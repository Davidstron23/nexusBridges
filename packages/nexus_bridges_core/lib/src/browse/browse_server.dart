import 'dart:async';

import '../protocol/protocol.dart' show ApiPaths, Limits, monotonicClock;
import '../server/server.dart'
    show ApiCall, ApiReply, ApiRoute, RouteAccess, RouteLimit;
import '../transfer/transfer.dart' show checkRelativePath;
import 'client.dart' show BrowseCheck;
import 'labels.dart' show parentLabelOf, visibleRootNames;
import 'messages.dart';
import 'rate_window.dart';
import 'share_fs.dart';
import 'shares.dart' show ShareReader, sharePathUnits;
import 'shares_store.dart' show ShareRecord;

void _noLog(String message) {}

const ApiReply _forbidden = ApiReply(403, {'error': 'forbidden'});

const ApiReply _unavailable = ApiReply(404, {'error': 'unavailable'});

const ApiReply _rateLimited = ApiReply(429, {'error': 'rate_limited'});

const ApiReply _badRequest = ApiReply(400, {'error': 'bad_request'});

const RouteLimit _ipLimit = RouteLimit(
  maxPerWindow: Limits.browseRequestsPerMinutePerIp,
  window: Duration(minutes: 1),
  block: Limits.routeBlock,
);

final class BrowseServer {
  BrowseServer({
    required this._shares,
    required ShareBrowseFileSystem fileSystem,
    Duration Function() clock = monotonicClock,
    this._log = _noLog,
  }) : _fs = fileSystem,
       _limiter = SlidingWindowLimiter(
         limit: Limits.browseRequestsPerWindow,
         window: Limits.browseWindow,
         clock: clock,
       );

  final ShareReader _shares;
  final ShareBrowseFileSystem _fs;
  final void Function(String) _log;
  final SlidingWindowLimiter _limiter;
  final Map<String, int> _slotsByPeer = {};
  int _slots = 0;

  late final List<ApiRoute> routes = List.unmodifiable([
    ApiRoute(
      path: ApiPaths.browse,
      access: RouteAccess.paired,
      handle: _handle,
      maxBodyBytes: Limits.maxBrowseBodyBytes,
      limit: _ipLimit,
    ),
  ]);

  void forget(String fingerprint) => _limiter.forget(fingerprint);

  Future<ApiReply> _handle(ApiCall call) async {
    try {
      final fingerprint = call.clientFingerprint;
      if (fingerprint == null) return _forbidden;
      if (!_limiter.tryAcquire(fingerprint)) {
        _log('browse rate_limited');
        return _rateLimited;
      }
      final request = BrowseRequest.tryParse(call.json);
      if (request == null) {
        _log('browse bad_request');
        return _badRequest;
      }
      if (!_shares.mayBrowse(fingerprint)) {
        _log('browse forbidden');
        return _forbidden;
      }
      return switch (request) {
        RootsRequest() => await _roots(fingerprint, request),
        FoldersRequest() => await _folders(fingerprint, request),
      };
    } catch (e) {
      _log('browse failed: ${e.runtimeType}');
      return _unavailable;
    }
  }

  bool _takeSlot(String fingerprint) {
    if (_slots >= Limits.maxBrowseConcurrent) return false;
    final mine = _slotsByPeer[fingerprint] ?? 0;
    if (mine >= Limits.maxBrowseConcurrentPerPeer) return false;
    _slots++;
    _slotsByPeer[fingerprint] = mine + 1;
    return true;
  }

  void _releaseSlot(String fingerprint) {
    if (_slots > 0) _slots--;
    final mine = (_slotsByPeer[fingerprint] ?? 1) - 1;
    if (mine <= 0) {
      _slotsByPeer.remove(fingerprint);
    } else {
      _slotsByPeer[fingerprint] = mine;
    }
  }

