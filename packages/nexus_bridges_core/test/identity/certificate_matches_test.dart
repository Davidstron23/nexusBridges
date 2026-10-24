import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:test/test.dart';

final class _Certificate implements X509Certificate {
  _Certificate(this._der);

  final Uint8List Function() _der;

  @override
  Uint8List get der => _der();

  @override
  String get pem => throw UnimplementedError();

  @override
  Uint8List get sha1 => throw UnimplementedError();

  @override
  String get subject => throw UnimplementedError();

  @override
  String get issuer => throw UnimplementedError();

  @override
  DateTime get startValidity => throw UnimplementedError();

  @override
  DateTime get endValidity => throw UnimplementedError();
}

Future<X509Certificate> _certificateSeenInTls(DeviceIdentity server) async {
  final listener = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    server.serverContext(trustedCertificatesPem: const []),
  );
  addTearDown(listener.close);
  listener.listen((socket) => socket.destroy(), onError: (Object _) {});
  X509Certificate? seen;
  final socket = await SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    listener.port,
    context: DeviceIdentity.generate().clientContext(),
    onBadCertificate: (certificate) {
      seen = certificate;
      return true;
    },
  );
  socket.destroy();
  return seen!;
}

void main() {
  late DeviceIdentity alice;
  late DeviceIdentity bob;

  setUpAll(() {
    alice = DeviceIdentity.generate();
    bob = DeviceIdentity.generate();
  });

  group('certificateMatches (RF-139, SEC-05)', () {
    test('the certificate a real TLS server presents matches its own '
        'fingerprint', () async {
      final certificate = await _certificateSeenInTls(alice);

      expect(certificateMatches(certificate, alice.fingerprint), isTrue);
    });

    test('the same certificate does not match another fingerprint', () async {
      final certificate = await _certificateSeenInTls(alice);

      expect(certificateMatches(certificate, bob.fingerprint), isFalse);
    });

    test('a certificate does not match an empty fingerprint or a short '
        'prefix of its own', () {
      final certificate = _Certificate(() => alice.certificate.der);

      expect(certificateMatches(certificate, ''), isFalse);
      expect(
        certificateMatches(certificate, shortFingerprint(alice.fingerprint)),
        isFalse,
      );
    });

    test('the DER of each identity matches only its own fingerprint', () {
      final forAlice = _Certificate(() => alice.certificate.der);
      final forBob = _Certificate(() => bob.certificate.der);

      expect(certificateMatches(forAlice, alice.fingerprint), isTrue);
      expect(certificateMatches(forAlice, bob.fingerprint), isFalse);
      expect(certificateMatches(forBob, bob.fingerprint), isTrue);
      expect(certificateMatches(forBob, alice.fingerprint), isFalse);
    });

    test('unreadable DER gives false without throwing', () {
      for (final der in [
        Uint8List(0),
        Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x01]),
        Uint8List.fromList(List<int>.filled(200, 0xFF)),
        Uint8List.sublistView(alice.certificate.der, 0, 40),
      ]) {
        expect(
          certificateMatches(_Certificate(() => der), alice.fingerprint),
          isFalse,
        );
      }
    });

    test('a certificate whose DER cannot be read gives false without '
        'throwing', () {
      final certificate = _Certificate(() => throw StateError('no der'));

      expect(certificateMatches(certificate, alice.fingerprint), isFalse);
    });
  });
}
