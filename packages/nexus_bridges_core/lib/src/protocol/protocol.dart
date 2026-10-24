import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol_version.dart';

export 'protocol_version.dart';

const int defaultPort = 53530;

final InternetAddress multicastGroup = InternetAddress('224.0.0.169');

const String apiPrefix = '/api/nexusbridges/v1';

abstract final class ApiPaths {
  static const String register = '$apiPrefix/register';
  static const String pairStart = '$apiPrefix/pair/start';
  static const String pairReveal = '$apiPrefix/pair/reveal';
  static const String pairWait = '$apiPrefix/pair/wait';
  static const String pairConfirm = '$apiPrefix/pair/confirm';
  static const String pairCancel = '$apiPrefix/pair/cancel';
  static const String pairStatus = '$apiPrefix/pair/status';
  static const String unpair = '$apiPrefix/unpair';
  static const Set<String> anonymous = {
    register,
    pairStart,
    pairReveal,
    pairWait,
    pairConfirm,
    pairCancel,
    pairStatus,
  };
}

const int maxDatagramBytes = 1024;

abstract final class Limits {
  static const int maxBodyBytes = 65536;
  static const int maxHeaderBytes = 8192;
  static const Duration requestTimeout = Duration(seconds: 10);
  static const int registerPerMinute = 30;
  static const Duration registerBlock = Duration(minutes: 1);
  static const int maxListedUnpaired = 64;
  static const int maxNameLength = 64;
  static const Duration announceInterval = Duration(seconds: 10);
  static const Duration expireAfter = Duration(seconds: 30);
  static const Duration rescanHintAfter = Duration(seconds: 15);
  static const int scanConcurrency = 32;
  static const Duration scanConnectTimeout = Duration(milliseconds: 1500);
  static const int maxPendingHandshakesPerIp = 8;
  static const int maxPendingHandshakes = 128;
  static const int maxConnectionsPerIp = 16;
  static const int maxConnections = 256;
  static const int maxTrackedOrigins = 4096;
  static const int maxPairingBodyBytes = 8192;
  static const int maxRequestNameLength = 256;
  static const Duration pairingTimeout = Duration(seconds: 60);
  static const Duration pairingMessageTimeout = Duration(seconds: 10);
  static const Duration pairingPollHold = Duration(seconds: 7);
  static const Duration pairingConfirmRetry = Duration(seconds: 1);
  static const Duration pairingRecordTtl = Duration(seconds: 30);
  static const int pairingRequestsPerOrigin = 5;
  static const Duration pairingRequestWindow = Duration(minutes: 10);
  static const int pairingMismatchLimit = 3;
  static const Duration pairingBlock = Duration(minutes: 10);
  static const int pairingGlobalFailures = 3;
  static const Duration pairingGlobalWindow = Duration(minutes: 10);
  static const int signatureChecksPerSecond = 20;
  static const Duration unpairNoticeTimeout = Duration(seconds: 5);
  static const Duration peerCheckInterval = Duration(minutes: 5);
  static const Duration peerCheckRetry = Duration(seconds: 30);
  static const Duration peerCheckAfterPairing = Duration(seconds: 30);
  static const int pairSessionRequestsPerMinute = 120;
  static const int pairStatusPerMinute = 12;
  static const int unpairPerMinute = 12;
  static const Duration routeBlock = Duration(minutes: 1);
  static const Duration listenerCloseGrace = Duration(milliseconds: 300);
}

final Stopwatch _monotonicWatch = Stopwatch()..start();

Duration monotonicClock() => _monotonicWatch.elapsed;

final class PortInUseException implements Exception {
  const PortInUseException(this.port);

  final int port;

  @override
  String toString() => 'PortInUseException($port)';
}

enum DeviceType { desktop, mobile }

const int _maxProtocolLength = 16;

final RegExp _fingerprintPattern = RegExp(r'^[0-9A-F]{64}$');
final RegExp _protocolPattern = RegExp(r'^\d+\.\d+$');
final RegExp _invisibleCharacters = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5'
  r'\u180B-\u180F\u2028\u2029\u200B-\u200F\u202A-\u202E\u2060-\u2064'
  r'\u2066-\u206F\u3164\uFE00-\uFE0F\uFEFF\uFFA0\uFFF0-\uFFF8'
  r'\u{1BCA0}-\u{1BCA3}\u{1D173}-\u{1D17A}\u{E0000}-\u{E0FFF}]',
  unicode: true,
);

const Set<String> _deviceInfoKeys = {
  'name',
  'fingerprint',
  'port',
  'protocol',
  'deviceType',
};

final class DeviceInfo {
  const DeviceInfo({
    required this.name,
    required this.fingerprint,
    required this.port,
    required this.protocol,
    required this.deviceType,
  });

  final String? name;

  final String fingerprint;

  final int port;

  final String protocol;

  final DeviceType deviceType;

  Map<String, Object?> toJson() => {
    'name': name,
    'fingerprint': fingerprint,
    'port': port,
    'protocol': protocol,
    'deviceType': deviceType.name,
  };

  static DeviceInfo? tryParse(Object? json) {
    if (json is! Map<Object?, Object?> ||
        json.length != _deviceInfoKeys.length) {
      return null;
    }
    if (!_deviceInfoKeys.every(json.containsKey)) return null;

    final rawName = json['name'];
    final fingerprint = json['fingerprint'];
    final port = json['port'];
    final protocol = json['protocol'];
    final deviceType = json['deviceType'];

    if (rawName != null && rawName is! String) return null;
    if (fingerprint is! String || !_fingerprintPattern.hasMatch(fingerprint)) {
      return null;
    }
    if (port is! int || port < 1 || port > 65535) return null;
    if (protocol is! String ||
        protocol.length > _maxProtocolLength ||
        !_protocolPattern.hasMatch(protocol)) {
      return null;
    }
    final major = int.tryParse(protocol.split('.').first);
    final ownMajor = int.tryParse(protocolVersion.split('.').first);
    if (major == null || major != ownMajor) return null;
    if (deviceType is! String) return null;
    final type = DeviceType.values.asNameMap()[deviceType];
    if (type == null) return null;

    return DeviceInfo(
      name: rawName is String ? sanitizeDisplayName(rawName) : null,
      fingerprint: fingerprint,
      port: port,
      protocol: protocol,
      deviceType: type,
    );
  }
}

String? sanitizeDisplayName(String raw) {
  final cleaned = raw.replaceAll(_invisibleCharacters, '').trim();
  final truncated = String.fromCharCodes(
    cleaned.runes.take(Limits.maxNameLength),
  );
  return truncated.isEmpty ? null : truncated;
}

enum AnnouncementKind { hello, bye }

final class Announcement {
  const Announcement(this.kind, this.info);

  final AnnouncementKind kind;
  final DeviceInfo info;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(jsonEncode({'kind': kind.name, ...info.toJson()})),
  );

  static Announcement? tryDecode(Uint8List bytes) {
    if (bytes.length > maxDatagramBytes) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<Object?, Object?>) return null;

    final kindName = decoded['kind'];
    if (kindName is! String) return null;
    final kind = AnnouncementKind.values.asNameMap()[kindName];
    if (kind == null) return null;

    final info = DeviceInfo.tryParse(
      Map<Object?, Object?>.of(decoded)..remove('kind'),
    );
    if (info == null) return null;
    return Announcement(kind, info);
  }
}
