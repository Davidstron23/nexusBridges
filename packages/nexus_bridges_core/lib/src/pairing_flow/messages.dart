import 'dart:typed_data';

import '../protocol/protocol.dart' show DeviceType, Limits, protocolVersion;
import 'crypto.dart';

const int _maxCertificateLength = 4096;
const int _maxProtocolLength = 16;

final RegExp _protocolPattern = RegExp(r'^\d+\.\d+$');

enum RemoteState { pending, paired, cancelled, expired }

enum CancelReason { cancelled, expired }

Map<Object?, Object?>? _objectWithKeys(Object? json, Set<String> keys) {
  if (json is! Map<Object?, Object?> || json.length != keys.length) {
    return null;
  }
  if (!keys.every(json.containsKey)) return null;
  return json;
}

Uint8List? _hexField(Object? value, int length) =>
    value is String ? fromHex(value, length) : null;

String? _certificateField(Object? value) =>
    value is String && value.length <= _maxCertificateLength ? value : null;

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

final class StartRequest {
  const StartRequest({
    required this.certificate,
    required this.name,
    required this.deviceType,
    required this.commitment,
    required this.proof,
  });

  final String certificate;

  final String? name;

  final DeviceType deviceType;

  final Uint8List commitment;

  final Uint8List proof;

  Map<String, Object?> toJson() => {
    'protocol': protocolVersion,
    'certificate': certificate,
    'name': name,
    'deviceType': deviceType.name,
    'commitment': toHex(commitment),
    'proof': toHex(proof),
  };

  static StartRequest? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {
      'protocol',
      'certificate',
      'name',
      'deviceType',
      'commitment',
      'proof',
    });
    if (map == null || !_compatibleProtocol(map['protocol'])) return null;
    final certificate = _certificateField(map['certificate']);
    final name = map['name'];
    final deviceType = map['deviceType'];
    final commitment = _hexField(map['commitment'], commitmentLength);
    final proof = _hexField(map['proof'], signatureLength);
    if (certificate == null || commitment == null || proof == null) {
      return null;
    }
    if (name != null &&
        (name is! String || name.length > Limits.maxRequestNameLength)) {
      return null;
    }
    if (deviceType is! String) return null;
    final type = DeviceType.values.asNameMap()[deviceType];
    if (type == null) return null;
    return StartRequest(
      certificate: certificate,
      name: name as String?,
      deviceType: type,
      commitment: commitment,
      proof: proof,
    );
  }
}

final class StartReply {
  const StartReply({required this.session, required this.commitment});

  final Uint8List session;

  final Uint8List commitment;

  Map<String, Object?> toJson() => {
    'session': toHex(session),
    'commitment': toHex(commitment),
  };

  static StartReply? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {'session', 'commitment'});
    if (map == null) return null;
    final session = _hexField(map['session'], sessionIdLength);
    final commitment = _hexField(map['commitment'], commitmentLength);
    if (session == null || commitment == null) return null;
    return StartReply(session: session, commitment: commitment);
  }
}

final class RevealRequest {
  const RevealRequest({
    required this.session,
    required this.nonce,
    required this.signature,
  });

  final Uint8List session;

  final Uint8List nonce;

  final Uint8List signature;

  Map<String, Object?> toJson() => {
    'session': toHex(session),
    'nonce': toHex(nonce),
    'signature': toHex(signature),
  };

  static RevealRequest? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {'session', 'nonce', 'signature'});
    if (map == null) return null;
    final session = _hexField(map['session'], sessionIdLength);
    final nonce = _hexField(map['nonce'], nonceLength);
    final signature = _hexField(map['signature'], signatureLength);
    if (session == null || nonce == null || signature == null) return null;
    return RevealRequest(session: session, nonce: nonce, signature: signature);
  }
}

final class RevealReply {
  const RevealReply({required this.nonce});

  final Uint8List nonce;

  Map<String, Object?> toJson() => {'nonce': toHex(nonce)};

  static RevealReply? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {'nonce'});
    if (map == null) return null;
    final nonce = _hexField(map['nonce'], nonceLength);
    return nonce == null ? null : RevealReply(nonce: nonce);
  }
}

final class SessionRequest {
  const SessionRequest({required this.session});

  final Uint8List session;

  Map<String, Object?> toJson() => {'session': toHex(session)};

  static SessionRequest? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {'session'});
    if (map == null) return null;
    final session = _hexField(map['session'], sessionIdLength);
    return session == null ? null : SessionRequest(session: session);
  }
}

final class CancelRequest {
  const CancelRequest({required this.session, required this.reason});

  final Uint8List session;

  final CancelReason reason;

  Map<String, Object?> toJson() => {
    'session': toHex(session),
    'reason': reason.name,
  };

  static CancelRequest? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {'session', 'reason'});
    if (map == null) return null;
    final session = _hexField(map['session'], sessionIdLength);
    final reasonName = map['reason'];
    if (session == null || reasonName is! String) return null;
    final reason = CancelReason.values.asNameMap()[reasonName];
    if (reason == null) return null;
    return CancelRequest(session: session, reason: reason);
  }
}

final class StateReply {
  const StateReply({required this.state});

  final RemoteState state;

  Map<String, Object?> toJson() => {'state': state.name};

  static StateReply? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {'state'});
    if (map == null) return null;
    final stateName = map['state'];
    if (stateName is! String) return null;
    final state = RemoteState.values.asNameMap()[stateName];
    return state == null ? null : StateReply(state: state);
  }
}

final class StatusRequest {
  const StatusRequest({
    required this.certificate,
    required this.challenge,
    required this.proof,
  });

  final String certificate;

  final Uint8List challenge;

  final Uint8List proof;

  Map<String, Object?> toJson() => {
    'certificate': certificate,
    'challenge': toHex(challenge),
    'proof': toHex(proof),
  };

  static StatusRequest? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {
      'certificate',
      'challenge',
      'proof',
    });
    if (map == null) return null;
    final certificate = _certificateField(map['certificate']);
    final challenge = _hexField(map['challenge'], challengeLength);
    final proof = _hexField(map['proof'], signatureLength);
    if (certificate == null || challenge == null || proof == null) {
      return null;
    }
    return StatusRequest(
      certificate: certificate,
      challenge: challenge,
      proof: proof,
    );
  }
}

final class StatusReply {
  const StatusReply({required this.paired});

  final bool paired;

  Map<String, Object?> toJson() => {'paired': paired};

  static StatusReply? tryParse(Object? json) {
    final map = _objectWithKeys(json, const {'paired'});
    if (map == null) return null;
    final paired = map['paired'];
    return paired is bool ? StatusReply(paired: paired) : null;
  }
}
