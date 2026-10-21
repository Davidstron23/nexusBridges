import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:test/test.dart';

final class _ReversingProtector implements SecretProtector {
  final List<Uint8List> received = [];

  @override
  Uint8List protect(Uint8List data) {
    received.add(Uint8List.fromList(data));
    return Uint8List.fromList(data.reversed.toList());
  }

  @override
  Uint8List? unprotect(Uint8List data) =>
      Uint8List.fromList(data.reversed.toList());
}

String _privateKeyPemOf(DeviceIdentity identity) {
  final protector = _ReversingProtector();
  return utf8.decode(
    protector.unprotect(identity.protectPrivateKey(protector))!,
  );
}

String _pemBody(String pem) =>
    LineSplitter.split(pem)
        .map((l) => l.trim())
        .where((l) => !l.startsWith('-----'))
        .join();

Iterable<String> _fragments(String text, {int size = 16}) sync* {
  for (var i = 0; i + size <= text.length; i += size ~/ 2) {
    yield text.substring(i, i + size);
  }
}

List<String> _privateScalarForms(String privateKeyPem) {
  final hex = CryptoUtils.ecPrivateKeyFromPem(privateKeyPem).d!
      .toRadixString(16)
      .padLeft(64, '0');
  final bytes = [
    for (var i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  return [
    hex,
    hex.toUpperCase(),
    latin1.decode(bytes),
    for (var pad = 0; pad < 3; pad++)
      ..._fragments(
        base64.encode([...List.filled(pad, 0), ...bytes]).substring(4),
      ),
  ];
}

({String certificatePem, String privateKeyPem}) _expiredCertificate() {
  final pair = CryptoUtils.generateEcKeyPair();
  final privateKey = pair.privateKey as ECPrivateKey;
  final publicKey = pair.publicKey as ECPublicKey;
  final csr = X509Utils.generateEccCsrPem(
    {'CN': 'NexusBridges-expired'},
    privateKey,
    publicKey,
  );
  return (
    certificatePem: X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      365,
      notBefore: DateTime.utc(2000),
    ),
    privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
  );
}

SecurityContext _clientWithCertificate(
  String certificatePem,
  String privateKeyPem,
) => SecurityContext(withTrustedRoots: false)
  ..useCertificateChainBytes(utf8.encode(certificatePem))
  ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

String? _findOpenssl() {
  const candidates = [
    'openssl',
    r'C:\Program Files\Git\usr\bin\openssl.exe',
    r'C:\Program Files\Git\mingw64\bin\openssl.exe',
  ];
  for (final candidate in candidates) {
    try {
      if (Process.runSync(candidate, ['version']).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

Future<Object?> _serverOutcome({
  required DeviceIdentity server,
  required List<String> trusted,
  required SecurityContext client,
}) async {
  final listener = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    server.serverContext(trustedCertificatesPem: trusted),
    requestClientCertificate: true,
  );
  final outcome = Completer<Object?>();
  listener.listen(
    (socket) {
      if (!outcome.isCompleted) outcome.complete(socket.peerCertificate);
      socket.destroy();
    },
    onError: (Object error) {
      if (!outcome.isCompleted) outcome.complete(error);
    },
  );
  SecureSocket? socket;
  try {
    socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      listener.port,
      context: client,
      onBadCertificate: (c) => fingerprintOf(c.der) == server.fingerprint,
    );
  } on IOException {
    socket = null;
  }
  try {
    return await outcome.future.timeout(const Duration(seconds: 5));
  } finally {
    socket?.destroy();
    await listener.close();
  }
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;
  late String alicePrivateKeyPem;
  late String bobPrivateKeyPem;
  late String carolPrivateKeyPem;

  setUpAll(() {
    alice = DeviceIdentity.generate(commonName: 'NexusBridges-alice');
    bob = DeviceIdentity.generate(commonName: 'NexusBridges-bob');
    carol = DeviceIdentity.generate(commonName: 'NexusBridges-carol');
    alicePrivateKeyPem = _privateKeyPemOf(alice);
    bobPrivateKeyPem = _privateKeyPemOf(bob);
    carolPrivateKeyPem = _privateKeyPemOf(carol);
  });

  group('fingerprintOf', () {
    test('matches the known SHA-256 vector of empty input', () {
      expect(
        fingerprintOf(const []),
        'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855',
      );
    });

    test('is uppercase hex of the SHA-256 digest', () {
      final bytes = utf8.encode('abc');

      expect(
        fingerprintOf(bytes),
        sha256.convert(bytes).toString().toUpperCase(),
      );
    });
  });

  group('generate', () {
    test(
      'fingerprint is 64 uppercase hex chars equal to SHA-256 of the DER',
      () {
        expect(alice.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
        expect(
          alice.fingerprint,
          sha256.convert(alice.certificateDer).toString().toUpperCase(),
        );
      },
    );

    test('certificateDer is the DER inside certificatePem', () {
      expect(alice.certificatePem, startsWith('-----BEGIN CERTIFICATE-----'));
      expect(
        alice.certificateDer,
        base64.decode(_pemBody(alice.certificatePem)),
      );
    });

    test('puts the given common name in the subject', () {
      final data = X509Utils.x509CertificateFromPem(alice.certificatePem);

      expect(data.tbsCertificate!.subject['2.5.4.3'], 'NexusBridges-alice');
    });

    test('uses an EC P-256 key', () {
      final data = X509Utils.x509CertificateFromPem(alice.certificatePem);

      expect(
        data.tbsCertificate!.subjectPublicKeyInfo.parameterReadableName,
        'prime256v1',
      );
    });

    test('gives a different fingerprint on each call', () {
      expect({
        alice.fingerprint,
        bob.fingerprint,
        carol.fingerprint,
      }, hasLength(3));
    });
  });

  group('validity (RF-9)', () {
    test('is 2000-01-01 to 2049-12-31 according to basic_utils', () {
      final validity = X509Utils.x509CertificateFromPem(alice.certificatePem)
          .tbsCertificate!
          .validity;

      expect(validity.notBefore, DateTime.utc(2000));
      expect(validity.notAfter, DateTime.utc(2049, 12, 31));
    });

    final openssl = _findOpenssl();
    test(
      'is 2000-01-01 to 2049-12-31 according to openssl, which verifies it',
      () async {
        final dir = await Directory.systemTemp.createTemp('nexus_identity_');
        addTearDown(() => dir.delete(recursive: true));
        final pem = File('${dir.path}${Platform.pathSeparator}cert.pem');
        await pem.writeAsString(alice.certificatePem);

        final dates = await Process.run(openssl!, [
          'x509',
          '-in',
          pem.path,
          '-noout',
          '-dates',
        ]);
        expect(dates.exitCode, 0, reason: '${dates.stderr}');
        expect(
          LineSplitter.split(dates.stdout as String).map((l) => l.trim()),
          [
            'notBefore=Jan  1 00:00:00 2000 GMT',
            'notAfter=Dec 31 00:00:00 2049 GMT',
          ],
        );

        final verify = await Process.run(openssl, [
          'verify',
          '-CAfile',
          pem.path,
          pem.path,
        ]);
        expect(verify.exitCode, 0, reason: '${verify.stdout}${verify.stderr}');
      },
      skip: openssl == null
          ? 'openssl is not on PATH nor in Git for Windows; '
                'the basic_utils and TLS tests still cover the dates'
          : false,
    );

    test('a TLS handshake that validates dates accepts it', () async {
      final outcome = await _serverOutcome(
        server: alice,
        trusted: [bob.certificatePem],
        client: _clientWithCertificate(bob.certificatePem, bobPrivateKeyPem),
      );

      expect(outcome, isA<X509Certificate>());
      expect(fingerprintOf((outcome as X509Certificate).der), bob.fingerprint);
    });

    test(
      'control: the same handshake rejects an expired certificate',
      () async {
        final expired = _expiredCertificate();

        final outcome = await _serverOutcome(
          server: alice,
          trusted: [expired.certificatePem],
          client: _clientWithCertificate(
            expired.certificatePem,
            expired.privateKeyPem,
          ),
        );

        expect(outcome, isA<HandshakeException>());
        expect('$outcome', contains('expired'));
      },
    );
  });

  group('private key (RF-3)', () {
    test('toString has the fingerprint and no PEM material', () {
      final text = alice.toString();

      expect(text, 'DeviceIdentity(${alice.fingerprint})');
      expect(text, isNot(contains('PRIVATE KEY')));
      expect(text, isNot(contains('CERTIFICATE')));
      for (final fragment in [
        ..._fragments(_pemBody(alicePrivateKeyPem)),
        ..._fragments(_pemBody(alice.certificatePem)),
      ]) {
        expect(text, isNot(contains(fragment)));
      }
    });

    test('no public getter exposes the private key', () {
      final secretForms = _privateScalarForms(alicePrivateKeyPem);
      final keyDer = latin1.decode(base64.decode(_pemBody(alicePrivateKeyPem)));
      final exposed = <String, String>{
        'certificatePem': alice.certificatePem,
        'certificateDer': latin1.decode(alice.certificateDer),
        'fingerprint': alice.fingerprint,
        'toString': alice.toString(),
      };

      for (final MapEntry(key: name, value: text) in exposed.entries) {
        expect(text, isNot(contains('PRIVATE KEY')), reason: name);
        expect(text, isNot(contains(keyDer)), reason: name);
        for (final form in secretForms) {
          expect(text, isNot(contains(form)), reason: name);
        }
      }
      final dynamic untyped = alice;
      expect(() => untyped.privateKeyPem, throwsNoSuchMethodError);
      expect(() => untyped.privateKey, throwsNoSuchMethodError);
    });

    test('protectPrivateKey hands the key PEM to the protector only', () {
      final protector = _ReversingProtector();

      final protected = alice.protectPrivateKey(protector);

      expect(protector.received, hasLength(1));
      expect(utf8.decode(protector.received.single), contains('PRIVATE KEY'));
      expect(protected, protector.received.single.reversed.toList());
      expect(latin1.decode(protected), isNot(contains('PRIVATE KEY')));
    });
  });

  group('fromPem', () {
    test('round-trips to the same fingerprint', () {
      final loaded = DeviceIdentity.fromPem(
        certificatePem: alice.certificatePem,
        privateKeyPem: alicePrivateKeyPem,
      );

      expect(loaded, isNotNull);
      expect(loaded!.fingerprint, alice.fingerprint);
      expect(loaded.certificatePem, alice.certificatePem);
      expect(loaded.certificateDer, alice.certificateDer);
    });

    test('protect, unprotect and fromPem recover the same identity', () {
      final protector = _ReversingProtector();
      final stored = alice.protectPrivateKey(protector);

      final loaded = DeviceIdentity.fromPem(
        certificatePem: alice.certificatePem,
        privateKeyPem: utf8.decode(protector.unprotect(stored)!),
      );

      expect(loaded?.fingerprint, alice.fingerprint);
    });

    test('returns null with the private key of another identity', () {
      expect(
        DeviceIdentity.fromPem(
          certificatePem: alice.certificatePem,
          privateKeyPem: bobPrivateKeyPem,
        ),
        isNull,
      );
    });

    test('returns null and never throws with unreadable input', () {
      final keyBody = _pemBody(alicePrivateKeyPem);
      final truncatedKey = alicePrivateKeyPem.replaceFirst(
        keyBody.substring(0, 64),
        keyBody.substring(0, 20),
      );
      final certBody = _pemBody(alice.certificatePem);
      final truncatedCert = alice.certificatePem.replaceFirst(
        certBody.substring(0, 64),
        certBody.substring(0, 20),
      );
      final cases = <String, (String, String)>{
        'both empty': ('', ''),
        'empty key': (alice.certificatePem, ''),
        'empty certificate': ('', alicePrivateKeyPem),
        'garbage': ('not a pem', 'not a pem either'),
        'garbage base64 key': (
          alice.certificatePem,
          '-----BEGIN EC PRIVATE KEY-----\n!!!!\n-----END EC PRIVATE KEY-----',
        ),
        'truncated key': (alice.certificatePem, truncatedKey),
        'truncated certificate': (truncatedCert, alicePrivateKeyPem),
        'swapped': (alicePrivateKeyPem, alice.certificatePem),
      };

      for (final MapEntry(key: label, value: (cert, key)) in cases.entries) {
        expect(
          () =>
              DeviceIdentity.fromPem(certificatePem: cert, privateKeyPem: key),
          returnsNormally,
          reason: label,
        );
        expect(
          DeviceIdentity.fromPem(certificatePem: cert, privateKeyPem: key),
          isNull,
          reason: label,
        );
      }
    });
  });

  group('serverContext and clientContext over HTTPS', () {
    late HttpServer server;
    late HttpClient client;
    late int handled;

    Future<void> startServer({
      required List<String> trusted,
      bool requestClientCertificate = false,
    }) async {
      handled = 0;
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        alice.serverContext(trustedCertificatesPem: trusted),
        requestClientCertificate: requestClientCertificate,
      );
      server.listen((request) {
        handled++;
        final certificate = request.certificate;
        request.response
          ..write(certificate == null ? 'none' : fingerprintOf(certificate.der))
          ..close();
      });
      addTearDown(() => server.close(force: true));
    }

    HttpClient pinnedClient(SecurityContext context, String fingerprint) {
      client = HttpClient(context: context)
        ..badCertificateCallback = (certificate, host, port) =>
            fingerprintOf(certificate.der) == fingerprint;
      addTearDown(() => client.close(force: true));
      return client;
    }

    Future<String> get(HttpClient client) async {
      final request = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/'),
      );
      final response = await request.close();
      return response.transform(utf8.decoder).join();
    }

    test('a client pinning the server fingerprint connects', () async {
      await startServer(trusted: []);

      final body = await get(
        pinnedClient(bob.clientContext(), alice.fingerprint),
      );

      expect(body, 'none');
      expect(handled, 1);
    });

    test('a client pinning another fingerprint fails the handshake', () async {
      await startServer(trusted: []);

      await expectLater(
        get(pinnedClient(bob.clientContext(), bob.fingerprint)),
        throwsA(isA<HandshakeException>()),
      );
      expect(handled, 0);
    });

    test('clientContext trusts no root on its own', () async {
      await startServer(trusted: []);
      client = HttpClient(context: bob.clientContext());
      addTearDown(() => client.close(force: true));

      await expectLater(get(client), throwsA(isA<HandshakeException>()));
      expect(handled, 0);
    });

    test('a client certificate in the trusted list is accepted', () async {
      await startServer(
        trusted: [bob.certificatePem],
        requestClientCertificate: true,
      );

      final body = await get(
        pinnedClient(
          _clientWithCertificate(bob.certificatePem, bobPrivateKeyPem),
          alice.fingerprint,
        ),
      );

      expect(body, bob.fingerprint);
    });

    test('a client certificate not in the trusted list is rejected', () async {
      await startServer(
        trusted: [bob.certificatePem],
        requestClientCertificate: true,
      );

      await expectLater(
        get(
          pinnedClient(
            _clientWithCertificate(carol.certificatePem, carolPrivateKeyPem),
            alice.fingerprint,
          ),
        ),
        throwsA(isA<IOException>()),
      );
      expect(handled, 0);
    });

    test(
      'a client without certificate is still served when one is requested',
      () async {
        await startServer(
          trusted: [bob.certificatePem],
          requestClientCertificate: true,
        );

        final body = await get(
          pinnedClient(bob.clientContext(), alice.fingerprint),
        );

        expect(body, 'none');
      },
    );
  });

  group('serverContext trusted list', () {
    test(
      'trusts every certificate in the list when the subjects differ',
      () async {
        final trusted = [bob.certificatePem, carol.certificatePem];

        final fromBob = await _serverOutcome(
          server: alice,
          trusted: trusted,
          client: _clientWithCertificate(bob.certificatePem, bobPrivateKeyPem),
        );
        final fromCarol = await _serverOutcome(
          server: alice,
          trusted: trusted,
          client: _clientWithCertificate(
            carol.certificatePem,
            carolPrivateKeyPem,
          ),
        );

        expect(fromBob, isA<X509Certificate>(), reason: '$fromBob');
        expect(fromCarol, isA<X509Certificate>(), reason: '$fromCarol');
        expect(
          fingerprintOf((fromBob as X509Certificate).der),
          bob.fingerprint,
        );
        expect(
          fingerprintOf((fromCarol as X509Certificate).der),
          carol.fingerprint,
        );
      },
    );

    test('with two subjects alike only the first is trusted', () async {
      final first = DeviceIdentity.generate(commonName: 'NexusBridges-twin');
      final second = DeviceIdentity.generate(commonName: 'NexusBridges-twin');
      final trusted = [first.certificatePem, second.certificatePem];

      final fromFirst = await _serverOutcome(
        server: alice,
        trusted: trusted,
        client: _clientWithCertificate(
          first.certificatePem,
          _privateKeyPemOf(first),
        ),
      );
      final fromSecond = await _serverOutcome(
        server: alice,
        trusted: trusted,
        client: _clientWithCertificate(
          second.certificatePem,
          _privateKeyPemOf(second),
        ),
      );

      expect(fromFirst, isA<X509Certificate>(), reason: '$fromFirst');
      expect(fromSecond, isA<HandshakeException>(), reason: '$fromSecond');
    });

    test('with an empty list rejects any client certificate', () async {
      final outcome = await _serverOutcome(
        server: alice,
        trusted: [],
        client: _clientWithCertificate(bob.certificatePem, bobPrivateKeyPem),
      );

      expect(outcome, isA<HandshakeException>());
    });
  });
}
