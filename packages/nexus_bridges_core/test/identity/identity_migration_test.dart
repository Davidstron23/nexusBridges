import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:nexus_bridges_core/src/identity/certificate_builder.dart';
import 'package:nexus_bridges_core/src/identity/certificate_parser.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:test/test.dart';

final class _XorProtector implements SecretProtector {
  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ 0x5A]);

  @override
  Uint8List protect(Uint8List data) => _xor(data);

  @override
  Uint8List? unprotect(Uint8List data) => _xor(data);
}

typedef _Legacy = ({
  String certificatePem,
  String privateKeyPem,
  String commonName,
  Uint8List spki,
});

_Legacy _identityOfSpec001() {
  final pair = CryptoUtils.generateEcKeyPair();
  final privateKey = pair.privateKey as ECPrivateKey;
  final publicKey = pair.publicKey as ECPublicKey;
  final commonName = randomCommonName();
  final csr = X509Utils.generateEccCsrPem(
    {'CN': commonName},
    privateKey,
    publicKey,
  );
  return (
    certificatePem: X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      18262,
      notBefore: DateTime.utc(2000),
    ),
    privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
    commonName: commonName,
    spki: spkiOf(publicKey),
  );
}

Uint8List _derOf(String pem) =>
    Uint8List.fromList(CryptoUtils.getBytesFromPEMString(pem));

String _fingerprintOf(Uint8List spki) =>
    sha256.convert(spki).toString().toUpperCase();

Iterable<String> _fragments(String text, {int size = 16}) sync* {
  for (var i = 0; i + size <= text.length; i += size ~/ 2) {
    yield text.substring(i, i + size);
  }
}

String _bodyOf(String pem) =>
    LineSplitter.split(pem)
        .map((l) => l.trim())
        .where((l) => !l.startsWith('-----'))
        .join();

Future<void> _setReadOnly(File file, bool readOnly) async {
  final result = await Process.run('attrib', [
    readOnly ? '+R' : '-R',
    file.path,
  ]);
  if (result.exitCode != 0) fail('attrib failed: ${result.stderr}');
}

