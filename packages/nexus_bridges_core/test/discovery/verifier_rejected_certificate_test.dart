import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:nexus_bridges_core/src/discovery/discovery.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

final InternetAddress _loopback = InternetAddress.loopbackIPv4;
const Duration _settle = Duration(milliseconds: 200);

typedef _Served = ({String certificatePem, String privateKeyPem});

_Served _basicUtilsServer({required String curve, required String commonName}) {
  final pair = CryptoUtils.generateEcKeyPair(curve: curve);
  final privateKey = pair.privateKey as ECPrivateKey;
  final publicKey = pair.publicKey as ECPublicKey;
  final csr = X509Utils.generateEccCsrPem(
    {'CN': commonName},
    privateKey,
    publicKey,
  );
  return (
    certificatePem: X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3650,
      notBefore: DateTime.utc(2000),
    ),
    privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
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

SecurityContext _contextOf(_Served served) =>
    SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(served.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(served.privateKeyPem));

final class _CountingServer {
  _CountingServer._(this._server);

  static Future<_CountingServer> start(SecurityContext context) async {
    final server = await HttpServer.bindSecure(
      _loopback,
      0,
      context,
      requestClientCertificate: true,
    );
    final counting = _CountingServer._(server);
    server.listen(counting._handle, onError: (Object _) {});
    addTearDown(() => server.close(force: true));
    return counting;
  }

  final HttpServer _server;
  int handled = 0;

  int get port => _server.port;

  Future<void> _handle(HttpRequest request) async {
    handled++;
    try {
      await request.drain<void>();
      request.response.statusCode = 404;
      await request.response.close();
    } on Object {
      return;
    }
  }
}

void main() {
  late DeviceIdentity bob;
  late DeviceVerifier verifier;
  late DeviceInfo self;

  setUpAll(() {
    bob = DeviceIdentity.generate();
    verifier = DeviceVerifier(identity: bob);
    self = DeviceInfo(
      name: 'Bob',
      fingerprint: bob.fingerprint,
      port: 40000,
      protocol: protocolVersion,
      deviceType: DeviceType.desktop,
    );
  });

  Future<DeviceInfo?> register(int port, {String? expectedFingerprint}) =>
      verifier.register(
        address: _loopback,
        port: port,
        expectedFingerprint: expectedFingerprint,
        self: self,
        timeout: const Duration(seconds: 5),
      );

  final rejected = <String, _Served Function()>{
    'a P-384 key': () =>
        _basicUtilsServer(curve: 'secp384r1', commonName: randomCommonName()),
    'a CN outside the pattern': () =>
        _basicUtilsServer(curve: 'prime256v1', commonName: 'Server PC'),
    'a CN in uppercase': () => _basicUtilsServer(
      curve: 'prime256v1',
      commonName: randomCommonName().toUpperCase(),
    ),
  };

  group('the verifier against a certificate the parser rejects (RF-82, '
      'plan "DeviceVerifier")', () {
    rejected.forEach((name, build) {
      test('$name: the parser really rejects it and TLS really serves '
          'it', () async {
        final served = build();
        expect(
          () => fingerprintOfCertificate(_derOf(served.certificatePem)),
          throwsFormatException,
        );
        expect(PeerCertificate.tryParse(served.certificatePem), isNull);

        final socket = await SecureSocket.connect(
          _loopback,
          (await _CountingServer.start(_contextOf(served))).port,
          onBadCertificate: (_) => true,
        );
        addTearDown(socket.destroy);
        expect(socket.peerCertificate?.der, _derOf(served.certificatePem));
      });

      test('$name without an expected fingerprint gives null without '
          'throwing and never reaches the handler', () async {
        final server = await _CountingServer.start(_contextOf(build()));

        await expectLater(register(server.port), completion(isNull));
        await Future<void>.delayed(_settle);
        expect(server.handled, 0);
      });

      test('$name with an expected fingerprint gives null without throwing '
          'and never reaches the handler', () async {
        final server = await _CountingServer.start(_contextOf(build()));

        await expectLater(
          register(server.port, expectedFingerprint: bob.fingerprint),
          completion(isNull),
        );
        await Future<void>.delayed(_settle);
        expect(server.handled, 0);
      });
    });

    test('control: a valid identity behind the same counting server reaches '
        'the handler', () async {
      final alice = DeviceIdentity.generate();
      final server = await _CountingServer.start(
        alice.serverContext(trustedCertificatesPem: const []),
      );

      final info = await register(
        server.port,
        expectedFingerprint: alice.fingerprint,
      );

      expect(info, isNull);
      expect(server.handled, 1);
    });
  });
}
