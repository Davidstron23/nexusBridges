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
    {'CN': commonNameForSpki(spkiOf(publicKey))},
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
      onBadCertificate: (c) =>
          fingerprintOfCertificate(c.der) == server.fingerprint,
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

List<int> _u16(int value) => [(value >> 8) & 0xFF, value & 0xFF];

List<int> _u24(int value) => [
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

List<int> _extension(int type, List<int> data) => [
  ..._u16(type),
  ..._u16(data.length),
  ...data,
];

Uint8List _tls12OnlyClientHello() {
  const suites = [0xC0, 0x2B, 0xC0, 0x2C, 0xCC, 0xA9, 0xC0, 0x2F, 0xC0, 0x30];
  final extensions = [
    ..._extension(0x000A, [0x00, 0x04, 0x00, 0x17, 0x00, 0x1D]),
    ..._extension(0x000B, [0x01, 0x00]),
    ..._extension(0x000D, [0x00, 0x06, 0x04, 0x03, 0x08, 0x04, 0x04, 0x01]),
    ..._extension(0xFF01, [0x00]),
  ];
  final body = [
    0x03,
    0x03,
    for (var i = 0; i < 32; i++) i,
    0x00,
    ..._u16(suites.length),
    ...suites,
    0x01,
    0x00,
    ..._u16(extensions.length),
    ...extensions,
  ];
  final handshake = [0x01, ..._u24(body.length), ...body];
  return Uint8List.fromList([
    0x16,
    0x03,
    0x01,
    ..._u16(handshake.length),
    ...handshake,
  ]);
}

Future<List<int>> _firstServerBytes(int port, List<int> hello) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final received = <int>[];
  final done = Completer<void>();
  socket.listen(
    (chunk) {
      received.addAll(chunk);
      if (received.length >= 7 && !done.isCompleted) done.complete();
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  socket.add(hello);
  try {
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    socket.destroy();
  }
  return received;
}

Future<List<int>> _capturedClientHello(SecurityContext context) async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final hello = Completer<List<int>>();
  listener.listen((socket) {
    final received = <int>[];
    socket.listen((chunk) {
      received.addAll(chunk);
      if (received.length >= 5) {
        final length = (received[3] << 8) | received[4];
        if (received.length >= 5 + length && !hello.isCompleted) {
          hello.complete(received.sublist(0, 5 + length));
          socket.destroy();
        }
      }
    }, onError: (Object _) {});
  });
  final connecting = SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    listener.port,
    context: context,
    onBadCertificate: (_) => true,
    timeout: const Duration(seconds: 5),
  ).then<void>((s) => s.destroy(), onError: (Object _) {});
  try {
    return await hello.future.timeout(const Duration(seconds: 5));
  } finally {
    await connecting;
    await listener.close();
  }
}

