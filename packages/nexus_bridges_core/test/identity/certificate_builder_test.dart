import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:nexus_bridges_core/src/identity/certificate_builder.dart';
import 'package:nexus_bridges_core/src/identity/certificate_parser.dart';
import 'package:nexus_bridges_core/src/identity/der.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:test/test.dart';

const String _sharedCommonName = 'NexusBridges-0123456789abcdef';

const List<int> _oidCommonName = [0x55, 0x04, 0x03];

const List<int> _oidEcdsaWithSha256 = [
  0x2A,
  0x86,
  0x48,
  0xCE,
  0x3D,
  0x04,
  0x03,
  0x02,
];

const List<int> _oidEcPublicKey = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01];

const List<int> _oidPrime256v1 = [
  0x2A,
  0x86,
  0x48,
  0xCE,
  0x3D,
  0x03,
  0x01,
  0x07,
];

final BigInt _curveOrder = BigInt.parse(
  'FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551',
  radix: 16,
);

final class _XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

typedef _KeyPair = ({ECPrivateKey privateKey, ECPublicKey publicKey});

typedef _Layout = ({
  List<DerElement> parts,
  List<DerElement> tbs,
  Uint8List der,
});

typedef _Attempt = ({int? status, Object? error});

final class _CountingServer {
  _CountingServer._(this._server);

  final HttpServer _server;

  int handled = 0;

  final List<String> clients = [];

  int get port => _server.port;

  static Future<_CountingServer> start(SecurityContext context) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
    );
    final counting = _CountingServer._(server);
    server.listen((request) {
      counting.handled++;
      final certificate = request.certificate;
      counting.clients.add(
        certificate == null
            ? 'none'
            : PeerCertificate.fromDer(certificate.der)?.fingerprint ??
                  'unreadable',
      );
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    });
    return counting;
  }

  Future<void> close() => _server.close(force: true);
}

_KeyPair _keyPair() {
  final pair = CryptoUtils.generateEcKeyPair();
  return (
    privateKey: pair.privateKey as ECPrivateKey,
    publicKey: pair.publicKey as ECPublicKey,
  );
}

String _privateKeyPemOf(DeviceIdentity identity) {
  final protector = _XorProtector();
  return utf8.decode(
    protector.unprotect(identity.protectPrivateKey(protector))!,
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

Uint8List _serial() {
  final serial = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  serial[0] = 0x42;
  return serial;
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

_Layout _layoutOf(Uint8List der) {
  final root = readDerElement(der, 0, der.length);
  expect(root.tag, 0x30);
  expect(root.end, der.length);
  final parts = readDerChildren(der, root);
  expect(parts, hasLength(3));
  return (parts: parts, tbs: readDerChildren(der, parts[0]), der: der);
}

BigInt _bigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b);
  }
  return value;
}

Uint8List _bigEndian32(BigInt value) {
  final out = Uint8List(32);
  var rest = value;
  for (var i = 31; i >= 0; i--) {
    out[i] = (rest & BigInt.from(0xFF)).toInt();
    rest = rest >> 8;
  }
  return out;
}

Uint8List _indefinite(Uint8List element) {
  final parsed = readDerElement(element, 0, element.length);
  return _bytes([element[0], 0x80, ...derValue(element, parsed), 0x00, 0x00]);
}

Uint8List _nameOf(Uint8List commonNameValue) => derSequence([
  derSet([
    derSequence([derOid(_oidCommonName), commonNameValue]),
  ]),
]);

String _boundName(_KeyPair keys) => commonNameForSpki(spkiOf(keys.publicKey));

Uint8List _handBuilt(
  _KeyPair keys, {
  String? commonName,
  Uint8List? commonNameValue,
  Uint8List? point,
  Uint8List? validity,
  List<Uint8List> afterSpki = const [],
  bool indefiniteCertificate = false,
}) {
  final name = _nameOf(
    commonNameValue ?? derPrintable(commonName ?? _boundName(keys)),
  );
  final algorithm = derSequence([derOid(_oidEcdsaWithSha256)]);
  final tbs = derSequence([
    derExplicit(0, derInteger(_bytes([2]))),
    derInteger(_serial()),
    algorithm,
    name,
    validity ??
        derSequence([
          derUtcTime('000101000000Z'),
          derGeneralizedTime('99991231235959Z'),
        ]),
    name,
    derSequence([
      derSequence([derOid(_oidEcPublicKey), derOid(_oidPrime256v1)]),
      derBitString(point ?? keys.publicKey.Q!.getEncoded(false)),
    ]),
    ...afterSpki,
  ]);
  final signature = CryptoUtils.ecSign(
    keys.privateKey,
    tbs,
    algorithmName: 'SHA-256/ECDSA',
  );
  final certificate = derSequence([
    tbs,
    algorithm,
    derBitString(
      derSequence([
        derIntegerFromBigInt(signature.r),
        derIntegerFromBigInt(signature.s),
      ]),
    ),
  ]);
  return indefiniteCertificate ? _indefinite(certificate) : certificate;
}

void _expectRejected(Uint8List der, String label) {
  expect(
    () => PeerCertificate.tryParse(_pemOf(der)),
    returnsNormally,
    reason: label,
  );
  expect(PeerCertificate.tryParse(_pemOf(der)), isNull, reason: label);
  expect(PeerCertificate.fromDer(der), isNull, reason: label);
  expect(
    () => parseCertificate(der),
    throwsA(isA<FormatException>()),
    reason: label,
  );
}

SecurityContext _presenting(String certificatePem, String privateKeyPem) =>
    SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..useCertificateChainBytes(utf8.encode(certificatePem))
      ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

