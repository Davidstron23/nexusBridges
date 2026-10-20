import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol_version.dart';

export 'protocol_version.dart';

/// Default TCP and UDP port of NexusBridges.
const int defaultPort = 53530;

/// Multicast group used for discovery announcements.
final InternetAddress multicastGroup = InternetAddress('224.0.0.169');

/// Path prefix of every API route.
const String apiPrefix = '/api/nexusbridges/v1';

/// Largest discovery datagram that is accepted or sent, in bytes.
const int maxDatagramBytes = 1024;

/// Protocol limits shared by the server and discovery.
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
}

/// Thrown when the protocol port is already taken by another process.
final class PortInUseException implements Exception {
  const PortInUseException(this.port);

  final int port;

  @override
  String toString() => 'PortInUseException($port)';
}

/// Kind of device that is announcing itself.
enum DeviceType { desktop, mobile }

final RegExp _fingerprintPattern = RegExp(r'^[0-9A-F]{64}$');
final RegExp _protocolPattern = RegExp(r'^\d+\.\d+$');
final RegExp _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

/// The exact set of keys a [DeviceInfo] JSON map must have.
const Set<String> _deviceInfoKeys = {
  'name',
  'fingerprint',
  'port',
  'protocol',
  'deviceType',
};

/// What a device says about itself, in announcements and in `/info`.
final class DeviceInfo {
  const DeviceInfo({
    required this.name,
    required this.fingerprint,
    required this.port,
    required this.protocol,
    required this.deviceType,
  });

  /// Display name chosen by the device, or `null` when it has none.
  final String? name;

  /// Uppercase SHA-256 of the device certificate (64 hex characters).
  final String fingerprint;

  final int port;

  /// Protocol version as `major.minor`.
  final String protocol;

  final DeviceType deviceType;

  Map<String, Object?> toJson() => {
    'name': name,
    'fingerprint': fingerprint,
    'port': port,
    'protocol': protocol,
    'deviceType': deviceType.name,
  };

  /// Validates untrusted JSON and never throws: anything invalid gives `null`.
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
    if (protocol is! String || !_protocolPattern.hasMatch(protocol)) {
      return null;
    }
    final major = int.tryParse(protocol.split('.').first);
    final ownMajor = int.tryParse(protocolVersion.split('.').first);
    if (major == null || major != ownMajor) return null;
    if (deviceType is! String) return null;
    final type = DeviceType.values.asNameMap()[deviceType];
    if (type == null) return null;

    return DeviceInfo(
      name: _cleanName(rawName as String?),
      fingerprint: fingerprint,
      port: port,
      protocol: protocol,
      deviceType: type,
    );
  }
}

/// Strips control characters, trims and truncates to [Limits.maxNameLength]
/// runes. An empty result is `null`.
String? _cleanName(String? raw) {
  if (raw == null) return null;
  final cleaned = raw.replaceAll(_controlCharacters, '').trim();
  final truncated = String.fromCharCodes(
    cleaned.runes.take(Limits.maxNameLength),
  );
  return truncated.isEmpty ? null : truncated;
}

/// Whether a datagram announces a device or says goodbye.
enum AnnouncementKind { hello, bye }

/// A multicast datagram: a [kind] plus the [DeviceInfo] of the sender.
final class Announcement {
  const Announcement(this.kind, this.info);

  final AnnouncementKind kind;
  final DeviceInfo info;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(jsonEncode({'kind': kind.name, ...info.toJson()})),
  );

  /// Decodes an untrusted datagram and never throws: anything invalid gives
  /// `null`.
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
