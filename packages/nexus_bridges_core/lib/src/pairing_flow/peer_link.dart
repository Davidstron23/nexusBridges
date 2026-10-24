import 'dart:convert';
import 'dart:io';

import '../identity/identity.dart';
import '../protocol/protocol.dart';
import '../transport/transport.dart';
import 'pairing_flow.dart';

final class PeerLink {
  PeerLink({
    required this._identity,
    required this._target,
    required this._abort,
  });

  final DeviceIdentity _identity;

  final PairingTarget _target;

  final AbortSignal _abort;

  PeerCertificate? _serverCertificate;

  PeerCertificate? get serverCertificate => _serverCertificate;

  Future<(int, Map<String, Object?>)?> post(
    String path,
    Map<String, Object?> body, {
    Duration timeout = Limits.pairingMessageTimeout,
    bool presentCertificate = false,
    AbortSignal? abort,
  }) async {
    try {
      final response = await postJson(
        address: _target.address,
        port: _target.port,
        path: path,
        json: body,
        context: _identity.clientContext(
          presentCertificate: presentCertificate,
        ),
        acceptServer: _acceptServer,
        sourceAddress: _target.localAddress,
        timeout: timeout,
        maxResponseBytes: Limits.maxPairingBodyBytes,
        abort: abort ?? _abort,
      );
      if (response == null) return null;
      final decoded = jsonDecode(utf8.decode(response.body));
      if (decoded is! Map<String, Object?>) return null;
      return (response.status, decoded);
    } catch (_) {
      return null;
    }
  }

  bool _acceptServer(X509Certificate certificate) {
    try {
      if (fingerprintOfCertificate(certificate.der) != _target.fingerprint) {
        return false;
      }
      final parsed = PeerCertificate.fromDer(certificate.der);
      if (parsed == null) return false;
      _serverCertificate = parsed;
      return true;
    } catch (_) {
      return false;
    }
  }
}
