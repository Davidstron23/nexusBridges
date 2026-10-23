import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/certificate_parser.dart';
import 'package:nexus_bridges_core/src/identity/der.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:test/test.dart';

const List<int> _p256SpkiPrefix = [
  0x30,
  0x59,
  0x30,
  0x13,
  0x06,
  0x07,
  0x2A,
  0x86,
  0x48,
  0xCE,
  0x3D,
  0x02,
  0x01,
  0x06,
  0x08,
  0x2A,
  0x86,
  0x48,
  0xCE,
  0x3D,
  0x03,
  0x01,
  0x07,
  0x03,
  0x42,
  0x00,
];

final RegExp _commonNamePattern = RegExp(r'^NexusBridges-[0-9a-f]{16}$');

final class _XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

typedef _KeyPair = ({ECPrivateKey privateKey, ECPublicKey publicKey});

typedef _Legacy = ({String certificatePem, String privateKeyPem});

typedef _Exchange = ({
  String? body,
  Object? error,
  int handled,
  X509Certificate? serverCertificate,
});

_KeyPair _keyPair({String curve = 'prime256v1'}) {
  final pair = CryptoUtils.generateEcKeyPair(curve: curve);
  return (
    privateKey: pair.privateKey as ECPrivateKey,
    publicKey: pair.publicKey as ECPublicKey,
  );
}

String _basicUtilsCertificate(
  _KeyPair keys, {
  required Map<String, String> subject,
  String serialNumber = '1',
  Map<String, String>? issuer,
  int days = 18262,
  DateTime? notBefore,
  List<KeyUsage>? keyUsage,
}) {
  final csr = X509Utils.generateEccCsrPem(
    subject,
    keys.privateKey,
    keys.publicKey,
  );
  return X509Utils.generateSelfSignedCertificate(
    keys.privateKey,
    csr,
    days,
    serialNumber: serialNumber,
    issuer: issuer,
    notBefore: notBefore ?? DateTime.utc(2000),
    keyUsage: keyUsage,
  );
}

_Legacy _legacyIdentity({_KeyPair? keys, String? commonName}) {
  final pair = keys ?? _keyPair();
  final csr = X509Utils.generateEccCsrPem(
    {'CN': commonName ?? randomCommonName()},
    pair.privateKey,
    pair.publicKey,
  );
  return (
    certificatePem: X509Utils.generateSelfSignedCertificate(
      pair.privateKey,
      csr,
      18262,
      notBefore: DateTime.utc(2000),
    ),
    privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(pair.privateKey),
  );
}

Uint8List _derOf(String pem) => Uint8List.fromList(
  base64.decode(
    LineSplitter.split(pem)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join(),
  ),
);

String _pemOf(List<int> der) =>
    '-----BEGIN CERTIFICATE-----\n${base64.encode(der)}\n'
    '-----END CERTIFICATE-----\n';

Uint8List _expectedSpki(ECPublicKey publicKey) =>
    Uint8List.fromList([..._p256SpkiPrefix, ...publicKey.Q!.getEncoded(false)]);

Uint8List _expectedSpkiFromPrivateKeyPem(String privateKeyPem) {
  final privateKey = CryptoUtils.ecPrivateKeyFromPem(privateKeyPem);
  final point = (privateKey.parameters!.G * privateKey.d)!;
  return Uint8List.fromList([..._p256SpkiPrefix, ...point.getEncoded(false)]);
}

String _sha256Upper(List<int> bytes) =>
    sha256.convert(bytes).toString().toUpperCase();

