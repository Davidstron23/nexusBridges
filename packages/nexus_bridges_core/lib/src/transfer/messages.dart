import '../protocol/protocol.dart' show Limits, protocolVersion;
import 'transfer.dart' show TransferOutcome;

const int _maxProtocolLength = 16;

final RegExp _protocolPattern = RegExp(r'^\d+\.\d+$');
final RegExp _transferIdPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

const String _errorKey = 'error';

Map<Object?, Object?>? _objectWithKeys(Object? json, Set<String> keys) {
  if (json is! Map<Object?, Object?> || json.length != keys.length) {
    return null;
  }
  if (!keys.every(json.containsKey)) return null;
  return json;
}

String? _transferId(Object? value) =>
    value is String && _transferIdPattern.hasMatch(value) ? value : null;

bool _compatibleProtocol(Object? value) {
  if (value is! String ||
      value.length > _maxProtocolLength ||
      !_protocolPattern.hasMatch(value)) {
    return false;
  }
  final major = int.tryParse(value.split('.').first);
  final ownMajor = int.tryParse(protocolVersion.split('.').first);
  return major != null && major == ownMajor;
}

final class OfferRequest {
  const OfferRequest({
    required this.transfer,
    required this.name,
    required this.size,
    required this.sha256,
  });

  final String transfer;
  final String name;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
    'protocol': protocolVersion,
    'transfer': transfer,
    'name': name,
    'size': size,
    'sha256': sha256,
  };

  static OfferRequest? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {
      'protocol',
      'transfer',
      'name',
      'size',
      'sha256',
    });
    if (map == null || !_compatibleProtocol(map['protocol'])) return null;
    final transfer = _transferId(map['transfer']);
    final name = map['name'];
    final size = map['size'];
    final sha256 = map['sha256'];
    if (transfer == null || name is! String) return null;
    if (size is! int || size < 0 || size > Limits.maxTransferSize) return null;
    if (sha256 is! String || !_sha256Pattern.hasMatch(sha256)) return null;
    return OfferRequest(
      transfer: transfer,
      name: name,
      size: size,
      sha256: sha256,
    );
  }
}

const int _maxLongestPath = 32767;

final class FolderOfferRequest {
  const FolderOfferRequest({
    required this.transfer,
    required this.name,
    required this.entries,
    required this.files,
    required this.bytes,
    required this.depth,
    required this.longest,
    required this.manifestBytes,
  });

  final String transfer;
  final String name;
  final int entries;
  final int files;
  final int bytes;
  final int depth;
  final int longest;
  final int manifestBytes;

  Map<String, Object?> toJson() => {
    'protocol': protocolVersion,
    'transfer': transfer,
    'kind': 'folder',
    'name': name,
    'entries': entries,
    'files': files,
    'bytes': bytes,
    'depth': depth,
    'longest': longest,
    'manifestBytes': manifestBytes,
  };

  bool get exceedsLimits =>
      entries > Limits.maxFolderEntries ||
      depth > Limits.maxFolderDepth ||
      manifestBytes > Limits.maxManifestBytes;

  static FolderOfferRequest? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {
      'protocol',
      'transfer',
      'kind',
      'name',
      'entries',
      'files',
      'bytes',
      'depth',
      'longest',
      'manifestBytes',
    });
    if (map == null || !_compatibleProtocol(map['protocol'])) return null;
    final transfer = _transferId(map['transfer']);
    final name = map['name'];
    final entries = map['entries'];
    final files = map['files'];
    final bytes = map['bytes'];
    final depth = map['depth'];
    final longest = map['longest'];
    final manifestBytes = map['manifestBytes'];
    if (transfer == null || map['kind'] != 'folder' || name is! String) {
      return null;
    }
    if (entries is! int || entries < 0) return null;
    if (files is! int || files < 0 || files > entries) return null;
    if (bytes is! int || bytes < 0 || bytes > Limits.maxTransferSize) {
      return null;
    }
    if (depth is! int || depth < 0) return null;
    if (longest is! int || longest < 0 || longest > _maxLongestPath) {
      return null;
    }
    if (manifestBytes is! int ||
        manifestBytes < 0 ||
        manifestBytes < entries * 6) {
      return null;
    }
    return FolderOfferRequest(
      transfer: transfer,
      name: name,
      entries: entries,
      files: files,
      bytes: bytes,
      depth: depth,
      longest: longest,
      manifestBytes: manifestBytes,
    );
  }
}

final class WaitRequest {
  const WaitRequest({required this.transfer});

  final String transfer;

  Map<String, Object?> toJson() => {'transfer': transfer};

  static WaitRequest? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {'transfer'});
    if (map == null) return null;
    final transfer = _transferId(map['transfer']);
    return transfer == null ? null : WaitRequest(transfer: transfer);
  }
}