  Future<ApiReply> _roots(String fingerprint, RootsRequest request) async {
    final roots = _shares.rootsFor(fingerprint);
    final valid = <(ShareRecord, List<String>)>[];
    final validIndexes = <int>[];
    for (var i = 0; i < request.checks.length; i++) {
      final check = request.checks[i];
      final root = _shares.rootFor(fingerprint, check.rootId);
      if (root == null || !_checkPasses(root, check)) continue;
      valid.add((root, check.path));
      validIndexes.add(i);
    }
    var available = const <bool>[];
    var answered = const <bool>[];
    var profile = null as String?;
    if (roots.isNotEmpty || valid.isNotEmpty) {
      if (!_takeSlot(fingerprint)) {
        _log('browse rate_limited');
        return _rateLimited;
      }
      var deferred = false;
      try {
        profile = await _fs.profilePath();
        final facts = await _fs.levelZero(
          roots,
          valid,
          budget: Limits.shareCheckTimeout,
        );
        final exited = facts.exited;
        if (exited != null) {
          deferred = true;
          unawaited(
            exited.then(
              (_) => _releaseSlot(fingerprint),
              onError: (Object _) => _releaseSlot(fingerprint),
            ),
          );
        }
        available = facts.available;
        answered = facts.checks;
      } finally {
        if (!deferred) _releaseSlot(fingerprint);
      }
    }
    if (!_stillGranted(fingerprint, roots)) {
      _log('browse forbidden');
      return _forbidden;
    }
    final names = visibleRootNames([
      for (final root in roots)
        (
          label: root.label,
          home: root.home,
          parentLabel: parentLabelOf(root.path, profilePath: profile),
        ),
    ]);
    final body = <String, Object?>{
      'roots': [
        for (var i = 0; i < roots.length; i++)
          {
            'id': roots[i].id,
            'name': names[i],
            'home': roots[i].home,
            'available': i < available.length && available[i],
          },
      ],
    };
    if (request.checks.isNotEmpty) {
      final checks = List<bool>.filled(request.checks.length, false);
      for (var j = 0; j < validIndexes.length; j++) {
        if (j < answered.length && answered[j]) checks[validIndexes[j]] = true;
      }
      body['checks'] = checks;
    }
    _log('browse roots ok ${roots.length}');
    return ApiReply(200, body);
  }

  bool _checkPasses(ShareRecord root, BrowseCheck check) =>
      checkRelativePath(check.path, rootPathUnits: sharePathUnits(root)) ==
      null;

  bool _stillGranted(String fingerprint, List<ShareRecord> roots) {
    if (!_shares.mayBrowse(fingerprint)) return false;
    final current = {for (final root in _shares.rootsFor(fingerprint)) root.id};
    return roots.every((root) => current.contains(root.id));
  }

  Future<ApiReply> _folders(String fingerprint, FoldersRequest request) async {
    final root = _shares.rootFor(fingerprint, request.rootId);
    if (root == null) {
      _log('browse forbidden');
      return _forbidden;
    }
    if (checkRelativePath(request.path, rootPathUnits: sharePathUnits(root)) !=
        null) {
      _log('browse unavailable');
      return _unavailable;
    }
    if (!_takeSlot(fingerprint)) {
      _log('browse rate_limited');
      return _rateLimited;
    }
    final FolderListing listing;
    try {
      listing = await _fs.listFolders(
        root,
        request.path,
        cap: Limits.browseEnumerationCap,
        max: Limits.maxBrowseEntries,
      );
    } finally {
      _releaseSlot(fingerprint);
    }
    if (!_shares.mayBrowse(fingerprint) ||
        _shares.rootFor(fingerprint, request.rootId)?.id != root.id) {
      _log('browse forbidden');
      return _forbidden;
    }
    switch (listing) {
      case FolderListed(:final names, :final more, :final partial):
        _log('browse folders ok ${names.length}');
        return ApiReply(200, {
          'folders': names,
          'more': more,
          'partial': partial,
        });
      case FolderUnavailable():
        _log('browse unavailable');
        return _unavailable;
    }
  }
}
