import 'dart:convert';
import 'dart:io';

import '../identity/identity.dart' show DeviceIdentity, certificateMatches;
import '../protocol/protocol.dart' show ApiPaths, Limits;
import '../transfer/transfer.dart'
    show AbortSignal, SendTarget, visibleFileName;
import '../transport/transport.dart' show postJson;
import 'messages.dart';

final class RemoteRoot {
  const RemoteRoot({
    required this.id,
    required this.name,
    required this.home,
    required this.available,
  });

  final String id;
  final String name;
  final bool home;
  final bool available;

  String displayName({required String homeName}) =>
      home ? homeName : visibleFileName(name);

  @override
  bool operator ==(Object other) =>
      other is RemoteRoot &&
      other.id == id &&
      other.name == name &&
      other.home == home &&
      other.available == available;

  @override
  int get hashCode => Object.hash(id, name, home, available);
}

enum BrowseFailure {
  notAllowed,
  unavailable,
  busy,
  noAnswer,
  unreadable,
  notVisible,
}

sealed class RemoteListing {
  const RemoteListing();
}

final class RemoteRoots extends RemoteListing {
  const RemoteRoots(this.roots, {this.checks = const []});

  final List<RemoteRoot> roots;
  final List<bool> checks;
}

final class RemoteFolders extends RemoteListing {
  const RemoteFolders(this.names, {required this.more, required this.partial});

  final List<String> names;
  final bool more;
  final bool partial;
}

final class RemoteListingFailed extends RemoteListing {
  const RemoteListingFailed(this.reason);

  final BrowseFailure reason;
}

final class BrowseCheck {
  const BrowseCheck({required this.rootId, required this.path});

  final String rootId;
  final List<String> path;
}

final class BrowseClient {
  BrowseClient({required this._identity});

  final DeviceIdentity _identity;

  late final SecurityContext _context = _identity.clientContext(
    presentCertificate: true,
  );

  Future<RemoteListing> roots(
    SendTarget target, {
    List<BrowseCheck> checks = const [],
    Duration timeout = Limits.browseRootsTimeout,
    AbortSignal? abort,
  }) => _ask(
    target,
    rootsRequestJson(checks),
    timeout,
    abort,
    (json) => parseRootsResponse(json, checks: checks.length),
  );

  Future<RemoteListing> folders(
    SendTarget target,
    String rootId,
    List<String> path, {
    Duration timeout = Limits.browseFoldersTimeout,
    AbortSignal? abort,
  }) => _ask(
    target,
    foldersRequestJson(rootId, path),
    timeout,
    abort,
    parseFoldersResponse,
  );

  Future<RemoteListing> _ask(
    SendTarget target,
    Map<String, Object?> request,
    Duration timeout,
    AbortSignal? abort,
    RemoteListing? Function(Object? json) parse,
  ) async {
    try {
      final response = await postJson(
        address: target.address,
        port: target.port,
        path: ApiPaths.browse,
        json: request,
        context: _context,
        acceptServer: (certificate) =>
            certificateMatches(certificate, target.fingerprint),
        sourceAddress: target.localAddress,
        timeout: timeout,
        maxResponseBytes: Limits.maxBrowseResponseBytes,
        abort: abort,
      );
      if (response == null) {
        return const RemoteListingFailed(BrowseFailure.noAnswer);
      }
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.body));
      } catch (_) {
        decoded = null;
      }
      return switch (response.status) {
        200 =>
          parse(decoded) ?? const RemoteListingFailed(BrowseFailure.unreadable),
        403 => const RemoteListingFailed(BrowseFailure.notAllowed),
        404
            when decoded is Map<Object?, Object?> &&
                decoded['error'] == 'unavailable' =>
          const RemoteListingFailed(BrowseFailure.unavailable),
        404 || 400 => const RemoteListingFailed(BrowseFailure.notAllowed),
        429 => const RemoteListingFailed(BrowseFailure.busy),
        _ => const RemoteListingFailed(BrowseFailure.noAnswer),
      };
    } catch (_) {
      return const RemoteListingFailed(BrowseFailure.noAnswer);
    }
  }
}