Future<_Attempt> _get(
  int port,
  SecurityContext context,
  String pinnedFingerprint,
) async {
  final client = HttpClient(context: context)
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(seconds: 5)
    ..badCertificateCallback = (certificate, host, port) =>
        fingerprintOfCertificate(certificate.der) == pinnedFingerprint;
  try {
    final request = await client
        .getUrl(Uri.parse('https://127.0.0.1:$port/'))
        .timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();
    return (status: response.statusCode, error: null);
  } on IOException catch (error) {
    return (status: null, error: error);
  } on TimeoutException catch (error) {
    return (status: null, error: error);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late String alicePrivateKeyPem;

  setUpAll(() {
    alice = DeviceIdentity.generate();
    bob = DeviceIdentity.generate();
    alicePrivateKeyPem = _privateKeyPemOf(alice);
  });

  group('C5 new certificate (inheritance: random serial, GeneralizedTime)', () {
    late _Layout layout;

    setUpAll(() {
      layout = _layoutOf(alice.certificateDer);
    });

    test('is a v3 certificate with seven tbs fields and no extensions', () {
      final der = layout.der;
      final tbs = layout.tbs;

      expect(layout.parts.map((p) => p.tag), [0x30, 0x30, 0x03]);
      expect(tbs.map((e) => e.tag), [0xA0, 0x02, 0x30, 0x30, 0x30, 0x30, 0x30]);
      final version = readDerChildren(der, tbs[0]);
      expect(version, hasLength(1));
      expect(derBytes(der, version.single), [0x02, 0x01, 0x02]);
      expect(tbs.where((e) => e.tag == 0xA3), isEmpty);
    });

    test('notBefore is UTCTime 000101000000Z, read with the own reader', () {
      final validity = readDerChildren(layout.der, layout.tbs[4]);

      expect(validity, hasLength(2));
      expect(validity[0].tag, 0x17);
      expect(ascii.decode(derValue(layout.der, validity[0])), '000101000000Z');
    });

    test('notAfter is GeneralizedTime 99991231235959Z, read with the own '
        'reader', () {
      final validity = readDerChildren(layout.der, layout.tbs[4]);

      expect(validity[1].tag, 0x18);
      expect(
        ascii.decode(derValue(layout.der, validity[1])),
        '99991231235959Z',
      );
    });

    test('the serial is a positive 16-byte integer', () {
      final serial = layout.tbs[1];
      final value = derValue(layout.der, serial);

      expect(serial.tag, 0x02);
      expect(value, hasLength(16));
      expect(value[0], isNot(0));
      expect(value[0] & 0x80, 0);
    });

    test('the serial changes between generations and never repeats', () {
      final serials = <String>{};
      for (var i = 0; i < 20; i++) {
        final identity = DeviceIdentity.generate();
        final der = identity.certificateDer;
        final serial = derValue(der, _layoutOf(der).tbs[1]);
        expect(serial, hasLength(16));
        expect(serial[0], inInclusiveRange(1, 0x7F));
        serials.add(base64.encode(serial));
      }

      expect(serials, hasLength(20));
    });

    test('the algorithm is ecdsa-with-SHA256 without parameters, twice', () {
      final der = layout.der;
      final inner = layout.tbs[2];

      expect(derBytes(der, inner), derSequence([derOid(_oidEcdsaWithSha256)]));
      expect(readDerChildren(der, inner), hasLength(1));
      expect(derBytes(der, layout.parts[1]), derBytes(der, inner));
    });

    test('issuer and subject are the same single PrintableString CN', () {
      final der = layout.der;
      final name = alice.certificate.commonName;

      expect(derBytes(der, layout.tbs[3]), _nameOf(derPrintable(name)));
      expect(derBytes(der, layout.tbs[5]), derBytes(der, layout.tbs[3]));
    });

    test('the SPKI carries the uncompressed point of the private key', () {
      final privateKey = CryptoUtils.ecPrivateKeyFromPem(alicePrivateKeyPem);
      final point = (privateKey.parameters!.G * privateKey.d)!;

      expect(
        derBytes(layout.der, layout.tbs[6]),
        derSequence([
          derSequence([derOid(_oidEcPublicKey), derOid(_oidPrime256v1)]),
          derBitString(point.getEncoded(false)),
        ]),
      );
    });

    test('the signature is a SEQUENCE of r and s that verifies the tbs', () {
      final der = layout.der;
      final bits = derValue(der, layout.parts[2]);
      expect(bits[0], 0x00);
      final inner = Uint8List.sublistView(bits, 1);
      final sequence = readDerElement(inner, 0, inner.length);
      expect(sequence.tag, 0x30);
      expect(sequence.end, inner.length);
      final integers = readDerChildren(inner, sequence);
      expect(integers.map((e) => e.tag), [0x02, 0x02]);
      final r = _bigInt(derValue(inner, integers[0]));
      final s = _bigInt(derValue(inner, integers[1]));

      expect(
        CryptoUtils.ecVerify(
          CryptoUtils.ecPublicKeyFromDerBytes(parseCertificate(der).spki),
          derBytes(der, layout.parts[0]),
          ECSignature(r, s),
          algorithm: 'SHA-256/ECDSA',
        ),
        isTrue,
      );
    });

    test('the PEM is normalized and certificate matches it', () {
      final lines = alice.certificatePem.split('\n');

      expect(alice.certificatePem, alice.certificate.pem);
      expect(lines.first, '-----BEGIN CERTIFICATE-----');
      expect(lines[lines.length - 2], '-----END CERTIFICATE-----');
      expect(lines.last, '');
      final body = lines.sublist(1, lines.length - 2);
      for (final line in body.take(body.length - 1)) {
        expect(line, hasLength(64));
      }
      expect(base64.decode(body.join()), alice.certificateDer);
      expect(alice.certificate.der, alice.certificateDer);
      expect(alice.certificate.fingerprint, alice.fingerprint);
    });

    test('buildSelfSignedCertificatePem writes the serial it is given and a '
        'UTF8String only on request', () {
      final keys = _keyPair();
      final serial = _serial();
      final printable = _derOf(
        buildSelfSignedCertificatePem(
          privateKey: keys.privateKey,
          publicKey: keys.publicKey,
          commonName: _sharedCommonName,
          serialNumber: serial,
        ),
      );
      final utf8Name = _derOf(
        buildSelfSignedCertificatePem(
          privateKey: keys.privateKey,
          publicKey: keys.publicKey,
          commonName: _sharedCommonName,
          serialNumber: serial,
          utf8CommonName: true,
        ),
      );

      final printableTbs = _layoutOf(printable).tbs;
      final utf8Tbs = _layoutOf(utf8Name).tbs;
      expect(derValue(printable, printableTbs[1]), serial);
      expect(
        derBytes(printable, printableTbs[5]),
        _nameOf(derPrintable(_sharedCommonName)),
      );
      expect(
        derBytes(utf8Name, utf8Tbs[5]),
        _nameOf(derUtf8(_sharedCommonName)),
      );
      expect(derBytes(utf8Name, utf8Tbs[3]), derBytes(utf8Name, utf8Tbs[5]));
    });

    test('buildSelfSignedCertificatePem fails only with the generic '
        'StateError', () {
      final keys = _keyPair();
      final badKey = ECPublicKey(null, keys.publicKey.parameters);

      for (final build in <String, String Function()>{
        'public key without point': () => buildSelfSignedCertificatePem(
          privateKey: keys.privateKey,
          publicKey: badKey,
          commonName: _sharedCommonName,
          serialNumber: _serial(),
        ),
        'non ASCII PrintableString': () => buildSelfSignedCertificatePem(
          privateKey: keys.privateKey,
          publicKey: keys.publicKey,
          commonName: 'NexusBridges-0123456789abcd\u00E9f',
          serialNumber: _serial(),
        ),
      }.entries) {
        expect(
          build.value,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'certificate build failed',
            ),
          ),
          reason: build.key,
        );
      }
    });

    test('TLS works with the new identity as server and as client', () async {
      final bobAsServer = await _CountingServer.start(
        bob.serverContext(trustedCertificatesPem: [alice.certificatePem]),
      );
      addTearDown(bobAsServer.close);
      final aliceAsServer = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: [bob.certificatePem]),
      );
      addTearDown(aliceAsServer.close);

      final toBob = await _get(
        bobAsServer.port,
        alice.clientContext(presentCertificate: true),
        bob.fingerprint,
      );
      final toAlice = await _get(
        aliceAsServer.port,
        bob.clientContext(presentCertificate: true),
        alice.fingerprint,
      );

      expect(toBob.error, isNull, reason: '${toBob.error}');
      expect(toBob.status, HttpStatus.notFound);
      expect(bobAsServer.clients, [alice.fingerprint]);
      expect(toAlice.error, isNull, reason: '${toAlice.error}');
      expect(toAlice.status, HttpStatus.notFound);
      expect(aliceAsServer.clients, [bob.fingerprint]);
    });

    test('clientContext presents no certificate unless asked to', () async {
      final server = await _CountingServer.start(
        bob.serverContext(trustedCertificatesPem: [alice.certificatePem]),
      );
      addTearDown(server.close);

      final plain = await _get(
        server.port,
        alice.clientContext(),
        bob.fingerprint,
      );
      final presenting = await _get(
        server.port,
        alice.clientContext(presentCertificate: true),
        bob.fingerprint,
      );

      expect(plain.status, HttpStatus.notFound, reason: '${plain.error}');
      expect(presenting.status, HttpStatus.notFound);
      expect(server.clients, ['none', alice.fingerprint]);
      expect(
        alice.clientContext(presentCertificate: true).minimumTlsProtocolVersion,
        TlsProtocolVersion.tls1_3,
      );
    });

    test('an untrusted client presenting its certificate is cut', () async {
      final carol = DeviceIdentity.generate();
      final server = await _CountingServer.start(
        bob.serverContext(trustedCertificatesPem: [alice.certificatePem]),
      );
      addTearDown(server.close);

      final outcome = await _get(
        server.port,
        carol.clientContext(presentCertificate: true),
        bob.fingerprint,
      );

      expect(outcome.status, isNull);
      expect(outcome.error, isA<IOException>());
      expect(server.handled, 0);
    });
  });

  group('C6 signature (RF-80, RF-81)', () {
    final data = utf8.encode('pairing transcript');

    test('sign gives 64 bytes that verify with the own certificate', () {
      final signature = alice.sign(data);

      expect(signature, hasLength(64));
      expect(alice.certificate.verify(data, signature), isTrue);
      expect(
        PeerCertificate.tryParse(alice.certificatePem)!.verify(data, signature),
        isTrue,
      );
    });

    test('the 64 bytes are r and s big-endian, as basic_utils checks them', () {
      final signature = alice.sign(data);
      final r = _bigInt(signature.sublist(0, 32));
      final s = _bigInt(signature.sublist(32));

      expect(
        CryptoUtils.ecVerify(
          CryptoUtils.ecPublicKeyFromDerBytes(
            parseCertificate(alice.certificateDer).spki,
          ),
          Uint8List.fromList(data),
          ECSignature(r, s),
          algorithm: 'SHA-256/ECDSA',
        ),
        isTrue,
      );
    });

    test('empty and large data also sign and verify', () {
      for (final input in <List<int>>[
        const [],
        List<int>.generate(100000, (i) => i & 0xFF),
      ]) {
        expect(alice.certificate.verify(input, alice.sign(input)), isTrue);
      }
    });

    test('changed data gives false', () {
      final signature = alice.sign(data);
      final changed = [...data]..[0] ^= 0x01;

      expect(alice.certificate.verify(changed, signature), isFalse);
      expect(alice.certificate.verify([...data, 0], signature), isFalse);
    });

    test('a signature by another key gives false', () {
      expect(alice.certificate.verify(data, bob.sign(data)), isFalse);
      expect(bob.certificate.verify(data, alice.sign(data)), isFalse);
    });

    test('a changed signature byte gives false', () {
      final signature = alice.sign(data);

      expect(
        alice.certificate.verify(
          data,
          Uint8List.fromList(signature)..[10] ^= 1,
        ),
        isFalse,
      );
      expect(
        alice.certificate.verify(
          data,
          Uint8List.fromList(signature)..[50] ^= 1,
        ),
        isFalse,
      );
    });

    test('63, 65 and 0 bytes give false', () {
      final signature = alice.sign(data);

      expect(alice.certificate.verify(data, signature.sublist(0, 63)), isFalse);
      expect(alice.certificate.verify(data, [...signature, 0]), isFalse);
      expect(alice.certificate.verify(data, const []), isFalse);
    });

    test('r = 0 or s = 0 gives false', () {
      final signature = alice.sign(data);
      final zeroR = Uint8List.fromList(signature)..fillRange(0, 32, 0);
      final zeroS = Uint8List.fromList(signature)..fillRange(32, 64, 0);

      expect(alice.certificate.verify(data, zeroR), isFalse);
      expect(alice.certificate.verify(data, zeroS), isFalse);
      expect(alice.certificate.verify(data, Uint8List(64)), isFalse);
    });

    test('r or s equal to or above the curve order gives false', () {
      final signature = alice.sign(data);
      final s = signature.sublist(32);
      final r = signature.sublist(0, 32);

      for (final bad in [
        [..._bigEndian32(_curveOrder), ...s],
        [...r, ..._bigEndian32(_curveOrder)],
        [...List<int>.filled(32, 0xFF), ...s],
        [...r, ...List<int>.filled(32, 0xFF)],
      ]) {
        expect(() => alice.certificate.verify(data, bad), returnsNormally);
        expect(alice.certificate.verify(data, bad), isFalse);
      }
    });

    test('an identity loaded with fromPem signs for the same certificate', () {
      final loaded = DeviceIdentity.fromPem(
        certificatePem: alice.certificatePem,
        privateKeyPem: alicePrivateKeyPem,
      )!;

      final signature = loaded.sign(data);

      expect(alice.certificate.verify(data, signature), isTrue);
      expect(loaded.certificate.fingerprint, alice.fingerprint);
    });
  });

  group('C7 (b) PeerCertificate.tryParse with hand-built DER (RF-93)', () {
    late _KeyPair keys;

    setUpAll(() {
      keys = _keyPair();
    });

    test('control: the hand-built baseline is read', () {
      final der = _handBuilt(keys);

      final peer = PeerCertificate.fromDer(der);

      expect(peer, isNotNull);
      expect(peer!.commonName, _boundName(keys));
      expect(
        peer.fingerprint,
        PeerCertificate.tryParse(
          buildSelfSignedCertificatePem(
            privateKey: keys.privateKey,
            publicKey: keys.publicKey,
            commonName: _boundName(keys),
            serialNumber: _serial(),
          ),
        )!.fingerprint,
      );
    });

    test('a valid UTF8String CN gives an object', () {
      final name = _boundName(keys);
      final der = _handBuilt(keys, commonNameValue: derUtf8(name));
      final built = _derOf(
        buildSelfSignedCertificatePem(
          privateKey: keys.privateKey,
          publicKey: keys.publicKey,
          commonName: name,
          serialNumber: _serial(),
          utf8CommonName: true,
        ),
      );

      for (final certificate in [der, built]) {
        final peer = PeerCertificate.tryParse(_pemOf(certificate));
        expect(peer, isNotNull);
        expect(peer!.commonName, name);
        expect(peer.canonicalName, name.toLowerCase());
        expect(peer.fingerprint, PeerCertificate.fromDer(der)!.fingerprint);
      }
    });

    test('a compressed point in the SPKI gives null', () {
      final compressed = keys.publicKey.Q!.getEncoded(true);
      expect(compressed, hasLength(33));
      expect(compressed[0], anyOf(0x02, 0x03));

      _expectRejected(_handBuilt(keys, point: compressed), 'compressed point');
    });

    test('a CN as IA5String gives null', () {
      final ia5 = derUtf8(_boundName(keys))..[0] = 0x16;

      _expectRejected(_handBuilt(keys, commonNameValue: ia5), 'IA5String');
    });

    test('an indefinite length gives null', () {
      final validity = _indefinite(
        derSequence([
          derUtcTime('000101000000Z'),
          derGeneralizedTime('99991231235959Z'),
        ]),
      );
      expect(validity[1], 0x80);

      _expectRejected(_handBuilt(keys, validity: validity), 'validity');
      _expectRejected(
        _handBuilt(keys, indefiniteCertificate: true),
        'certificate',
      );
      _expectRejected(
        _handBuilt(
          keys,
          commonNameValue: _indefinite(derUtf8(_boundName(keys))..[0] = 0x2C),
        ),
        'constructed CN',
      );
    });
  });

  group('C105 same SPKI as TLS (RF-65, RF-93)', () {
    late _KeyPair keys;

    setUpAll(() {
      keys = _keyPair();
    });

    test('control: the baseline without unique identifiers is read', () {
      expect(PeerCertificate.fromDer(_handBuilt(keys)), isNotNull);
    });

    test('a [1] or [2] in the tbs gives null', () {
      final uniqueId = derBitString(_bytes([1, 2, 3, 4]));
      final cases = <String, List<Uint8List>>{
        'explicit [1]': [derExplicit(1, uniqueId)],
        'explicit [2]': [derExplicit(2, uniqueId)],
        'implicit [1]': [derExplicit(1, uniqueId)..[0] = 0x81],
        'implicit [2]': [derExplicit(2, uniqueId)..[0] = 0x82],
        '[1] and [2]': [derExplicit(1, uniqueId), derExplicit(2, uniqueId)],
        '[1] before [3]': [
          derExplicit(1, uniqueId),
          derExplicit(3, derSequence([])),
        ],
      };

      for (final MapEntry(key: label, value: extra) in cases.entries) {
        _expectRejected(_handBuilt(keys, afterSpki: extra), label);
      }
    });

    test('a 32-byte challenge signed by the identity verifies with its '
        'certificate', () {
      final challenge = Uint8List.fromList(List<int>.generate(32, (i) => i));

      final signature = alice.sign(challenge);

      expect(alice.certificate.verify(challenge, signature), isTrue);
    });

    test('the certificate seen in TLS gives the fingerprint and verifies the '
        'signature', () async {
      final challenge = Uint8List.fromList(
        List<int>.generate(32, (i) => 7 * i),
      );
      final signature = alice.sign(challenge);
      X509Certificate? seenByClient;
      X509Certificate? seenByServer;
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        alice.serverContext(trustedCertificatesPem: [bob.certificatePem]),
        requestClientCertificate: true,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        seenByServer = request.certificate;
        request.response.close();
      });
      final client =
          HttpClient(context: bob.clientContext(presentCertificate: true))
            ..findProxy = ((_) => 'DIRECT')
            ..badCertificateCallback = (certificate, host, port) {
              seenByClient = certificate;
              return fingerprintOfCertificate(certificate.der) ==
                  alice.fingerprint;
            };
      addTearDown(() => client.close(force: true));

      final request = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/'),
      );
      await (await request.close()).drain<void>();

      final fromTls = PeerCertificate.fromDer(seenByClient!.der)!;
      expect(fromTls.fingerprint, alice.fingerprint);
      expect(fromTls.verify(challenge, signature), isTrue);
      expect(fromTls.verify(challenge, bob.sign(challenge)), isFalse);
      final clientInTls = PeerCertificate.fromDer(seenByServer!.der)!;
      expect(clientInTls.fingerprint, bob.fingerprint);
      expect(clientInTls.verify(challenge, bob.sign(challenge)), isTrue);
    });
  });

  group('C8 trusted context without repeated subjects (RF-93)', () {
    late DeviceIdentity server;
    late DeviceIdentity printable;
    late String twinPem;
    late String twinKeyPem;

    setUpAll(() {
      server = DeviceIdentity.generate();
      printable = DeviceIdentity.generate();
      final keys = _keyPair();
      twinPem = buildSelfSignedCertificatePem(
        privateKey: keys.privateKey,
        publicKey: keys.publicKey,
        commonName: printable.certificate.commonName,
        serialNumber: _serial(),
        utf8CommonName: true,
      );
      twinKeyPem = CryptoUtils.encodeEcPrivateKeyToPem(keys.privateKey);
    });

    test('a UTF8String twin with the same name and another key is not '
        'readable: its name is not the one of its key', () {
      final twinDer = _derOf(twinPem);
      expect(
        derBytes(twinDer, _layoutOf(twinDer).tbs[5]),
        _nameOf(derUtf8(printable.certificate.commonName)),
      );
      expect(
        printable.certificate.commonName,
        commonNameForSpki(parseCertificate(printable.certificateDer).spki),
      );

      expect(PeerCertificate.tryParse(twinPem), isNull);
      expect(
        DeviceIdentity.fromPem(
          certificatePem: twinPem,
          privateKeyPem: twinKeyPem,
        ),
        isNull,
      );
    });

    Future<
      ({_Attempt printable, _Attempt twin, int handled, List<String> seen})
    >
    run({required bool twinFirst}) async {
      final counting = await _CountingServer.start(
        server.serverContext(
          trustedCertificatesPem: twinFirst
              ? [twinPem, printable.certificatePem]
              : [printable.certificatePem, twinPem],
        ),
      );
      addTearDown(counting.close);
      final fromPrintable = await _get(
        counting.port,
        printable.clientContext(presentCertificate: true),
        server.fingerprint,
      );
      final fromTwin = await _get(
        counting.port,
        _presenting(twinPem, twinKeyPem),
        server.fingerprint,
      );
      return (
        printable: fromPrintable,
        twin: fromTwin,
        handled: counting.handled,
        seen: counting.clients,
      );
    }

    for (final twinFirst in [false, true]) {
      test('twin ${twinFirst ? 'first' : 'second'}: the paired certificate '
          'reaches HTTP and the twin is cut in the handshake', () async {
        final outcome = await run(twinFirst: twinFirst);

        expect(outcome.printable.status, HttpStatus.notFound);
        expect(outcome.twin.status, isNull);
        expect(outcome.twin.error, isA<IOException>());
        expect(outcome.handled, 1);
        expect(outcome.seen, [printable.fingerprint]);
      });
    }

    test('control: the twin alone is skipped and cut, the paired one alone '
        'reaches HTTP', () async {
      final twinOnly = await _CountingServer.start(
        server.serverContext(trustedCertificatesPem: [twinPem]),
      );
      addTearDown(twinOnly.close);
      final printableOnly = await _CountingServer.start(
        server.serverContext(
          trustedCertificatesPem: [printable.certificatePem],
        ),
      );
      addTearDown(printableOnly.close);

      final twin = await _get(
        twinOnly.port,
        _presenting(twinPem, twinKeyPem),
        server.fingerprint,
      );
      final paired = await _get(
        printableOnly.port,
        printable.clientContext(presentCertificate: true),
        server.fingerprint,
      );

      expect(twin.status, isNull);
      expect(twinOnly.handled, 0);
      expect(paired.status, HttpStatus.notFound, reason: '${paired.error}');
      expect(printableOnly.clients, [printable.fingerprint]);
    });
  });

  group('C92 canonical subject in BoringSSL (RF-93, SEC-17)', () {
    late DeviceIdentity server;
    late String serverPrivateKeyPem;
    late DeviceIdentity a;

    setUpAll(() {
      server = DeviceIdentity.generate();
      serverPrivateKeyPem = _privateKeyPemOf(server);
      a = DeviceIdentity.generate();
    });

    String impostor(String commonName, {bool utf8CommonName = false}) {
      final keys = _keyPair();
      return buildSelfSignedCertificatePem(
        privateKey: keys.privateKey,
        publicKey: keys.publicKey,
        commonName: commonName,
        serialNumber: _serial(),
        utf8CommonName: utf8CommonName,
      );
    }

    SecurityContext trusting(List<String> pems) {
      final context = _presenting(server.certificatePem, serverPrivateKeyPem);
      for (final pem in pems) {
        context.setTrustedCertificatesBytes(utf8.encode(pem));
      }
      return context;
    }

    Future<({_Attempt outcome, int handled})> attempt(List<String> pems) async {
      final counting = await _CountingServer.start(trusting(pems));
      addTearDown(counting.close);
      final outcome = await _get(
        counting.port,
        a.clientContext(presentCertificate: true),
        server.fingerprint,
      );
      return (outcome: outcome, handled: counting.handled);
    }

    test('control: trusting only A, A reaches HTTP', () async {
      final result = await attempt([a.certificatePem]);

      expect(result.outcome.status, HttpStatus.notFound);
      expect(result.handled, 1);
    });

    final variants = <String, String Function()>{
      '(1) the name in capitals': () =>
          impostor(a.certificate.commonName.toUpperCase()),
      '(2) UTF8String': () =>
          impostor(a.certificate.commonName, utf8CommonName: true),
      '(3) spaces before and after': () =>
          impostor('  ${a.certificate.commonName}  '),
    };

    for (final MapEntry(key: label, value: build) in variants.entries) {
      test('variant $label trusted before A cuts A in the handshake', () async {
        final x = build();
        expect(_derOf(x), isNot(a.certificateDer));
        expect(PeerCertificate.tryParse(x)?.fingerprint, isNot(a.fingerprint));

        final result = await attempt([x, a.certificatePem]);

        expect(result.outcome.status, isNull, reason: label);
        expect(result.outcome.error, isA<IOException>(), reason: label);
        expect(result.handled, 0, reason: label);
      });
    }

    test(
      'control: an impostor with another canonical name does not cut A',
      () async {
        final result = await attempt([
          impostor('NexusBridges-fedcba9876543210'),
          a.certificatePem,
        ]);

        expect(result.outcome.status, HttpStatus.notFound);
        expect(result.handled, 1);
      },
    );
  });

  group('serverContext skips unreadable and repeated trusted certificates', () {
    late DeviceIdentity server;
    late DeviceIdentity carol;
    late String bobTwinPem;
    late String bobTwinKeyPem;
    late DeviceIdentity readableByTls;

    setUpAll(() {
      server = DeviceIdentity.generate();
      carol = DeviceIdentity.generate();
      final twinKeys = _keyPair();
      bobTwinPem = buildSelfSignedCertificatePem(
        privateKey: twinKeys.privateKey,
        publicKey: twinKeys.publicKey,
        commonName: bob.certificate.commonName,
        serialNumber: _serial(),
      );
      bobTwinKeyPem = CryptoUtils.encodeEcPrivateKeyToPem(twinKeys.privateKey);
      final keys = _keyPair();
      readableByTls = DeviceIdentity.fromPem(
        certificatePem: buildSelfSignedCertificatePem(
          privateKey: keys.privateKey,
          publicKey: keys.publicKey,
          commonName: commonNameForSpki(spkiOf(keys.publicKey)),
          serialNumber: _serial(),
        ),
        privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(keys.privateKey),
      )!;
    });

    String unreadableButTlsValid() {
      final keys = _keyPair();
      return buildSelfSignedCertificatePem(
        privateKey: keys.privateKey,
        publicKey: keys.publicKey,
        commonName: 'NexusBridges-alice',
        serialNumber: _serial(),
      );
    }

    test('never throws, skips the unreadable and the repeated, and the valid '
        'ones keep mutual TLS', () async {
      final keys = _keyPair();
      final rejectedPem = buildSelfSignedCertificatePem(
        privateKey: keys.privateKey,
        publicKey: keys.publicKey,
        commonName: 'NexusBridges-alice',
        serialNumber: _serial(),
      );
      final rejectedKeyPem = CryptoUtils.encodeEcPrivateKeyToPem(
        keys.privateKey,
      );
      expect(PeerCertificate.tryParse(rejectedPem), isNull);
      expect(PeerCertificate.tryParse(bobTwinPem), isNull);
      final trusted = [
        'garbage',
        '',
        '-----BEGIN CERTIFICATE-----\n@@@@\n-----END CERTIFICATE-----\n',
        alicePrivateKeyPem,
        bob.certificatePem,
        rejectedPem,
        bobTwinPem,
        carol.certificatePem,
        unreadableButTlsValid(),
        readableByTls.certificatePem,
      ];

      late SecurityContext context;
      expect(
        () => context = server.serverContext(trustedCertificatesPem: trusted),
        returnsNormally,
      );
      final counting = await _CountingServer.start(context);
      addTearDown(counting.close);

      Future<_Attempt> from(SecurityContext client) =>
          _get(counting.port, client, server.fingerprint);

      final fromBob = await from(bob.clientContext(presentCertificate: true));
      final fromCarol = await from(
        carol.clientContext(presentCertificate: true),
      );
      final fromLast = await from(
        readableByTls.clientContext(presentCertificate: true),
      );
      final fromTwin = await from(_presenting(bobTwinPem, bobTwinKeyPem));
      final fromRejected = await from(_presenting(rejectedPem, rejectedKeyPem));

      expect(fromBob.status, HttpStatus.notFound, reason: '${fromBob.error}');
      expect(fromCarol.status, HttpStatus.notFound);
      expect(fromLast.status, HttpStatus.notFound);
      expect(fromTwin.status, isNull);
      expect(fromRejected.status, isNull);
      expect(counting.clients, [
        bob.fingerprint,
        carol.fingerprint,
        readableByTls.fingerprint,
      ]);
    });

    test('control: BoringSSL itself would trust the certificate our parser '
        'rejects', () async {
      final keys = _keyPair();
      final rejectedPem = buildSelfSignedCertificatePem(
        privateKey: keys.privateKey,
        publicKey: keys.publicKey,
        commonName: 'NexusBridges-alice',
        serialNumber: _serial(),
      );
      final rejectedKeyPem = CryptoUtils.encodeEcPrivateKeyToPem(
        keys.privateKey,
      );
      final serverKeyPem = _privateKeyPemOf(server);
      final byHand = _presenting(server.certificatePem, serverKeyPem)
        ..setTrustedCertificatesBytes(utf8.encode(rejectedPem));
      final counting = await _CountingServer.start(byHand);
      addTearDown(counting.close);

      final outcome = await _get(
        counting.port,
        _presenting(rejectedPem, rejectedKeyPem),
        server.fingerprint,
      );

      expect(outcome.status, HttpStatus.notFound, reason: '${outcome.error}');
      expect(counting.handled, 1);
    });

    test('the same name with another key alone is skipped too, and it is '
        'cut in the handshake', () async {
      final counting = await _CountingServer.start(
        server.serverContext(trustedCertificatesPem: [bobTwinPem]),
      );
      addTearDown(counting.close);

      final outcome = await _get(
        counting.port,
        _presenting(bobTwinPem, bobTwinKeyPem),
        server.fingerprint,
      );

      expect(outcome.status, isNull);
      expect(counting.handled, 0);
    });
  });

  group('the point of the key is on P-256 (V6)', () {
    late _KeyPair keys;

    setUpAll(() {
      keys = _keyPair();
    });

    Uint8List withPoint(BigInt x, BigInt y) {
      final point = Uint8List.fromList([
        0x04,
        ..._bigEndian32(x),
        ..._bigEndian32(y),
      ]);
      final spki = derSequence([
        derSequence([derOid(_oidEcPublicKey), derOid(_oidPrime256v1)]),
        derBitString(point),
      ]);
      return _handBuilt(
        keys,
        point: point,
        commonName: commonNameForSpki(spki),
      );
    }

    test('control: the real point, written the same way, is read', () {
      final encoded = keys.publicKey.Q!.getEncoded(false);
      final der = withPoint(
        _bigInt(encoded.sublist(1, 33)),
        _bigInt(encoded.sublist(33, 65)),
      );

      expect(PeerCertificate.fromDer(der), isNotNull);
      expect(
        fingerprintOfCertificate(der),
        PeerCertificate.fromDer(_handBuilt(keys))!.fingerprint,
      );
    });

    test('a point off the curve gives null and is not readable', () {
      final encoded = keys.publicKey.Q!.getEncoded(false);
      final x = _bigInt(encoded.sublist(1, 33));
      final y = _bigInt(encoded.sublist(33, 65));
      final cases = <String, Uint8List>{
        'y + 1': withPoint(x, (y + BigInt.one) % _fieldPrime),
        'x + 1': withPoint((x + BigInt.one) % _fieldPrime, y),
        '(0, 0)': withPoint(BigInt.zero, BigInt.zero),
        '(1, 1)': withPoint(BigInt.one, BigInt.one),
      };

      for (final MapEntry(key: label, value: der) in cases.entries) {
        _expectRejected(der, label);
        expect(
          () => fingerprintOfCertificate(der),
          throwsA(isA<FormatException>()),
          reason: label,
        );
      }
    });

    test('x written as x + p passes the curve equation modulo p and is still '
        'rejected', () {
      final (x, y) = _smallPoint();
      expect(
        (y * y - (x * x * x - BigInt.from(3) * x + _curveB)) % _fieldPrime,
        BigInt.zero,
      );
      expect(PeerCertificate.fromDer(withPoint(x, y)), isNotNull);

      _expectRejected(withPoint(x + _fieldPrime, y), 'x + p');
    });

    test('x or y equal to or above p give null', () {
      final (x, y) = _smallPoint();
      final top = (BigInt.one << 256) - BigInt.one;
      final cases = <String, Uint8List>{
        'x = p': withPoint(_fieldPrime, y),
        'y = p': withPoint(x, _fieldPrime),
        'y = p + 2': withPoint(x, _fieldPrime + BigInt.two),
        'x all ones': withPoint(top, y),
        'y all ones': withPoint(x, top),
      };

      for (final MapEntry(key: label, value: der) in cases.entries) {
        _expectRejected(der, label);
      }
    });
  });

  group('no extensions: a certificate cannot act as a CA (Q-4)', () {
    late _KeyPair caKeys;
    late String caName;
    late String caPem;
    late String caKeyPem;
    late DeviceIdentity server;
    late String serverKeyPem;

    setUpAll(() {
      caKeys = _keyPair();
      caName = _boundName(caKeys);
      caPem = _pemOf(
        _issued(
          subject: caName,
          issuer: caName,
          subjectKeys: caKeys,
          signer: caKeys,
          extensions: _caExtensions(),
        ),
      );
      caKeyPem = CryptoUtils.encodeEcPrivateKeyToPem(caKeys.privateKey);
      server = DeviceIdentity.generate();
      serverKeyPem = _privateKeyPemOf(server);
    });

    test('a certificate with basicConstraints CA:TRUE gives null even with '
        'its own name bound to its key', () {
      final der = _derOf(caPem);
      expect(_layoutOf(der).tbs.last.tag, 0xA3);

      _expectRejected(der, 'CA:TRUE');
      expect(
        () => fingerprintOfCertificate(der),
        throwsA(isA<FormatException>()),
      );
    });

    test('any [3] after the SPKI gives null, even an empty one', () {
      final cases = <String, Uint8List>{
        'empty [3]': derExplicit(3, derSequence([])),
        'CA:TRUE': _caExtensions(),
        'keyUsage keyCertSign': derExplicit(
          3,
          derSequence([
            derSequence([
              derOid(const [0x55, 0x1D, 0x0F]),
              _bytes([0x01, 0x01, 0xFF]),
              _bytes([0x04, 0x04, 0x03, 0x02, 0x02, 0x04]),
            ]),
          ]),
        ),
      };

      for (final MapEntry(key: label, value: extra) in cases.entries) {
        _expectRejected(_handBuilt(caKeys, afterSpki: [extra]), label);
      }
    });

    test('control: the same certificate without the [3] is read', () {
      final der = _issued(
        subject: caName,
        issuer: caName,
        subjectKeys: caKeys,
        signer: caKeys,
      );

      expect(PeerCertificate.fromDer(der)?.commonName, caName);
    });

    Future<({_Attempt outcome, int handled})> presentLeaf(
      SecurityContext serverContext,
    ) async {
      final leafKeys = _keyPair();
      final leafPem = _pemOf(
        _issued(
          subject: _boundName(leafKeys),
          issuer: caName,
          subjectKeys: leafKeys,
          signer: caKeys,
        ),
      );
      final counting = await _CountingServer.start(serverContext);
      addTearDown(counting.close);
      final outcome = await _get(
        counting.port,
        _presenting(
          leafPem,
          CryptoUtils.encodeEcPrivateKeyToPem(leafKeys.privateKey),
        ),
        server.fingerprint,
      );
      return (outcome: outcome, handled: counting.handled);
    }

    test('control: BoringSSL alone, trusting the CA, lets a leaf it issued '
        'reach HTTP', () async {
      final byHand = _presenting(server.certificatePem, serverKeyPem)
        ..setTrustedCertificatesBytes(utf8.encode(caPem));

      final result = await presentLeaf(byHand);

      expect(
        result.outcome.status,
        HttpStatus.notFound,
        reason: '${result.outcome.error}',
      );
      expect(result.handled, 1);
    });

    test('a paired list with the CA certificate trusts nothing from it: a '
        'leaf it issued and the CA itself are cut in the handshake', () async {
      final context = server.serverContext(trustedCertificatesPem: [caPem]);

      final leaf = await presentLeaf(context);
      final counting = await _CountingServer.start(context);
      addTearDown(counting.close);
      final itself = await _get(
        counting.port,
        _presenting(caPem, caKeyPem),
        server.fingerprint,
      );

      expect(leaf.outcome.status, isNull);
      expect(leaf.handled, 0);
      expect(itself.status, isNull);
      expect(counting.handled, 0);
    });
  });
}