String _privateKeyPemOf(DeviceIdentity identity) {
  final protector = _XorProtector();
  return utf8.decode(
    protector.unprotect(identity.protectPrivateKey(protector))!,
  );
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

List<int> _commonNameAttribute(int stringTag, String value) {
  final bytes = utf8.encode(value);
  return [0x06, 0x03, 0x55, 0x04, 0x03, stringTag, bytes.length, ...bytes];
}

SecurityContext _presenting(String certificatePem, String privateKeyPem) =>
    SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..useCertificateChainBytes(utf8.encode(certificatePem))
      ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

Future<_Exchange> _exchange({
  required SecurityContext serverContext,
  required SecurityContext clientContext,
  required String pinnedFingerprint,
}) async {
  var handled = 0;
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    serverContext,
    requestClientCertificate: true,
  );
  server.listen((request) {
    handled++;
    final certificate = request.certificate;
    request.response
      ..write(
        certificate == null
            ? 'none'
            : fingerprintOfCertificate(certificate.der),
      )
      ..close();
  });
  X509Certificate? seen;
  final client = HttpClient(context: clientContext)
    ..findProxy = ((_) => 'DIRECT')
    ..badCertificateCallback = (certificate, host, port) {
      seen = certificate;
      return fingerprintOfCertificate(certificate.der) == pinnedFingerprint;
    };
  try {
    final request = await client
        .getUrl(Uri.parse('https://127.0.0.1:${server.port}/'))
        .timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = await response.transform(utf8.decoder).join();
    return (body: body, error: null, handled: handled, serverCertificate: seen);
  } on IOException catch (error) {
    return (
      body: null,
      error: error,
      handled: handled,
      serverCertificate: seen,
    );
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
}

Matcher _notReadable() => throwsA(
  isA<FormatException>().having(
    (e) => e.message,
    'message',
    'certificate is not readable',
  ),
);

Matcher _invalidDer() => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', 'invalid DER'),
);

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late String alicePrivateKeyPem;
  late String bobPrivateKeyPem;

  setUpAll(() {
    alice = DeviceIdentity.generate(commonName: randomCommonName());
    bob = DeviceIdentity.generate(commonName: randomCommonName());
    alicePrivateKeyPem = _privateKeyPemOf(alice);
    bobPrivateKeyPem = _privateKeyPemOf(bob);
  });

  group('C1 fingerprint over the public key (RF-65)', () {
    test('is the uppercase SHA-256 of the SPKI built from the private key', () {
      final spki = _expectedSpkiFromPrivateKeyPem(alicePrivateKeyPem);

      expect(spki, hasLength(91));
      expect(alice.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(alice.fingerprint, _sha256Upper(spki));
    });

    test('differs from the SHA-256 of the whole certificate DER', () {
      expect(alice.fingerprint, isNot(_sha256Upper(alice.certificateDer)));
      expect(bob.fingerprint, isNot(_sha256Upper(bob.certificateDer)));
    });

    test('every entry point gives the same fingerprint', () {
      final asList = List<int>.of(alice.certificateDer);

      expect(fingerprintOfCertificate(alice.certificateDer), alice.fingerprint);
      expect(fingerprintOfCertificate(asList), alice.fingerprint);
      expect(
        PeerCertificate.tryParse(alice.certificatePem)!.fingerprint,
        alice.fingerprint,
      );
      expect(
        PeerCertificate.fromDer(alice.certificateDer)!.fingerprint,
        alice.fingerprint,
      );
    });

    test('parseCertificate returns the full SPKI DER of an EC P-256 key', () {
      final parsed = parseCertificate(alice.certificateDer);

      expect(parsed.spki, _expectedSpkiFromPrivateKeyPem(alicePrivateKeyPem));
      expect(parsed.spki.sublist(0, _p256SpkiPrefix.length), _p256SpkiPrefix);
      expect(parsed.spki[_p256SpkiPrefix.length], 0x04);
    });

    test('two identities never share a fingerprint', () {
      expect(alice.fingerprint, isNot(bob.fingerprint));
    });

    test('fingerprintOfCertificate throws only the not readable error', () {
      final p384 = _derOf(
        _basicUtilsCertificate(
          _keyPair(curve: 'secp384r1'),
          subject: {'CN': randomCommonName()},
        ),
      );
      final der = alice.certificateDer;
      final inputs = <String, List<int>>{
        'empty': const [],
        'one byte': const [0x30],
        'garbage': utf8.encode('not a certificate'),
        'truncated': der.sublist(0, der.length - 1),
        'trailing byte': [...der, 0x00],
        'P-384 key': p384,
        'the PEM text as bytes': utf8.encode(alice.certificatePem),
      };

      for (final MapEntry(key: label, value: bytes) in inputs.entries) {
        expect(
          () => fingerprintOfCertificate(bytes),
          _notReadable(),
          reason: label,
        );
      }
    });
  });

  group('C2 same key, another certificate (RF-65)', () {
    test('a different serial and common name keep the fingerprint', () {
      final keys = _keyPair();
      final first = _derOf(
        _basicUtilsCertificate(keys, subject: {'CN': randomCommonName()}),
      );
      final second = _derOf(
        _basicUtilsCertificate(
          keys,
          subject: {'CN': randomCommonName()},
          serialNumber: '987654321987654321',
        ),
      );

      expect(first, isNot(second));
      expect(_sha256Upper(first), isNot(_sha256Upper(second)));
      expect(fingerprintOfCertificate(first), fingerprintOfCertificate(second));
      expect(
        fingerprintOfCertificate(first),
        _sha256Upper(_expectedSpki(keys.publicKey)),
      );
      expect(
        PeerCertificate.fromDer(first)!.commonName,
        isNot(PeerCertificate.fromDer(second)!.commonName),
      );
      expect(
        PeerCertificate.fromDer(first)!.fingerprint,
        PeerCertificate.fromDer(second)!.fingerprint,
      );
    });

    test('other dates and extensions keep the fingerprint too', () {
      final keys = _keyPair();
      final plain = _derOf(
        _basicUtilsCertificate(keys, subject: {'CN': randomCommonName()}),
      );
      final other = _derOf(
        _basicUtilsCertificate(
          keys,
          subject: {'CN': randomCommonName()},
          serialNumber: '2',
          days: 30,
          notBefore: DateTime.utc(2020, 6, 15),
          keyUsage: [KeyUsage.DIGITAL_SIGNATURE],
        ),
      );

      expect(fingerprintOfCertificate(plain), fingerprintOfCertificate(other));
    });

    test('control: another key with the same name and serial changes it', () {
      final commonName = randomCommonName();
      final first = _derOf(
        _basicUtilsCertificate(_keyPair(), subject: {'CN': commonName}),
      );
      final second = _derOf(
        _basicUtilsCertificate(_keyPair(), subject: {'CN': commonName}),
      );

      expect(
        fingerprintOfCertificate(first),
        isNot(fingerprintOfCertificate(second)),
      );
      expect(
        PeerCertificate.fromDer(first)!.canonicalName,
        PeerCertificate.fromDer(second)!.canonicalName,
      );
    });
  });

  group('C3 identity stored by spec 001 (RF-65, risk R35)', () {
    late _KeyPair keys;
    late String commonName;
    late _Legacy legacy;
    late Uint8List legacyDer;

    setUpAll(() {
      keys = _keyPair();
      commonName = randomCommonName();
      legacy = _legacyIdentity(keys: keys, commonName: commonName);
      legacyDer = _derOf(legacy.certificatePem);
    });

    test('the fixture is what spec 001 wrote: serial 1, UTCTime to 2049, '
        'PrintableString CN, ECDSA P-256', () {
      final data = X509Utils.x509CertificateFromPem(legacy.certificatePem);
      final tbs = data.tbsCertificate!;

      expect(tbs.serialNumber, BigInt.one);
      expect(tbs.validity.notBefore, DateTime.utc(2000));
      expect(tbs.validity.notAfter, DateTime.utc(2049, 12, 31));
      expect(tbs.subject['2.5.4.3'], commonName);
      expect(tbs.subjectPublicKeyInfo.parameterReadableName, 'prime256v1');
      expect(
        _containsBytes(legacyDer, _commonNameAttribute(0x13, commonName)),
        isTrue,
      );
      expect(_containsBytes(legacyDer, [0x18, 0x0F]), isFalse);
    });

    test('parseCertificate accepts it with its name and SPKI', () {
      final parsed = parseCertificate(legacyDer);

      expect(parsed.commonName, commonName);
      expect(parsed.spki, _expectedSpki(keys.publicKey));
    });

    test('fromPem loads it and the fingerprint is over the SPKI', () {
      final loaded = DeviceIdentity.fromPem(
        certificatePem: legacy.certificatePem,
        privateKeyPem: legacy.privateKeyPem,
      );

      expect(loaded, isNotNull);
      expect(loaded!.fingerprint, _sha256Upper(_expectedSpki(keys.publicKey)));
      expect(loaded.fingerprint, isNot(_sha256Upper(legacyDer)));
      expect(loaded.certificatePem, legacy.certificatePem);
      expect(loaded.certificateDer, legacyDer);
    });

    test('PeerCertificate reads it with the same fingerprint and name', () {
      final peer = PeerCertificate.tryParse(legacy.certificatePem);

      expect(peer, isNotNull);
      expect(peer!.commonName, commonName);
      expect(peer.canonicalName, commonName.toLowerCase());
      expect(peer.fingerprint, _sha256Upper(_expectedSpki(keys.publicKey)));
      expect(peer.der, legacyDer);
    });

    test('IdentityStore loads the stored files without resetting', () async {
      final dataDir = await Directory.systemTemp.createTemp('nexus_c3_');
      addTearDown(() => dataDir.delete(recursive: true));
      final identityDir = Directory('${dataDir.path}/identity');
      await identityDir.create();
      final protector = _XorProtector();
      await File('${identityDir.path}/certificate.pem')
          .writeAsString(legacy.certificatePem);
      await File('${identityDir.path}/private-key.dpapi').writeAsBytes(
        protector.protect(
          Uint8List.fromList(utf8.encode(legacy.privateKeyPem)),
        ),
      );

      final result = await IdentityStore(
        dataDir: dataDir,
        protector: protector,
      ).loadOrCreate();

      expect(result, isA<IdentityLoaded>());
      expect(
        result.identity.fingerprint,
        _sha256Upper(_expectedSpki(keys.publicKey)),
      );
      expect(
        await dataDir
            .list()
            .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
            .toList(),
        ['identity'],
      );
    });

    test('mutual TLS with a pinned fingerprint works as server', () async {
      final server = DeviceIdentity.fromPem(
        certificatePem: legacy.certificatePem,
        privateKeyPem: legacy.privateKeyPem,
      )!;

      final outcome = await _exchange(
        serverContext: server.serverContext(
          trustedCertificatesPem: [bob.certificatePem],
        ),
        clientContext: _presenting(bob.certificatePem, bobPrivateKeyPem),
        pinnedFingerprint: server.fingerprint,
      );

      expect(outcome.error, isNull, reason: '${outcome.error}');
      expect(outcome.body, bob.fingerprint);
      expect(outcome.handled, 1);
      expect(
        fingerprintOfCertificate(outcome.serverCertificate!.der),
        server.fingerprint,
      );
    });

    test('mutual TLS with a pinned fingerprint works as client', () async {
      final client = DeviceIdentity.fromPem(
        certificatePem: legacy.certificatePem,
        privateKeyPem: legacy.privateKeyPem,
      )!;

      final outcome = await _exchange(
        serverContext: alice.serverContext(
          trustedCertificatesPem: [legacy.certificatePem],
        ),
        clientContext: _presenting(legacy.certificatePem, legacy.privateKeyPem),
        pinnedFingerprint: alice.fingerprint,
      );

      expect(outcome.error, isNull, reason: '${outcome.error}');
      expect(outcome.body, client.fingerprint);
      expect(outcome.handled, 1);
    });
  });

  group('C4 fingerprint in TLS (RF-65, RF-82)', () {
    test('a client pinning A connects and the server reads B', () async {
      final outcome = await _exchange(
        serverContext: alice.serverContext(
          trustedCertificatesPem: [bob.certificatePem],
        ),
        clientContext: _presenting(bob.certificatePem, bobPrivateKeyPem),
        pinnedFingerprint: alice.fingerprint,
      );

      expect(outcome.error, isNull, reason: '${outcome.error}');
      expect(outcome.handled, 1);
      expect(outcome.body, bob.fingerprint);
      final seen = PeerCertificate.fromDer(outcome.serverCertificate!.der)!;
      expect(seen.fingerprint, alice.fingerprint);
      expect(
        seen.commonName,
        PeerCertificate.tryParse(alice.certificatePem)!.commonName,
      );
      expect(
        alice.fingerprint,
        isNot(_sha256Upper(outcome.serverCertificate!.der)),
      );
    });

    test(
      'the certificate the server reads is B, by fingerprint and name',
      () async {
        late X509Certificate received;
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          alice.serverContext(trustedCertificatesPem: [bob.certificatePem]),
          requestClientCertificate: true,
        );
        addTearDown(() => server.close(force: true));
        server.listen((request) {
          received = request.certificate!;
          request.response.close();
        });
        final client =
            HttpClient(
                context: _presenting(bob.certificatePem, bobPrivateKeyPem),
              )
              ..findProxy = ((_) => 'DIRECT')
              ..badCertificateCallback = (certificate, host, port) =>
                  fingerprintOfCertificate(certificate.der) ==
                  alice.fingerprint;
        addTearDown(() => client.close(force: true));

        final request = await client.getUrl(
          Uri.parse('https://127.0.0.1:${server.port}/'),
        );
        await (await request.close()).drain<void>();

        final peer = PeerCertificate.fromDer(received.der)!;
        final expected = PeerCertificate.tryParse(bob.certificatePem)!;
        expect(peer.fingerprint, bob.fingerprint);
        expect(peer.commonName, expected.commonName);
        expect(peer.der, bob.certificateDer);
      },
    );

    test('a client pinning another fingerprint is cut before HTTP', () async {
      final outcome = await _exchange(
        serverContext: alice.serverContext(
          trustedCertificatesPem: [bob.certificatePem],
        ),
        clientContext: _presenting(bob.certificatePem, bobPrivateKeyPem),
        pinnedFingerprint: bob.fingerprint,
      );

      expect(outcome.error, isA<HandshakeException>());
      expect(outcome.handled, 0);
      expect(
        fingerprintOfCertificate(outcome.serverCertificate!.der),
        alice.fingerprint,
      );
    });

    test(
      'pinning the old SHA-256 of the whole DER no longer connects',
      () async {
        final outcome = await _exchange(
          serverContext: alice.serverContext(
            trustedCertificatesPem: [bob.certificatePem],
          ),
          clientContext: _presenting(bob.certificatePem, bobPrivateKeyPem),
          pinnedFingerprint: _sha256Upper(alice.certificateDer),
        );

        expect(outcome.error, isA<HandshakeException>());
        expect(outcome.handled, 0);
      },
    );

    test('a client without certificate reaches HTTP with none', () async {
      final outcome = await _exchange(
        serverContext: alice.serverContext(
          trustedCertificatesPem: [bob.certificatePem],
        ),
        clientContext: bob.clientContext(),
        pinnedFingerprint: alice.fingerprint,
      );

      expect(outcome.error, isNull, reason: '${outcome.error}');
      expect(outcome.body, 'none');
    });

    test(
      'a client certificate that is not trusted never reaches HTTP',
      () async {
        final outcome = await _exchange(
          serverContext: alice.serverContext(
            trustedCertificatesPem: [bob.certificatePem],
          ),
          clientContext: _presenting(alice.certificatePem, alicePrivateKeyPem),
          pinnedFingerprint: alice.fingerprint,
        );

        expect(outcome.error, isNotNull);
        expect(outcome.handled, 0);
      },
    );
  });

  group('C7 (a) PeerCertificate.tryParse with basic_utils certificates '
      '(RF-93)', () {
    late _KeyPair keys;
    late String commonName;
    late String validPem;
    late Uint8List validDer;

    setUpAll(() {
      keys = _keyPair();
      commonName = randomCommonName();
      validPem = _basicUtilsCertificate(keys, subject: {'CN': commonName});
      validDer = _derOf(validPem);
    });

    String withName(String name) =>
        _basicUtilsCertificate(_keyPair(), subject: {'CN': name});

    void expectRejected(String pem, String label) {
      expect(
        () => PeerCertificate.tryParse(pem),
        returnsNormally,
        reason: label,
      );
      expect(PeerCertificate.tryParse(pem), isNull, reason: label);
    }

    test('a valid one with a PrintableString CN gives an object', () {
      expect(
        _containsBytes(validDer, _commonNameAttribute(0x13, commonName)),
        isTrue,
      );

      final peer = PeerCertificate.tryParse(validPem);

      expect(peer, isNotNull);
      expect(peer!.commonName, commonName);
      expect(peer.canonicalName, commonName.toLowerCase());
      expect(peer.fingerprint, _sha256Upper(_expectedSpki(keys.publicKey)));
      expect(peer.der, validDer);
    });

    test('pem is normalized: header, lines of 64, footer and one newline', () {
      final peer = PeerCertificate.tryParse(validPem)!;
      final body = base64.encode(validDer);
      final lines = peer.pem.split('\n');

      expect(peer.pem, isNot(contains('\r')));
      expect(peer.pem, endsWith('-----END CERTIFICATE-----\n'));
      expect(lines.first, '-----BEGIN CERTIFICATE-----');
      expect(lines.last, '');
      expect(lines[lines.length - 2], '-----END CERTIFICATE-----');
      final bodyLines = lines.sublist(1, lines.length - 2);
      for (final line in bodyLines.take(bodyLines.length - 1)) {
        expect(line, hasLength(64));
      }
      expect(bodyLines.last.length, inInclusiveRange(1, 64));
      expect(bodyLines.join(), body);
    });

    test('any valid layout of the same certificate normalizes alike', () {
      final body = base64.encode(validDer);
      final layouts = <String>[
        validPem,
        _pemOf(validDer),
        '\n  -----BEGIN CERTIFICATE-----\r\n$body\r\n-----END CERTIFICATE-----  \n\n',
        '-----BEGIN CERTIFICATE-----\n'
            '${[for (var i = 0; i < body.length; i += 10) body.substring(i, i + 10 > body.length ? body.length : i + 10)].join('\n')}'
            '\n-----END CERTIFICATE-----',
      ];
      final expected = PeerCertificate.tryParse(validPem)!.pem;

      for (final layout in layouts) {
        final peer = PeerCertificate.tryParse(layout);
        expect(peer, isNotNull, reason: layout);
        expect(peer!.pem, expected);
        expect(PeerCertificate.tryParse(peer.pem)!.pem, expected);
      }
    });

    test('fromDer gives the same object as tryParse', () {
      final fromDer = PeerCertificate.fromDer(validDer)!;
      final fromPem = PeerCertificate.tryParse(validPem)!;

      expect(fromDer.pem, fromPem.pem);
      expect(fromDer.der, fromPem.der);
      expect(fromDer.fingerprint, fromPem.fingerprint);
      expect(fromDer.commonName, fromPem.commonName);
    });

    test('a certificate with extensions ([3]) is accepted', () {
      final pem = _basicUtilsCertificate(
        keys,
        subject: {'CN': commonName},
        keyUsage: [KeyUsage.DIGITAL_SIGNATURE, KeyUsage.KEY_AGREEMENT],
      );

      expect(
        PeerCertificate.tryParse(pem)?.fingerprint,
        _sha256Upper(_expectedSpki(keys.publicKey)),
      );
    });

    test('two PEM blocks give null', () {
      expectRejected('$validPem\n$validPem', 'same twice');
      expectRejected('$validPem\n${alice.certificatePem}', 'two certificates');
      expectRejected(
        '$validPem\n-----BEGIN CERTIFICATE-----\n',
        'a second header',
      );
    });

    test('garbage gives null and never throws', () {
      final body = base64.encode(validDer);
      final cases = <String, String>{
        'empty': '',
        'text': 'garbage',
        'only whitespace': ' \n\t ',
        'header only': '-----BEGIN CERTIFICATE-----\n',
        'empty body':
            '-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n',
        'bad base64': '-----BEGIN CERTIFICATE-----\n@@@@!!!!\n-----END CERTIFICATE-----\n',
        'short DER':
            '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n',
        'raw base64 without armor': body,
        'private key': alicePrivateKeyPem,
        'text before': 'hello\n$validPem',
        'text after': '${validPem}trailer',
        'swapped markers':
            '-----END CERTIFICATE-----\n$body\n-----BEGIN CERTIFICATE-----\n',
        'control characters': '\u0000\u0001\u0002',
        'truncated DER': _pemOf(validDer.sublist(0, validDer.length - 1)),
        'random bytes': _pemOf(List<int>.generate(400, (i) => (i * 37) & 0xFF)),
      };

      for (final MapEntry(key: label, value: pem) in cases.entries) {
        expectRejected(pem, label);
      }
    });

    test('a PEM of exactly 4096 characters is read and one of 4097 is not', () {
      final base = _pemOf(validDer);
      expect(base.length, lessThan(4096));
      final atLimit = base + '\n' * (4096 - base.length);
      final overLimit = '$atLimit\n';

      expect(atLimit, hasLength(4096));
      expect(overLimit, hasLength(4097));
      expect(PeerCertificate.tryParse(atLimit)?.commonName, commonName);
      expectRejected(overLimit, 'over the limit');
    });

    test('a P-384 key gives null', () {
      final pem = _basicUtilsCertificate(
        _keyPair(curve: 'secp384r1'),
        subject: {'CN': randomCommonName()},
      );
      expect(
        X509Utils.x509CertificateFromPem(pem)
            .tbsCertificate!
            .subjectPublicKeyInfo
            .parameterReadableName,
        'secp384r1',
      );

      expectRejected(pem, 'P-384');
    });

    test('a subject with CN and O gives null, in either order', () {
      expectRejected(
        _basicUtilsCertificate(
          _keyPair(),
          subject: {'CN': randomCommonName(), 'O': 'NexusBridges'},
        ),
        'CN then O',
      );
      expectRejected(
        _basicUtilsCertificate(
          _keyPair(),
          subject: {'O': 'NexusBridges', 'CN': randomCommonName()},
        ),
        'O then CN',
      );
    });

    test('a CN in uppercase gives null', () {
      final hex = randomCommonName().substring('NexusBridges-'.length);
      for (final name in [
        'NexusBridges-0123456789ABCDEF',
        'NEXUSBRIDGES-$hex',
        'nexusbridges-$hex',
        'NexusBridges-0123456789abcdeF',
      ]) {
        expectRejected(withName(name), name);
      }
    });

    test('a CN with a space at either end gives null', () {
      final name = randomCommonName();
      final trailing = withName('$name ');
      expect(
        _containsBytes(_derOf(trailing), _commonNameAttribute(0x13, '$name ')),
        isTrue,
      );

      expectRejected(trailing, 'trailing space');
      expectRejected(withName(' $name'), 'leading space');
      expectRejected(withName('NexusBridges- ${name.substring(14)}'), 'inner');
    });

    test('a CN with 15 or 17 hex digits gives null and 16 is read', () {
      final hex = randomCommonName().substring('NexusBridges-'.length);

      expectRejected(withName('NexusBridges-${hex.substring(0, 15)}'), '15');
      expectRejected(withName('NexusBridges-${hex}0'), '17');
      expect(
        PeerCertificate.tryParse(withName('NexusBridges-$hex'))?.commonName,
        'NexusBridges-$hex',
      );
    });

    test('a CN with other characters gives null', () {
      for (final name in [
        'NexusBridges-alice',
        'NexusBridges-0123456789abcdeg',
        'NexusBridges_0123456789abcdef',
        'NexusBridges-0123456789abcdef\u200B',
        '\u202ENexusBridges-0123456789abcdef',
        'NexusBridges-0123456789abcd\u00E9f',
        'NexusBridges-0123456789abcdef\n',
      ]) {
        expectRejected(withName(name), name);
      }
    });

    test('an issuer different from the subject gives null', () {
      final name = randomCommonName();
      final other = _withIssuer(keys, name, {'CN': randomCommonName()});
      final withO = _withIssuer(keys, name, {'CN': name, 'O': 'NexusBridges'});

      expect(
        X509Utils.x509CertificateFromPem(other)
            .tbsCertificate!
            .issuer['2.5.4.3'],
        isNot(name),
      );
      expectRejected(other, 'another CN');
      expectRejected(withO, 'same CN plus O');
      expect(
        PeerCertificate.tryParse(_withIssuer(keys, name, {'CN': name}))
            ?.commonName,
        name,
      );
    });

    test('bytes after the DER give null', () {
      for (final extra in <List<int>>[
        [0x00],
        [0x30, 0x00],
        validDer,
      ]) {
        final der = [...validDer, ...extra];
        expectRejected(_pemOf(der), 'extra ${extra.length}');
        expect(PeerCertificate.fromDer(der), isNull);
      }
    });

    test('fromDer never throws with garbage', () {
      for (final der in <List<int>>[
        const [],
        const [0x30],
        const [0x30, 0x80, 0x00, 0x00],
        List<int>.filled(5000, 0x41),
        validDer.sublist(1),
      ]) {
        expect(() => PeerCertificate.fromDer(der), returnsNormally);
        expect(PeerCertificate.fromDer(der), isNull);
      }
    });
  });

  group('canonicalSubjectName and randomCommonName', () {
    test('lowercases, collapses whitespace and trims', () {
      expect(
        canonicalSubjectName('NexusBridges-0123456789ABCDEF'),
        'nexusbridges-0123456789abcdef',
      );
      expect(canonicalSubjectName('  A \t\n  B  '), 'a b');
      expect(canonicalSubjectName('a\r\n\r\nb'), 'a b');
      expect(canonicalSubjectName(''), '');
    });

    test('the canonical form of a valid name is its lowercase', () {
      final name = randomCommonName();

      expect(canonicalSubjectName(name), name.toLowerCase());
    });

    test('randomCommonName follows the pattern and varies', () {
      final names = {for (var i = 0; i < 20; i++) randomCommonName()};

      expect(names, hasLength(20));
      for (final name in names) {
        expect(name, matches(_commonNamePattern));
      }
    });
  });

  group('DeviceIdentity.generate checks the common name', () {
    test('rejects a name outside the pattern with ArgumentError', () {
      final hex = randomCommonName().substring('NexusBridges-'.length);
      for (final name in [
        '',
        'NexusBridges-alice',
        'NexusBridges-0123456789ABCDEF',
        'NexusBridges-${hex.substring(1)}',
        'NexusBridges-${hex}0',
        'NexusBridges-$hex ',
        ' NexusBridges-$hex',
        'NexusBridges-$hex\u200B',
      ]) {
        expect(
          () => DeviceIdentity.generate(commonName: name),
          throwsArgumentError,
          reason: name,
        );
      }
    });

    test('accepts a valid name and puts it in the certificate', () {
      final name = randomCommonName();
      final identity = DeviceIdentity.generate(commonName: name);

      expect(
        PeerCertificate.tryParse(identity.certificatePem)?.commonName,
        name,
      );
    });
  });

  group('DER reader rules', () {
    Uint8List bytes(List<int> values) => Uint8List.fromList(values);

    test('reads a short-form element', () {
      final source = bytes([0x30, 0x03, 0x02, 0x01, 0x05]);

      final element = readDerElement(source, 0, source.length);

      expect(element.tag, 0x30);
      expect(element.start, 0);
      expect(element.headerLength, 2);
      expect(element.length, 3);
      expect(element.valueStart, 2);
      expect(element.end, 5);
      expect(derBytes(source, element), source);
      expect(derValue(source, element), [0x02, 0x01, 0x05]);
    });

    test('reads long forms of one, two and three bytes', () {
      for (final (header, length) in [
        ([0x04, 0x81, 0x80], 0x80),
        ([0x04, 0x81, 0xFF], 0xFF),
        ([0x04, 0x82, 0x01, 0x00], 0x100),
        ([0x04, 0x83, 0x01, 0x00, 0x00], 0x10000),
      ]) {
        final source = bytes([...header, ...List<int>.filled(length, 0x00)]);

        final element = readDerElement(source, 0, source.length);

        expect(element.headerLength, header.length);
        expect(element.length, length);
        expect(element.end, source.length);
      }
    });

    test('rejects what the plan rules out', () {
      final cases = <String, List<int>>{
        'high tag number': [0x1F, 0x01, 0x00],
        'indefinite length': [0x30, 0x80, 0x00, 0x00],
        'long form under 128': [0x04, 0x81, 0x05, 0, 0, 0, 0, 0],
        'leading zero in the length': [
          0x04,
          0x82,
          0x00,
          0x80,
          ...List.filled(0x80, 0),
        ],
        'four length bytes': [0x04, 0x84, 0x00, 0x00, 0x00, 0x01, 0x00],
        'value past the end': [0x04, 0x05, 0x00, 0x00],
        'length bytes past the end': [0x04, 0x82, 0x01],
        'only a tag': [0x30],
        'empty': [],
      };

      for (final MapEntry(key: label, value: values) in cases.entries) {
        final source = bytes(values);
        expect(
          () => readDerElement(source, 0, source.length),
          _invalidDer(),
          reason: label,
        );
      }
    });

    test('rejects an element that crosses the limit', () {
      final source = bytes([0x30, 0x03, 0x02, 0x01, 0x05, 0x00]);

      expect(() => readDerElement(source, 0, 4), _invalidDer());
      expect(() => readDerElement(source, 0, 7), _invalidDer());
      expect(() => readDerElement(source, -1, 5), _invalidDer());
    });

    test('children must cover the parent exactly', () {
      final ok = bytes([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
      final overflow = bytes([0x30, 0x04, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
      final stray = bytes([0x30, 0x04, 0x02, 0x01, 0x01, 0x00]);

      final children = readDerChildren(ok, readDerElement(ok, 0, ok.length));
      expect(children.map((c) => c.start), [2, 5]);
      expect(
        () => readDerChildren(
          overflow,
          readDerElement(overflow, 0, overflow.length),
        ),
        _invalidDer(),
      );
      expect(
        () => readDerChildren(stray, readDerElement(stray, 0, stray.length)),
        _invalidDer(),
      );
    });
  });

  group('parseCertificate only throws FormatException', () {
    test('with any prefix of a valid certificate', () {
      final der = alice.certificateDer;
      for (var n = 0; n < der.length; n += 7) {
        expect(
          () => parseCertificate(Uint8List.fromList(der.sublist(0, n))),
          throwsA(isA<FormatException>()),
          reason: 'prefix $n',
        );
      }
    });

    test('with each single byte of a valid certificate flipped', () {
      final der = alice.certificateDer;
      for (var i = 0; i < der.length; i += 3) {
        final mutated = Uint8List.fromList(der)..[i] ^= 0xFF;
        try {
          parseCertificate(mutated);
        } on FormatException {
          continue;
        } catch (e) {
          fail('byte $i threw ${e.runtimeType}');
        }
      }
    });
  });
}

String _withIssuer(_KeyPair keys, String name, Map<String, String> issuer) =>
    _basicUtilsCertificate(keys, subject: {'CN': name}, issuer: issuer);
