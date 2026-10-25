import 'dart:convert';
import 'dart:io';

import '../identity/identity.dart' show DeviceIdentity, certificateMatches;
import '../protocol/protocol.dart' show ApiPaths, Limits, TransferHeaders;
import '../transport/transport.dart'
    show
        AbortSignal,
        StreamPostFailed,
        StreamPostFailure,
        StreamPostResult,
        postJson,
        postStream;
import 'transfer.dart' show SendTarget;

Map<String, Object?>? decodeJsonObject(List<int> body) {
  try {
    final decoded = jsonDecode(utf8.decode(body));
    return decoded is Map<String, Object?> ? decoded : null;
  } catch (_) {
    return null;
  }
}

final class TransferLink {
  TransferLink({required this._identity, required this._target});

  final DeviceIdentity _identity;

  final SendTarget _target;

  late final SecurityContext _context = _identity.clientContext(
    presentCertificate: true,
  );

  Future<(int, Map<String, Object?>)?> post(
    String path,
    Map<String, Object?> body, {
    Duration timeout = Limits.transferMessageTimeout,
    AbortSignal? abort,
  }) async {
    try {
      final response = await postJson(
        address: _target.address,
        port: _target.port,
        path: path,
        json: body,
        context: _context,
        acceptServer: _acceptServer,
        sourceAddress: _target.localAddress,
        timeout: timeout,
        maxResponseBytes: Limits.maxTransferBodyBytes,
        abort: abort,
      );
      if (response == null) return null;
      final decoded = decodeJsonObject(response.body);
      if (decoded == null) return null;
      return (response.status, decoded);
    } catch (_) {
      return null;
    }
  }

  Future<StreamPostResult> upload({
    required String transfer,
    required String permit,
    required String filePath,
    required int size,
    required void Function(int sent) onProgress,
    required void Function() onBodySent,
    required Duration idleTimeout,
    required Duration answerTimeout,
    AbortSignal? abort,
  }) async {
    try {
      return await postStream(
        address: _target.address,
        port: _target.port,
        path: ApiPaths.transferUpload,
        headers: {
          TransferHeaders.transfer: transfer,
          TransferHeaders.permit: permit,
        },
        contentLength: size,
        body: File(filePath).openRead(0, size),
        context: _context,
        acceptServer: _acceptServer,
        sourceAddress: _target.localAddress,
        idleTimeout: idleTimeout,
        answerTimeout: answerTimeout,
        maxResponseBytes: Limits.maxTransferBodyBytes,
        onProgress: onProgress,
        onBodySent: onBodySent,
        abort: abort,
      );
    } catch (_) {
      return const StreamPostFailed(StreamPostFailure.connectionLost, sent: 0);
    }
  }

  bool _acceptServer(X509Certificate certificate) =>
      certificateMatches(certificate, _target.fingerprint);
}