final BigInt _fieldPrime = BigInt.parse(
  'FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF',
  radix: 16,
);

final BigInt _curveB = BigInt.parse(
  '5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B',
  radix: 16,
);

(BigInt, BigInt) _smallPoint() {
  final exponent = (_fieldPrime + BigInt.one) >> 2;
  for (var i = 1; ; i++) {
    final x = BigInt.from(i);
    final right = (x * x * x - BigInt.from(3) * x + _curveB) % _fieldPrime;
    final y = right.modPow(exponent, _fieldPrime);
    if ((y * y) % _fieldPrime == right) return (x, y);
  }
}

Uint8List _caExtensions() => derExplicit(
  3,
  derSequence([
    derSequence([
      derOid(const [0x55, 0x1D, 0x13]),
      _bytes([0x01, 0x01, 0xFF]),
      _bytes([0x04, 0x05, 0x30, 0x03, 0x01, 0x01, 0xFF]),
    ]),
  ]),
);

Uint8List _issued({
  required String subject,
  required String issuer,
  required _KeyPair subjectKeys,
  required _KeyPair signer,
  Uint8List? extensions,
}) {
  final algorithm = derSequence([derOid(_oidEcdsaWithSha256)]);
  final tbs = derSequence([
    derExplicit(0, derInteger(_bytes([2]))),
    derInteger(_serial()),
    algorithm,
    _nameOf(derPrintable(issuer)),
    derSequence([
      derUtcTime('000101000000Z'),
      derGeneralizedTime('99991231235959Z'),
    ]),
    _nameOf(derPrintable(subject)),
    spkiOf(subjectKeys.publicKey),
    ?extensions,
  ]);
  final signature = CryptoUtils.ecSign(
    signer.privateKey,
    tbs,
    algorithmName: 'SHA-256/ECDSA',
  );
  return derSequence([
    tbs,
    algorithm,
    derBitString(
      derSequence([
        derIntegerFromBigInt(signature.r),
        derIntegerFromBigInt(signature.s),
      ]),
    ),
  ]);
}