enum CancelReason {
  cancelled('cancelled'),
  unreadable('unreadable'),
  noContact('no_contact');

  const CancelReason(this.wire);

  final String wire;
}

final class CancelRequest {
  const CancelRequest({
    required this.transfer,
    required this.reason,
    this.entry,
  });

  final String transfer;
  final CancelReason reason;
  final int? entry;

  Map<String, Object?> toJson() => {
    'transfer': transfer,
    'reason': reason.wire,
    if (entry != null) 'entry': entry,
  };

  static CancelRequest? tryParse(Object? json) {
    final map =
        _objectWithKeys(json, const {'transfer', 'reason'}) ??
        _objectWithKeys(json, const {'transfer', 'reason', 'entry'});
    if (map == null) return null;
    final transfer = _transferId(map['transfer']);
    final wire = map['reason'];
    if (transfer == null || wire is! String) return null;
    final entry = map['entry'];
    if (map.containsKey('entry')) {
      if (entry is! int || entry < 1 || entry > Limits.maxFolderEntries) {
        return null;
      }
      if (wire != CancelReason.unreadable.wire) return null;
    }
    for (final reason in CancelReason.values) {
      if (reason.wire == wire) {
        return CancelRequest(
          transfer: transfer,
          reason: reason,
          entry: map.containsKey('entry') ? entry as int : null,
        );
      }
    }
    return null;
  }
}

enum RemoteStatus {
  waiting,
  manifest,
  accepted,
  uploading,
  saving,
  saved,
  rejected,
  cancelled,
  failed,
}

const Map<String, TransferOutcome> _rejectedReasons = {
  'declined': TransferOutcome.declined,
  'unanswered': TransferOutcome.unanswered,
  'no_folder': TransferOutcome.noFolder,
  'no_space': TransferOutcome.noSpace,
  'path_too_long': TransferOutcome.pathTooLong,
};

const Map<String, TransferOutcome> _failedReasons = {
  'upload_not_started': TransferOutcome.uploadNotStarted,
  'connection_lost': TransferOutcome.connectionLost,
  'idle': TransferOutcome.idle,
  'too_many_bytes': TransferOutcome.tooManyBytes,
  'write_failed': TransferOutcome.writeFailed,
  'disk_full': TransferOutcome.diskFull,
  'damaged': TransferOutcome.damaged,
  'mark_failed': TransferOutcome.markFailed,
  'move_failed': TransferOutcome.moveFailed,
  'no_free_name': TransferOutcome.noFreeName,
  'interface_down': TransferOutcome.interfaceDown,
  'unreadable': TransferOutcome.unreadable,
  'unexpected_data': TransferOutcome.unexpectedData,
};

String? _wireReason(Map<String, TransferOutcome> reasons, TransferOutcome o) {
  for (final MapEntry(:key, :value) in reasons.entries) {
    if (value == o) return key;
  }
  return null;
}

final class RemoteState {
  const RemoteState.waiting({required bool this.picker})
    : status = RemoteStatus.waiting,
      permit = null,
      marked = null,
      name = null,
      reason = null;

  const RemoteState.manifest({required String this.permit})
    : status = RemoteStatus.manifest,
      picker = null,
      marked = null,
      name = null,
      reason = null;

  const RemoteState.accepted({required String this.permit})
    : status = RemoteStatus.accepted,
      picker = null,
      marked = null,
      name = null,
      reason = null;

  const RemoteState.uploading()
    : status = RemoteStatus.uploading,
      picker = null,
      permit = null,
      marked = null,
      name = null,
      reason = null;

  const RemoteState.saving()
    : status = RemoteStatus.saving,
      picker = null,
      permit = null,
      marked = null,
      name = null,
      reason = null;

  const RemoteState.saved({required bool this.marked, this.name})
    : status = RemoteStatus.saved,
      picker = null,
      permit = null,
      reason = null;

  const RemoteState.rejected({required String this.reason})
    : status = RemoteStatus.rejected,
      picker = null,
      permit = null,
      marked = null,
      name = null;

  const RemoteState.cancelled()
    : status = RemoteStatus.cancelled,
      picker = null,
      permit = null,
      marked = null,
      name = null,
      reason = null;

  const RemoteState.failed({required String this.reason})
    : status = RemoteStatus.failed,
      picker = null,
      permit = null,
      marked = null,
      name = null;

  final RemoteStatus status;
  final bool? picker;
  final String? permit;
  final bool? marked;
  final String? name;
  final String? reason;

  Map<String, Object?> toJson() => {
    'state': status.name,
    ...switch (status) {
      RemoteStatus.waiting => {'picker': picker},
      RemoteStatus.manifest || RemoteStatus.accepted => {'permit': permit},
      RemoteStatus.saved => {'marked': marked, if (name != null) 'name': name},
      RemoteStatus.rejected || RemoteStatus.failed => {'reason': reason},
      RemoteStatus.uploading ||
      RemoteStatus.saving ||
      RemoteStatus.cancelled => const <String, Object?>{},
    },
  };

