import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/protocol.dart' show DeviceType;
import 'pairing_flow.dart' show PairingRole;

const int fingerprintLength = 32;
const int nonceLength = 32;
const int sessionIdLength = 16;
const int commitmentLength = 32;
const int challengeLength = 32;
const int signatureLength = 64;

const int _codeBytes = 7;
const int _codeModulus = 1000000;
const int _codeDigits = 6;
const int _maxNameBytes = 0xFFFF;

final RegExp _fingerprintPattern = RegExp(r'^[0-9A-F]{64}$');

final Random _random = Random.secure();

Uint8List _domain(String label) =>
    Uint8List.fromList([...ascii.encode(label), 0]);

final Uint8List _commitDomain = _domain('NexusBridges pair commit v1');
final Uint8List _codeDomain = _domain('NexusBridges pair code v1');
final Uint8List _startDomain = _domain('NexusBridges pair start v1');
final Uint8List _revealDomain = _domain('NexusBridges pair reveal v1');
final Uint8List _statusDomain = _domain('NexusBridges pair status v1');

Uint8List randomBytes(int length) {
  if (length < 0) throw ArgumentError.value(length, 'length');
  return Uint8List.fromList(
    List<int>.generate(length, (_) => _random.nextInt(256)),
  );
}

Uint8List fingerprintBytes(String fingerprint) {
  if (!_fingerprintPattern.hasMatch(fingerprint)) {
    throw const FormatException('fingerprint is not valid');
  }
  return fromHex(fingerprint.toLowerCase(), fingerprintLength)!;
}

String toHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Uint8List? fromHex(String hex, int length) {
  if (length < 0 || hex.length != length * 2) return null;
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    final high = _nibble(hex.codeUnitAt(i * 2));
    final low = _nibble(hex.codeUnitAt(i * 2 + 1));
    if (high < 0 || low < 0) return null;
    bytes[i] = (high << 4) | low;
  }
  return bytes;
}

int _nibble(int unit) {
  if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
  if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
  return -1;
}

Uint8List _concat(List<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}

Uint8List _hash(List<int> data) =>
    Uint8List.fromList(sha256.convert(data).bytes);

void _expectLength(Uint8List bytes, int length, String name) {
  if (bytes.length != length) {
    throw ArgumentError.value(bytes.length, name, 'must have $length bytes');
  }
}

int _roleByte(PairingRole role) => switch (role) {
  PairingRole.initiator => 1,
  PairingRole.receiver => 2,
};

int _deviceTypeByte(DeviceType type) => switch (type) {
  DeviceType.desktop => 0,
  DeviceType.mobile => 1,
};

bool _constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

Uint8List commitmentOf({
  required PairingRole role,
  required String fingerprint,
  required Uint8List nonce,
}) {
  _expectLength(nonce, nonceLength, 'nonce');
  return _hash(
    _concat([
      _commitDomain,
      [_roleByte(role)],
      fingerprintBytes(fingerprint),
      nonce,
    ]),
  );
}

bool commitmentMatches(
  Uint8List commitment, {
  required PairingRole role,
  required String fingerprint,
  required Uint8List nonce,
}) {
  if (commitment.length != commitmentLength || nonce.length != nonceLength) {
    return false;
  }
  return _constantTimeEquals(
    commitment,
    commitmentOf(role: role, fingerprint: fingerprint, nonce: nonce),
  );
}

String pairingCode({
  required String initiatorFingerprint,
  required String receiverFingerprint,
  required Uint8List initiatorNonce,
  required Uint8List receiverNonce,
}) {
  _expectLength(initiatorNonce, nonceLength, 'initiatorNonce');
  _expectLength(receiverNonce, nonceLength, 'receiverNonce');
  final digest = _hash(
    _concat([
      _codeDomain,
      fingerprintBytes(initiatorFingerprint),
      fingerprintBytes(receiverFingerprint),
      initiatorNonce,
      receiverNonce,
    ]),
  );
  var value = 0;
  for (var i = 0; i < _codeBytes; i++) {
    value = (value << 8) | digest[i];
  }
  return (value % _codeModulus).toString().padLeft(_codeDigits, '0');
}

Uint8List startTranscript({
  required String initiatorFingerprint,
  required String receiverFingerprint,
  required String? name,
  required DeviceType deviceType,
  required Uint8List initiatorCommitment,
}) {
  _expectLength(initiatorCommitment, commitmentLength, 'initiatorCommitment');
  final nameBytes = utf8.encode(name ?? '');
  if (nameBytes.length > _maxNameBytes) {
    throw ArgumentError.value(nameBytes.length, 'name', 'is too long');
  }
  return _concat([
    _startDomain,
    fingerprintBytes(initiatorFingerprint),
    fingerprintBytes(receiverFingerprint),
    [nameBytes.length >> 8, nameBytes.length & 0xFF],
    nameBytes,
    [_deviceTypeByte(deviceType)],
    initiatorCommitment,
  ]);
}

Uint8List revealTranscript({
  required Uint8List startTranscript,
  required Uint8List sessionId,
  required Uint8List receiverCommitment,
  required Uint8List initiatorNonce,
}) {
  _expectLength(sessionId, sessionIdLength, 'sessionId');
  _expectLength(receiverCommitment, commitmentLength, 'receiverCommitment');
  _expectLength(initiatorNonce, nonceLength, 'initiatorNonce');
  return _concat([
    _revealDomain,
    _hash(startTranscript),
    sessionId,
    receiverCommitment,
    initiatorNonce,
  ]);
}

Uint8List statusTranscript({
  required String callerFingerprint,
  required String serverFingerprint,
  required Uint8List challenge,
}) {
  _expectLength(challenge, challengeLength, 'challenge');
  return _concat([
    _statusDomain,
    fingerprintBytes(callerFingerprint),
    fingerprintBytes(serverFingerprint),
    challenge,
  ]);
}
