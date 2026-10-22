import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import '../storage/storage.dart';

export 'dpapi_secret_protector.dart' show DpapiSecretProtector;

String fingerprintOf(List<int> der) =>
    sha256.convert(der).toString().toUpperCase();

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
  ) : fingerprint = fingerprintOf(_certificateDer);

  static DeviceIdentity generate({required String commonName}) {
    final keyPair = CryptoUtils.generateEcKeyPair();
    final privateKey = keyPair.privateKey as ECPrivateKey;
    final publicKey = keyPair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': commonName},
      privateKey,
      publicKey,
    );
    final certificatePem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      18262,
      notBefore: DateTime.utc(2000),
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
      final certificate = X509Utils.x509CertificateFromPem(certificatePem);
      final publicKey = CryptoUtils.ecPublicKeyFromDerBytes(
        HexUtils.decode(
          certificate.tbsCertificate!.subjectPublicKeyInfo.bytes!,
        ),
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

  final String _certificatePem;

  final String _privateKeyPem;

  final Uint8List _certificateDer;

  final String fingerprint;

  String get certificatePem => _certificatePem;

  Uint8List get certificateDer => _certificateDer;

  SecurityContext serverContext({
    required Iterable<String> trustedCertificatesPem,
  }) {
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..useCertificateChainBytes(utf8.encode(_certificatePem))
      ..usePrivateKeyBytes(utf8.encode(_privateKeyPem));
    for (final pem in trustedCertificatesPem) {
      try {
        context.setTrustedCertificatesBytes(utf8.encode(pem));
      } catch (_) {
        continue;
      }
    }
    return context;
  }

  SecurityContext clientContext() =>
      SecurityContext(withTrustedRoots: false)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;

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
  });

  final Directory _dataDir;

  final SecretProtector _protector;

  final DateTime Function() _now;

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
      return DeviceIdentity.fromPem(
        certificatePem: utf8.decode(certificate),
        privateKeyPem: utf8.decode(key),
      );
    } on FormatException {
      return null;
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
      final identity = DeviceIdentity.generate(commonName: _newCommonName());
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

String _newCommonName() {
  final random = Random.secure();
  final suffix = List<int>.generate(
    8,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'NexusBridges-$suffix';
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