  static RemoteState? tryParse(Object? json) {
    if (json is! Map<Object?, Object?>) return null;
    final name = json['state'];
    if (name is! String) return null;
    final status = RemoteStatus.values.asNameMap()[name];
    if (status == null) return null;
    switch (status) {
      case RemoteStatus.waiting:
        final map = _objectWithKeys(json, const {'state', 'picker'});
        final picker = map?['picker'];
        return picker is bool ? RemoteState.waiting(picker: picker) : null;
      case RemoteStatus.manifest:
        final map = _objectWithKeys(json, const {'state', 'permit'});
        final permit = _transferId(map?['permit']);
        return permit == null ? null : RemoteState.manifest(permit: permit);
      case RemoteStatus.accepted:
        final map = _objectWithKeys(json, const {'state', 'permit'});
        final permit = _transferId(map?['permit']);
        return permit == null ? null : RemoteState.accepted(permit: permit);
      case RemoteStatus.uploading:
        return _objectWithKeys(json, const {'state'}) == null
            ? null
            : const RemoteState.uploading();
      case RemoteStatus.saving:
        return _objectWithKeys(json, const {'state'}) == null
            ? null
            : const RemoteState.saving();
      case RemoteStatus.cancelled:
        return _objectWithKeys(json, const {'state'}) == null
            ? null
            : const RemoteState.cancelled();
      case RemoteStatus.saved:
        final plain = _objectWithKeys(json, const {'state', 'marked'});
        if (plain != null) {
          final marked = plain['marked'];
          return marked is bool ? RemoteState.saved(marked: marked) : null;
        }
        final named = _objectWithKeys(json, const {'state', 'marked', 'name'});
        final marked = named?['marked'];
        final name = named?['name'];
        return marked is bool && name is String
            ? RemoteState.saved(marked: marked, name: name)
            : null;
      case RemoteStatus.rejected:
        final map = _objectWithKeys(json, const {'state', 'reason'});
        final reason = map?['reason'];
        return reason is String && _rejectedReasons.containsKey(reason)
            ? RemoteState.rejected(reason: reason)
            : null;
      case RemoteStatus.failed:
        final map = _objectWithKeys(json, const {'state', 'reason'});
        final reason = map?['reason'];
        return reason is String && _failedReasons.containsKey(reason)
            ? RemoteState.failed(reason: reason)
            : null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteState &&
      other.status == status &&
      other.picker == picker &&
      other.permit == permit &&
      other.marked == marked &&
      other.name == name &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(status, picker, permit, marked, name, reason);
}

TransferOutcome? outcomeOfRemote(RemoteState state) => switch (state.status) {
  RemoteStatus.saved =>
    state.marked == true
        ? TransferOutcome.saved
        : TransferOutcome.savedWithoutMark,
  RemoteStatus.rejected => _rejectedReasons[state.reason],
  RemoteStatus.failed => _failedReasons[state.reason],
  RemoteStatus.cancelled => TransferOutcome.cancelledByPeer,
  RemoteStatus.waiting ||
  RemoteStatus.manifest ||
  RemoteStatus.accepted ||
  RemoteStatus.uploading ||
  RemoteStatus.saving => null,
};

RemoteState? remoteOf(TransferOutcome outcome) {
  switch (outcome) {
    case TransferOutcome.saved:
      return const RemoteState.saved(marked: true);
    case TransferOutcome.savedWithoutMark:
      return const RemoteState.saved(marked: false);
    case TransferOutcome.cancelledHere ||
        TransferOutcome.cancelledByPeer ||
        TransferOutcome.unpaired:
      return const RemoteState.cancelled();
    default:
      final rejected = _wireReason(_rejectedReasons, outcome);
      if (rejected != null) return RemoteState.rejected(reason: rejected);
      final failed = _wireReason(_failedReasons, outcome);
      if (failed != null) return RemoteState.failed(reason: failed);
      return null;
  }
}

TransferOutcome offerOutcome(int status, Map<String, Object?> json) {
  final error = json[_errorKey];
  return switch (status) {
    409 || 429 || 503 => TransferOutcome.busy,
    403 when error == 'declined' => TransferOutcome.declined,
    413 when error == 'too_large' => TransferOutcome.tooLargeForPeer,
    400 || 413 => TransferOutcome.incompatible,
    422 when error == 'path_too_long' => TransferOutcome.pathTooLong,
    422 => TransferOutcome.invalidName,
    415 => TransferOutcome.blockedType,
    507 => TransferOutcome.noSpace,
    _ => TransferOutcome.noContact,
  };
}
