import 'dart:convert';
import 'dart:io';

import '../identity/identity.dart';
import '../protocol/protocol.dart';
import '../transport/transport.dart';

export '../transport/transport.dart' show AbortSignal;

final class DeviceVerifier {
  DeviceVerifier({required this._identity});

  final DeviceIdentity _identity;

  Future<DeviceInfo?> register({
    required InternetAddress address,
    required int port,
    required String? expectedFingerprint,
    required DeviceInfo self,
    Duration timeout = const Duration(seconds: 10),
    AbortSignal? abort,
  }) async {
    String? seen;
    try {
      final response = await postJson(
        address: address,
        port: port,
        path: ApiPaths.register,
        json: self.toJson(),
        context: _identity.clientContext(),
        acceptServer: (cert) {
          try {
            seen = fingerprintOfCertificate(cert.der);
          } catch (_) {
            return false;
          }
          return expectedFingerprint == null || seen == expectedFingerprint;
        },
        timeout: timeout,
        abort: abort,
      );
      final observed = seen;
      if (response == null || response.status != 200 || observed == null) {
        return null;
      }
      final info = DeviceInfo.tryParse(jsonDecode(utf8.decode(response.body)));
      if (info == null || info.fingerprint != observed) return null;
      if (expectedFingerprint != null &&
          info.fingerprint != expectedFingerprint) {
        return null;
      }
      return info;
    } catch (_) {
      return null;
    }
  }
}
