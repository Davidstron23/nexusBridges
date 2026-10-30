import 'dart:async';
import 'dart:typed_data';

import '../server/server.dart' show ApiUpload;
import 'manifest.dart';
import 'messages.dart' show FolderOfferRequest;

sealed class ManifestReadResult {
  const ManifestReadResult();
}

final class ManifestComplete extends ManifestReadResult {
  const ManifestComplete(this.manifest);

  final FolderManifest manifest;
}

final class ManifestRefused extends ManifestReadResult {
  const ManifestRefused(this.refusal);

  final ManifestRefusal refusal;
}

final class ManifestBroken extends ManifestReadResult {
  const ManifestBroken();
}

({int status, String error}) manifestRefusalReply(ManifestRefusal refusal) =>
    switch (refusal) {
      ManifestRefusal.incompatible => (status: 400, error: 'incompatible'),
      ManifestRefusal.invalidName => (status: 422, error: 'invalid_name'),
      ManifestRefusal.blockedType => (status: 415, error: 'blocked_type'),
      ManifestRefusal.tooLarge => (status: 413, error: 'too_large'),
    };

final class ManifestRead {
  ManifestRead._(this.result, this._abort);

  final Future<ManifestReadResult> result;
  final void Function() _abort;

  void abort() => _abort();

  static ManifestRead start({
    required ApiUpload upload,
    required FolderOfferRequest declared,
    required void Function() onActivity,
  }) {
    final reader = ManifestReader(declared);
    final done = Completer<ManifestReadResult>();
    void finish(ManifestReadResult value) {
      if (!done.isCompleted) done.complete(value);
    }

    ManifestReadResult closed() {
      final (:manifest, :refusal) = reader.close();
      if (manifest != null) return ManifestComplete(manifest);
      return ManifestRefused(refusal ?? ManifestRefusal.incompatible);
    }

    if (declared.manifestBytes == 0) {
      finish(closed());
    } else {
      upload.body.listen(
        onData: (Uint8List chunk) {
          if (done.isCompleted) return;
          onActivity();
          final refusal = reader.add(chunk);
          if (refusal != null) finish(ManifestRefused(refusal));
        },
        onDone: () => finish(closed()),
        onError: (Object _) => finish(const ManifestBroken()),
      );
    }
    return ManifestRead._(done.future, () => finish(const ManifestBroken()));
  }
}