void main() {
  final sep = Platform.pathSeparator;
  late Directory dataDir;
  late _Legacy legacy;

  File certificateIn(Directory dir) =>
      File('${dir.path}${sep}identity${sep}certificate.pem');
  File keyIn(Directory dir) =>
      File('${dir.path}${sep}identity${sep}private-key.dpapi');

  Future<void> writeIdentity(
    String certificatePem,
    String privateKeyPem,
  ) async {
    await Directory('${dataDir.path}${sep}identity').create();
    await certificateIn(dataDir).writeAsString(certificatePem);
    await keyIn(dataDir).writeAsBytes(
      _XorProtector().protect(Uint8List.fromList(utf8.encode(privateKeyPem))),
    );
  }

  IdentityStore storeWith(List<String> logs) => IdentityStore(
    dataDir: dataDir,
    protector: _XorProtector(),
    log: logs.add,
  );

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_migration_');
    addTearDown(() async {
      final certificate = certificateIn(dataDir);
      if (Platform.isWindows && certificate.existsSync()) {
        await _setReadOnly(certificate, false);
      }
      await dataDir.delete(recursive: true);
    });
    legacy = _identityOfSpec001();
    await writeIdentity(legacy.certificatePem, legacy.privateKeyPem);
  });

  group('migration of an identity of spec 001 (V1, correction v6)', () {
    test('the fixture is what spec 001 left on disk: a random name that is '
        'not the one of its key', () {
      final der = _derOf(legacy.certificatePem);

      expect(legacy.commonName, isNot(commonNameForSpki(legacy.spki)));
      expect(parseLegacyCertificate(der).commonName, legacy.commonName);
      expect(parseLegacyCertificate(der).spki, legacy.spki);
      expect(() => parseCertificate(der), throwsFormatException);
    });

    test('loadOrCreate gives IdentityLoaded with the same fingerprint and '
        'rewrites certificate.pem with the name bound to the key', () async {
      final keyBefore = await keyIn(dataDir).readAsBytes();
      final logs = <String>[];

      final result = await storeWith(logs).loadOrCreate();

      expect(result, isA<IdentityLoaded>());
      expect(result.identity.fingerprint, _fingerprintOf(legacy.spki));
      final stored = await certificateIn(dataDir).readAsString();
      expect(stored, isNot(legacy.certificatePem));
      expect(stored, result.identity.certificatePem);
      final parsed = parseCertificate(_derOf(stored));
      expect(parsed.spki, legacy.spki);
      expect(parsed.commonName, commonNameForSpki(legacy.spki));
      expect(
        parsed.commonName,
        'NexusBridges-'
        '${result.identity.fingerprint.substring(0, 16).toLowerCase()}',
      );
      expect(result.identity.certificate.commonName, parsed.commonName);
      expect(await keyIn(dataDir).readAsBytes(), keyBefore);
      expect(await namesIn(dataDir), ['identity']);
      expect(await namesIn(Directory('${dataDir.path}${sep}identity')), [
        'certificate.pem',
        'private-key.dpapi',
      ]);
      expect(logs, isEmpty);
    });

    test(
      'a second load finds the bound certificate and changes nothing',
      () async {
        final first = await storeWith([]).loadOrCreate();
        final afterFirst = await certificateIn(dataDir).readAsBytes();
        final logs = <String>[];

        final second = await storeWith(logs).loadOrCreate();

        expect(second, isA<IdentityLoaded>());
        expect(second.identity.fingerprint, first.identity.fingerprint);
        expect(second.identity.certificatePem, first.identity.certificatePem);
        expect(await certificateIn(dataDir).readAsBytes(), afterFirst);
        expect(logs, isEmpty);
      },
    );

    test('the migrated identity signs with the same key: a signature checks '
        'against the old certificate public key', () async {
      final result = await storeWith([]).loadOrCreate();
      final data = utf8.encode('migrated');

      final signature = result.identity.sign(data);

      final verifier = PeerCertificate.tryParse(
        result.identity.certificatePem,
      )!;
      expect(verifier.verify(data, signature), isTrue);
      expect(verifier.fingerprint, _fingerprintOf(legacy.spki));
    });

    test('with certificate.pem read only it still loads with the same '
        'fingerprint, uses the rebuilt certificate in memory and logs only the '
        'type of the error', () async {
      await _setReadOnly(certificateIn(dataDir), true);
      final logs = <String>[];

      final result = await storeWith(logs).loadOrCreate();

      expect(result, isA<IdentityLoaded>());
      expect(result.identity.fingerprint, _fingerprintOf(legacy.spki));
      expect(
        result.identity.certificate.commonName,
        commonNameForSpki(legacy.spki),
      );
      expect(
        await certificateIn(dataDir).readAsString(),
        legacy.certificatePem,
      );
      expect(await namesIn(dataDir), ['identity']);
      expect(logs, hasLength(1));
      final line = logs.single;
      expect(line, matches(RegExp(r'^[a-z ]+: [A-Za-z]+$')));
      expect(line, isNot(contains(dataDir.path)));
      expect(line, isNot(contains('.pem')));
      expect(line, isNot(contains('PRIVATE KEY')));
      for (final fragment in [
        ..._fragments(_bodyOf(legacy.privateKeyPem)),
        ..._fragments(_bodyOf(legacy.certificatePem)),
        ..._fragments(_bodyOf(result.identity.certificatePem)),
      ]) {
        expect(line, isNot(contains(fragment)));
      }

      await _setReadOnly(certificateIn(dataDir), false);
      final retried = await storeWith([]).loadOrCreate();
      expect(retried, isA<IdentityLoaded>());
      expect(retried.identity.fingerprint, result.identity.fingerprint);
      expect(
        await certificateIn(dataDir).readAsString(),
        retried.identity.certificatePem,
      );
    }, skip: Platform.isWindows ? false : 'attrib is only on Windows');

    test('an old certificate with the name of another key and our key is not '
        'adopted: the identity is reset, nothing migrated', () async {
      final other = _identityOfSpec001();
      await writeIdentity(other.certificatePem, legacy.privateKeyPem);

      final result = await storeWith([]).loadOrCreate();

      expect(result, isA<IdentityReset>());
      expect(result.identity.fingerprint, isNot(_fingerprintOf(legacy.spki)));
      expect(result.identity.fingerprint, isNot(_fingerprintOf(other.spki)));
      final backup = (result as IdentityReset).brokenBackup;
      expect(
        await File('${backup.path}${sep}certificate.pem').readAsString(),
        other.certificatePem,
      );
    });

    test('a bound certificate needs no migration: migrateLegacy gives null '
        'and the file is not touched on load', () async {
      final fresh = DeviceIdentity.generate();
      final protector = _XorProtector();
      final freshKey = utf8.decode(
        protector.unprotect(fresh.protectPrivateKey(protector))!,
      );
      await writeIdentity(fresh.certificatePem, freshKey);
      final before = await certificateIn(dataDir).readAsBytes();

      expect(
        DeviceIdentity.migrateLegacy(
          certificatePem: fresh.certificatePem,
          privateKeyPem: freshKey,
        ),
        isNull,
      );
      final result = await storeWith([]).loadOrCreate();

      expect(result, isA<IdentityLoaded>());
      expect(result.identity.fingerprint, fresh.fingerprint);
      expect(await certificateIn(dataDir).readAsBytes(), before);
    });

    test('a new certificate built for the migration keeps the strict subject '
        'and no extensions, and a fresh identity uses the same rule', () {
      final migrated = DeviceIdentity.migrateLegacy(
        certificatePem: legacy.certificatePem,
        privateKeyPem: legacy.privateKeyPem,
      )!;
      final generated = DeviceIdentity.generate();

      for (final identity in [migrated, generated]) {
        final parsed = parseCertificate(identity.certificateDer);
        expect(parsed.commonName, commonNameForSpki(parsed.spki));
        expect(
          parsed.commonName,
          'NexusBridges-${identity.fingerprint.substring(0, 16).toLowerCase()}',
        );
        expect(PeerCertificate.tryParse(identity.certificatePem), isNotNull);
      }
    });
  });
}