List<int> _offeredVersions(List<int> record) {
  int u16At(int i) => (record[i] << 8) | record[i + 1];
  var i = 5 + 4 + 2 + 32;
  i += 1 + record[i];
  i += 2 + u16At(i);
  i += 1 + record[i];
  final end = i + 2 + u16At(i);
  i += 2;
  while (i + 4 <= end) {
    final type = u16At(i);
    final length = u16At(i + 2);
    i += 4;
    if (type == 0x002B) {
      final listLength = record[i];
      return [
        for (var j = i + 1; j < i + 1 + listLength; j += 2)
          if ((u16At(j) & 0x0F0F) != 0x0A0A) u16At(j),
      ];
    }
    i += length;
  }
  return const [];
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;
  late DeviceIdentity carol;
  late String alicePrivateKeyPem;
  late String bobPrivateKeyPem;
  late String carolPrivateKeyPem;

  setUpAll(() {
    alice = DeviceIdentity.generate();
    bob = DeviceIdentity.generate();
    carol = DeviceIdentity.generate();
    alicePrivateKeyPem = _privateKeyPemOf(alice);
    bobPrivateKeyPem = _privateKeyPemOf(bob);
    carolPrivateKeyPem = _privateKeyPemOf(carol);
  });

  group('generate', () {
    test(
      'fingerprint is 64 uppercase hex chars given by fingerprintOfCertificate',
      () {
        expect(alice.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
        expect(
          alice.fingerprint,
          fingerprintOfCertificate(alice.certificateDer),
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

    test('puts the name bound to its own key in the subject', () {
      final data = X509Utils.x509CertificateFromPem(alice.certificatePem);

      expect(
        data.tbsCertificate!.subject['2.5.4.3'],
        'NexusBridges-${alice.fingerprint.substring(0, 16).toLowerCase()}',
      );
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
    List<DerElement> validityOf(DeviceIdentity identity) {
      final der = identity.certificateDer;
      final root = readDerElement(der, 0, der.length);
      final tbs = readDerChildren(der, readDerChildren(der, root).first);
      return readDerChildren(der, tbs[4]);
    }

    test('starts on 2000-01-01 as a UTCTime, read with the own reader', () {
      final validity = validityOf(alice);

      expect(validity, hasLength(2));
      expect(validity[0].tag, 0x17);
      expect(
        ascii.decode(derValue(alice.certificateDer, validity[0])),
        '000101000000Z',
      );
    });

    test('never expires: 9999-12-31 23:59:59 as a GeneralizedTime, read with '
        'the own reader', () {
      final validity = validityOf(alice);

      expect(validity[1].tag, 0x18);
      expect(
        ascii.decode(derValue(alice.certificateDer, validity[1])),
        '99991231235959Z',
      );
      expect(validityOf(bob)[1].tag, 0x18);
    });

    test('a TLS handshake that validates dates accepts it', () async {
      final outcome = await _serverOutcome(
        server: alice,
        trusted: [bob.certificatePem],
        client: _clientWithCertificate(bob.certificatePem, bobPrivateKeyPem),
      );

      expect(outcome, isA<X509Certificate>());
      expect(
        fingerprintOfCertificate((outcome as X509Certificate).der),
        bob.fingerprint,
      );
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
          ..write(
            certificate == null
                ? 'none'
                : fingerprintOfCertificate(certificate.der),
          )
          ..close();
      });
      addTearDown(() => server.close(force: true));
    }

    HttpClient pinnedClient(SecurityContext context, String fingerprint) {
      client = HttpClient(context: context)
        ..badCertificateCallback = (certificate, host, port) =>
            fingerprintOfCertificate(certificate.der) == fingerprint;
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
          fingerprintOfCertificate((fromBob as X509Certificate).der),
          bob.fingerprint,
        );
        expect(
          fingerprintOfCertificate((fromCarol as X509Certificate).der),
          carol.fingerprint,
        );
      },
    );

    test('with two subjects alike only the first is trusted', () async {
      final first = DeviceIdentity.generate();
      final pair = CryptoUtils.generateEcKeyPair();
      final secondKey = pair.privateKey as ECPrivateKey;
      final secondPem = buildSelfSignedCertificatePem(
        privateKey: secondKey,
        publicKey: pair.publicKey as ECPublicKey,
        commonName: first.certificate.commonName,
        serialNumber: Uint8List.fromList(List<int>.generate(16, (i) => i + 1)),
      );
      final trusted = [first.certificatePem, secondPem];

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
          secondPem,
          CryptoUtils.encodeEcPrivateKeyToPem(secondKey),
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

  group('serverContext skips unreadable trusted certificates (M2)', () {
    late DeviceIdentity dave;
    late String davePrivateKeyPem;

    setUpAll(() {
      dave = DeviceIdentity.generate();
      davePrivateKeyPem = _privateKeyPemOf(dave);
    });

    List<String> unreadable() => [
      'garbage',
      '',
      '-----BEGIN CERTIFICATE-----\n@@@@!!!!\n-----END CERTIFICATE-----\n',
      '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n',
      alicePrivateKeyPem,
      '\u0000\u0001\u0002',
    ];

    test('never throws, whatever the list holds', () {
      expect(
        () => alice.serverContext(trustedCertificatesPem: unreadable()),
        returnsNormally,
      );
      expect(
        () => alice.serverContext(
          trustedCertificatesPem: [
            bob.certificatePem,
            ...unreadable(),
            carol.certificatePem,
          ],
        ),
        returnsNormally,
      );
    });

    test('valid certificates around garbage are still trusted', () async {
      final trusted = [bob.certificatePem, 'garbage', '', carol.certificatePem];

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
        fingerprintOfCertificate((fromBob as X509Certificate).der),
        bob.fingerprint,
      );
      expect(
        fingerprintOfCertificate((fromCarol as X509Certificate).der),
        carol.fingerprint,
      );
    });

    test('every kind of garbage before a valid one keeps it trusted', () async {
      final outcome = await _serverOutcome(
        server: alice,
        trusted: [...unreadable(), bob.certificatePem],
        client: _clientWithCertificate(bob.certificatePem, bobPrivateKeyPem),
      );

      expect(outcome, isA<X509Certificate>(), reason: '$outcome');
      expect(
        fingerprintOfCertificate((outcome as X509Certificate).der),
        bob.fingerprint,
      );
    });

    test('a certificate outside the list is still rejected', () async {
      final outcome = await _serverOutcome(
        server: alice,
        trusted: [bob.certificatePem, 'garbage', '', carol.certificatePem],
        client: _clientWithCertificate(dave.certificatePem, davePrivateKeyPem),
      );

      expect(outcome, isA<HandshakeException>(), reason: '$outcome');
    });

    test('a list of only garbage trusts nobody', () async {
      final outcome = await _serverOutcome(
        server: alice,
        trusted: unreadable(),
        client: _clientWithCertificate(bob.certificatePem, bobPrivateKeyPem),
      );

      expect(outcome, isA<HandshakeException>(), reason: '$outcome');
    });
  });

  group('TLS 1.3 is the minimum (plan v2.6, point 6)', () {
    SecurityContext tls12Server() => SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(alice.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(alicePrivateKeyPem));

    test('both contexts declare TLS 1.3 as their minimum', () {
      expect(
        alice
            .serverContext(trustedCertificatesPem: [])
            .minimumTlsProtocolVersion,
        TlsProtocolVersion.tls1_3,
      );
      expect(
        alice
            .serverContext(trustedCertificatesPem: [bob.certificatePem])
            .minimumTlsProtocolVersion,
        TlsProtocolVersion.tls1_3,
      );
      expect(
        alice.clientContext().minimumTlsProtocolVersion,
        TlsProtocolVersion.tls1_3,
      );
    });

    test('control: a TLS 1.2 server answers the TLS 1.2 hello', () async {
      final listener = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        tls12Server(),
      );
      addTearDown(listener.close);
      listener.listen((s) => s.destroy(), onError: (Object _) {});

      final reply = await _firstServerBytes(
        listener.port,
        _tls12OnlyClientHello(),
      );

      expect(reply.length, greaterThanOrEqualTo(11));
      expect(reply[0], 0x16);
      expect(reply[5], 0x02);
      expect(reply.sublist(9, 11), [0x03, 0x03]);
    });

    test('serverContext answers a TLS 1.2 only client with an alert', () async {
      final listener = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        alice.serverContext(trustedCertificatesPem: [bob.certificatePem]),
        requestClientCertificate: true,
      );
      addTearDown(listener.close);
      final serverError = Completer<Object>();
      var accepted = 0;
      listener.listen(
        (s) {
          accepted++;
          s.destroy();
        },
        onError: (Object e) {
          if (!serverError.isCompleted) serverError.complete(e);
        },
      );

      final reply = await _firstServerBytes(
        listener.port,
        _tls12OnlyClientHello(),
      );

      expect(reply.isEmpty || reply.first == 0x15, isTrue, reason: '$reply');
      expect(reply, isNot(contains(0x16)));
      expect(
        await serverError.future.timeout(const Duration(seconds: 5)),
        isA<HandshakeException>(),
      );
      expect(accepted, 0);
    });

    test('a client that offers 1.2 and 1.3 connects with 1.3', () async {
      final defaultClient = SecurityContext(withTrustedRoots: false);
      expect(
        _offeredVersions(await _capturedClientHello(defaultClient)),
        containsAll([0x0303, 0x0304]),
      );

      final outcome = await _serverOutcome(
        server: alice,
        trusted: [bob.certificatePem],
        client: SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(bob.certificatePem))
          ..usePrivateKeyBytes(utf8.encode(bobPrivateKeyPem)),
      );

      expect(outcome, isA<X509Certificate>(), reason: '$outcome');
    });

    test('clientContext offers TLS 1.3 only', () async {
      final versions = _offeredVersions(
        await _capturedClientHello(bob.clientContext()),
      );

      expect(versions, [0x0304]);
    });

    final openssl = _findOpenssl();
    final noOpenssl = openssl == null
        ? 'openssl is not on PATH nor in Git for Windows; '
              'the raw ClientHello tests still cover TLS 1.3'
        : false;

    Future<String> opensslClient(int port, String versionFlag) async {
      final process = await Process.start(openssl!, [
        's_client',
        '-connect',
        '127.0.0.1:$port',
        versionFlag,
        '-brief',
      ]);
      final output = StringBuffer();
      final finished = Completer<void>();
      void collect(String text) {
        output.write(text);
        if (output.toString().contains('CONNECTION ESTABLISHED') &&
            !finished.isCompleted) {
          finished.complete();
        }
      }

      process.stdout.transform(utf8.decoder).listen(collect);
      process.stderr.transform(utf8.decoder).listen(collect);
      unawaited(
        process.exitCode.then((_) {
          if (!finished.isCompleted) finished.complete();
        }),
      );
      try {
        await finished.future.timeout(const Duration(seconds: 10));
      } finally {
        await process.stdin.close();
        process.kill();
        await process.exitCode;
      }
      return output.toString();
    }

    test('openssl s_client: -tls1_2 is refused and -tls1_3 connects', () async {
      final listener = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        alice.serverContext(trustedCertificatesPem: [bob.certificatePem]),
        requestClientCertificate: true,
      );
      addTearDown(listener.close);
      listener.listen((s) => s.destroy(), onError: (Object _) {});

      final old = await opensslClient(listener.port, '-tls1_2');
      final modern = await opensslClient(listener.port, '-tls1_3');

      expect(old, isNot(contains('CONNECTION ESTABLISHED')), reason: old);
      expect(old.toLowerCase(), contains('error'), reason: old);
      expect(modern, contains('CONNECTION ESTABLISHED'), reason: modern);
      expect(modern, contains('TLSv1.3'), reason: modern);
    }, skip: noOpenssl);
  });
}
