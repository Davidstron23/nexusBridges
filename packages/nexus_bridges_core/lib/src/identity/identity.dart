import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import '../storage/storage.dart';
import 'certificate_builder.dart';
import 'certificate_parser.dart';

export 'dpapi_secret_protector.dart' show DpapiSecretProtector;

String _fingerprintOfSpki(List<int> spki) =>
    sha256.convert(spki).toString().toUpperCase();

String fingerprintOfCertificate(List<int> certificateDer) {
  try {
    return _fingerprintOfSpki(
      parseCertificate(Uint8List.fromList(certificateDer)).spki,
    );
  } catch (_) {
    throw const FormatException('certificate is not readable');
  }
}

String canonicalSubjectName(String commonName) =>
    commonName.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

String randomCommonName() {
  final random = Random.secure();
  final suffix = List<int>.generate(
    8,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'NexusBridges-$suffix';
}

Uint8List _randomSerial() {
  final random = Random.secure();
  final serialNumber = Uint8List.fromList(
    List<int>.generate(16, (_) => random.nextInt(256)),
  );
  serialNumber[0] = 1 + random.nextInt(0x7F);
  return serialNumber;
}

void _ignoreLog(String message) {}

const int _maxPemLength = 4096;

final RegExp _whitespace = RegExp(r'\s+');

final BigInt _curveOrder = BigInt.parse(
  'FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551',
  radix: 16,
);

List<int> _certificateDerOf(String pem) {
  final begin = pem.indexOf(pemBegin);
  if (begin < 0 || pem.indexOf(pemBegin, begin + 1) >= 0) {
    throw const FormatException('certificate is not a single PEM block');
  }
  final bodyStart = begin + pemBegin.length;
  final end = pem.indexOf(pemEnd, bodyStart);
  if (end < 0 || pem.indexOf(pemEnd, end + 1) >= 0) {
    throw const FormatException('certificate is not a single PEM block');
  }
  if (pem.substring(0, begin).trim().isNotEmpty ||
      pem.substring(end + pemEnd.length).trim().isNotEmpty) {
    throw const FormatException('certificate has data outside the PEM block');
  }
  final body = pem.substring(bodyStart, end).replaceAll(_whitespace, '');
  if (body.isEmpty || body.contains('-')) {
    throw const FormatException('certificate body is not valid');
  }
  final List<int> der;
  try {
    der = base64.decode(body);
  } on FormatException {
    throw const FormatException('certificate body is not valid base64');
  }
  if (der.isEmpty) {
    throw const FormatException('certificate body is empty');
  }
  return der;
}

BigInt _bigIntOf(List<int> bytes, int start, int end) {
  var value = BigInt.zero;
  for (var i = start; i < end; i++) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}

final class PeerCertificate {
  PeerCertificate._(this.pem, this.der, this.commonName, this._spki)
    : fingerprint = _fingerprintOfSpki(_spki),
      canonicalName = canonicalSubjectName(commonName);

  static PeerCertificate? tryParse(String pem) {
    try {
      if (pem.length > _maxPemLength) return null;
      final der = Uint8List.fromList(_certificateDerOf(pem));
      final parsed = parseCertificate(der);
      return PeerCertificate._(
        normalizedPemOf(der),
        der,
        parsed.commonName,
        parsed.spki,
      );
    } catch (_) {
      return null;
    }
  }

  static PeerCertificate? fromDer(List<int> der) {
    try {
      return tryParse(normalizedPemOf(der));
    } catch (_) {
      return null;
    }
  }

  final String pem;

  final Uint8List der;

  final String fingerprint;

  final String commonName;

  final String canonicalName;

  final Uint8List _spki;

  bool verify(List<int> data, List<int> signature) {
    try {
      if (signature.length != 64) return false;
      final r = _bigIntOf(signature, 0, 32);
      final s = _bigIntOf(signature, 32, 64);
      if (r == BigInt.zero ||
          s == BigInt.zero ||
          r >= _curveOrder ||
          s >= _curveOrder) {
        return false;
      }
      return CryptoUtils.ecVerify(
        CryptoUtils.ecPublicKeyFromDerBytes(_spki),
        Uint8List.fromList(data),
        ECSignature(r, s),
        algorithm: _signatureAlgorithm,
      );
    } catch (_) {
      return false;
    }
  }
}

void _writeBigEndian(Uint8List target, int offset, BigInt value) {
  var rest = value;
  for (var i = offset + 31; i >= offset; i--) {
    target[i] = (rest & BigInt.from(0xFF)).toInt();
    rest = rest >> 8;
  }
}

abstract interface class SecretProtector {
  Uint8List protect(Uint8List data);

  Uint8List? unprotect(Uint8List data);
}

const String _signatureAlgorithm = 'SHA-256/ECDSA';

final class DeviceIdentity {
  DeviceIdentity._(
    this._certificatePem,
    this._privateKeyPem,
    this._certificateDer,
  ) : fingerprint = fingerprintOfCertificate(_certificateDer),
      certificate = PeerCertificate.fromDer(_certificateDer)!;

  static DeviceIdentity generate() {
    final keyPair = CryptoUtils.generateEcKeyPair();
    final privateKey = keyPair.privateKey as ECPrivateKey;
    final publicKey = keyPair.publicKey as ECPublicKey;
    final certificatePem = buildSelfSignedCertificatePem(
      privateKey: privateKey,
      publicKey: publicKey,
      commonName: commonNameForSpki(spkiOf(publicKey)),
      serialNumber: _randomSerial(),
    );
    return DeviceIdentity._(
      certificatePem,
      CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
      CryptoUtils.getBytesFromPEMString(certificatePem),
    );
  }

  static DeviceIdentity? fromPem({
    required String certificatePem,
    required String privateKeyPem,
  }) {
    try {
      final identity = DeviceIdentity._(
        certificatePem,
        privateKeyPem,
        CryptoUtils.getBytesFromPEMString(certificatePem),
      );
      final privateKey = CryptoUtils.ecPrivateKeyFromPem(privateKeyPem);
      final publicKey = CryptoUtils.ecPublicKeyFromDerBytes(
        parseCertificate(identity._certificateDer).spki,
      );

      final random = Random.secure();
      final data = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      final signature = CryptoUtils.ecSign(
        privateKey,
        data,
        algorithmName: _signatureAlgorithm,
      );
      final matches = CryptoUtils.ecVerify(
        publicKey,
        data,
        signature,
        algorithm: _signatureAlgorithm,
      );
      return matches ? identity : null;
    } catch (_) {
      return null;
    }
  }

  static DeviceIdentity? migrateLegacy({
    required String certificatePem,
    required String privateKeyPem,
  }) {
    try {
      final legacy = parseLegacyCertificate(
        Uint8List.fromList(_certificateDerOf(certificatePem)),
      );
      if (legacy.commonName == commonNameForSpki(legacy.spki)) return null;
      final privateKey = CryptoUtils.ecPrivateKeyFromPem(privateKeyPem);
      final parameters = privateKey.parameters!;
      final publicKey = ECPublicKey(parameters.G * privateKey.d, parameters);
      final spki = spkiOf(publicKey);
      if (_fingerprintOfSpki(spki) != _fingerprintOfSpki(legacy.spki)) {
        return null;
      }
      return fromPem(
        certificatePem: buildSelfSignedCertificatePem(
          privateKey: privateKey,
          publicKey: publicKey,
          commonName: commonNameForSpki(spki),
          serialNumber: _randomSerial(),
        ),
        privateKeyPem: privateKeyPem,
      );
    } catch (_) {
      return null;
    }
  }

  final String _certificatePem;

  final String _privateKeyPem;

  final Uint8List _certificateDer;

  final String fingerprint;

  String get certificatePem => _certificatePem;

  Uint8List get certificateDer => _certificateDer;

  late final ECPrivateKey _privateKey = CryptoUtils.ecPrivateKeyFromPem(
    _privateKeyPem,
  );

  final PeerCertificate certificate;

  Uint8List sign(List<int> data) {
    final signature = CryptoUtils.ecSign(
      _privateKey,
      Uint8List.fromList(data),
      algorithmName: _signatureAlgorithm,
    );
    final out = Uint8List(64);
    _writeBigEndian(out, 0, signature.r);
    _writeBigEndian(out, 32, signature.s);
    return out;
  }

  SecurityContext serverContext({
    required Iterable<String> trustedCertificatesPem,
  }) {
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..useCertificateChainBytes(utf8.encode(_certificatePem))
      ..usePrivateKeyBytes(utf8.encode(_privateKeyPem));
    final names = <String>{};
    for (final pem in trustedCertificatesPem) {
      final peer = PeerCertificate.tryParse(pem);
      if (peer == null || names.contains(peer.canonicalName)) continue;
      try {
        context.setTrustedCertificatesBytes(utf8.encode(peer.pem));
      } catch (_) {
        continue;
      }
      names.add(peer.canonicalName);
    }
    return context;
  }

  SecurityContext clientContext({bool presentCertificate = false}) {
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
    if (presentCertificate) {
      context
        ..useCertificateChainBytes(utf8.encode(_certificatePem))
        ..usePrivateKeyBytes(utf8.encode(_privateKeyPem));
    }
    return context;
  }

  Uint8List protectPrivateKey(SecretProtector p) =>
      p.protect(Uint8List.fromList(utf8.encode(_privateKeyPem)));

  @override
  String toString() => 'DeviceIdentity($fingerprint)';
}

sealed class IdentityLoadResult {
  DeviceIdentity get identity;
}

final class IdentityLoaded extends IdentityLoadResult {
  IdentityLoaded(this.identity);

  @override
  final DeviceIdentity identity;
}

final class IdentityCreated extends IdentityLoadResult {
  IdentityCreated(this.identity);

  @override
  final DeviceIdentity identity;
}

final class IdentityReset extends IdentityLoadResult {
  IdentityReset(this.identity, this.brokenBackup);

  @override
  final DeviceIdentity identity;

  final Directory brokenBackup;
}

final class IdentityCreationException implements Exception {
  IdentityCreationException(this.reason);

  final String reason;

  @override
  String toString() => 'IdentityCreationException($reason)';
}

final class IdentityStore {
  IdentityStore({
    required this._dataDir,
    required this._protector,
    this._now = DateTime.now,
    this._log = _ignoreLog,
  });

  final Directory _dataDir;

  final SecretProtector _protector;

  final DateTime Function() _now;

  final void Function(String) _log;

  Directory get _identityDir => Directory('${_dataDir.path}/identity');

  File get _certificateFile => File('${_identityDir.path}/certificate.pem');

  File get _keyFile => File('${_identityDir.path}/private-key.dpapi');

  Future<IdentityLoadResult> loadOrCreate() async {
    final certificateExists = await _certificateFile.exists();
    final keyExists = await _keyFile.exists();

    if (!certificateExists && !keyExists) {
      return IdentityCreated(await _createAndWrite());
    }
    if (certificateExists && keyExists) {
      final identity = await _tryLoad();
      if (identity != null) return IdentityLoaded(identity);
    }

    final Directory backup;
    try {
      backup = await _identityDir.rename(await _freeBackupPath());
    } catch (e) {
      throw _creationFailure(e);
    }
    return IdentityReset(await _createAndWrite(), backup);
  }

  Future<DeviceIdentity?> _tryLoad() async {
    final certificate = await _certificateFile.readAsBytes();
    final encryptedKey = await _keyFile.readAsBytes();
    final key = await _unprotectWithRetry(Uint8List.fromList(encryptedKey));
    if (key == null) return null;
    try {
      final certificatePem = utf8.decode(certificate);
      final privateKeyPem = utf8.decode(key);
      final identity = DeviceIdentity.fromPem(
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
      );
      if (identity != null) return identity;
      final migrated = DeviceIdentity.migrateLegacy(
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
      );
      if (migrated != null) await _saveMigrated(migrated);
      return migrated;
    } on FormatException {
      return null;
    }
  }

  Future<void> _saveMigrated(DeviceIdentity identity) async {
    try {
      await writeFileAtomic(
        _certificateFile,
        utf8.encode(identity.certificatePem),
      );
    } catch (e) {
      _log('identity certificate migration not saved: ${e.runtimeType}');
    }
  }

  Future<Uint8List?> _unprotectWithRetry(Uint8List encrypted) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      final plain = _protector.unprotect(encrypted);
      if (plain != null) return plain;
      if (attempt < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return null;
  }

  Future<DeviceIdentity> _createAndWrite() async {
    try {
      final identity = DeviceIdentity.generate();
      await writeFileAtomic(
        _certificateFile,
        utf8.encode(identity.certificatePem),
      );
      await writeFileAtomic(_keyFile, identity.protectPrivateKey(_protector));
      return identity;
    } catch (e) {
      throw _creationFailure(e);
    }
  }

  IdentityCreationException _creationFailure(Object e) =>
      IdentityCreationException('could not create identity: ${e.runtimeType}');

  Future<String> _freeBackupPath() async {
    final base = '${_dataDir.path}/identity.broken-${_timestamp(_now())}';
    var candidate = base;
    for (var n = 2; await _exists(candidate); n++) {
      candidate = '$base-$n';
    }
    return candidate;
  }
}

Future<bool> _exists(String path) async {
  return await File(path).exists() ||
      await Directory(path).exists() ||
      await Link(path).exists();
}

String _timestamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      '-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}
