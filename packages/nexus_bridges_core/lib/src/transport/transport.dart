import 'dart:typed_data';

export 'raw_https.dart' show postJson, postStream;

void _noop() {}

final class AbortSignal {
  final List<void Function()> _listeners = [];

  bool _aborted = false;

  bool get aborted => _aborted;

  int get listenerCount => _listeners.length;

  void abort() {
    if (_aborted) return;
    _aborted = true;
    final pending = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final callback in pending) {
      _run(callback);
    }
  }

  void Function() onAbort(void Function() callback) {
    if (_aborted) {
      _run(callback);
      return _noop;
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }

  void _run(void Function() callback) {
    try {
      callback();
    } catch (_) {
      return;
    }
  }
}

final class HttpsResponse {
  const HttpsResponse(this.status, this.body);

  final int status;

  final Uint8List body;
}

sealed class StreamPostResult {
  const StreamPostResult();
}

final class StreamPostAnswered extends StreamPostResult {
  const StreamPostAnswered(this.response, {required this.bodyComplete});

  final HttpsResponse response;

  final bool bodyComplete;
}

final class StreamPostFailed extends StreamPostResult {
  const StreamPostFailed(this.failure, {required this.sent});

  final StreamPostFailure failure;

  final int sent;
}

enum StreamPostFailure {
  notConnected,
  sourceError,
  stalled,
  connectionLost,
  noAnswer,
  aborted,
}
