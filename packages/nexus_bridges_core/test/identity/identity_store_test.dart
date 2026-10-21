import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:test/test.dart';

final class _XorProtector implements SecretProtector {
  _XorProtector({this.unprotectFailures = 0});

  static const int _key = 0x5A;

  int unprotectFailures;
  int protectCalls = 0;
  int unprotectCalls = 0;

  static Uint8List _xor(Uint8List data) =>
      Uint8List.fromList([for (final b in data) b ^ _key]);

  @override
  Uint8List protect(Uint8List data) {
    protectCalls++;
    return _xor(data);
  }

  @override
  Uint8List? unprotect(Uint8List data) {
    unprotectCalls++;
    if (unprotectFailures > 0) {
      unprotectFailures--;
      return null;
    }
    return _xor(data);
  }
}

final class _LeakyThrowingProtector implements SecretProtector {
  String? receivedPem;

  @override
  Uint8List protect(Uint8List data) {
    receivedPem = utf8.decode(data);
    throw StateError('DPAPI protect failed: $receivedPem');
  }

  @override
  Uint8List? unprotect(Uint8List data) => null;
}

String _pemBody(String pem) =>
    LineSplitter.split(pem)
        .map((l) => l.trim())
        .where((l) => !l.startsWith('-----'))
        .join();

Iterable<String> _fragments(String text, {int size = 16}) sync* {
  for (var i = 0; i + size <= text.length; i += size ~/ 2) {
    yield text.substring(i, i + size);
  }
}

List<String> _privateScalarForms(String privateKeyPem) {
  final hex = CryptoUtils.ecPrivateKeyFromPem(privateKeyPem).d!
      .toRadixString(16)
      .padLeft(64, '0');
  final bytes = [
    for (var i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  return [
    hex,
    hex.toUpperCase(),
    for (var pad = 0; pad < 3; pad++)
      ..._fragments(
        base64.encode([...List.filled(pad, 0), ...bytes]).substring(4),
      ),
  ];
}

void _expectNoKeyMaterial(String text, String privateKeyPem) {
  expect(text, isNot(contains('PRIVATE KEY')));
  for (final fragment in [
    ..._fragments(_pemBody(privateKeyPem)),
    ..._privateScalarForms(privateKeyPem),
  ]) {
    expect(text, isNot(contains(fragment)));
  }
}

SecurityContext _clientWithCertificate(
  String certificatePem,
  String privateKeyPem,
) => SecurityContext(withTrustedRoots: false)
  ..useCertificateChainBytes(utf8.encode(certificatePem))
  ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

Future<Object?> _serverOutcome({
  required DeviceIdentity server,
  required List<String> trusted,
  required SecurityContext client,
}) async {
  final listener = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    server.serverContext(trustedCertificatesPem: trusted),
    requestClientCertificate: true,
  );
  final outcome = Completer<Object?>();
  listener.listen(
    (socket) {
      if (!outcome.isCompleted) outcome.complete(socket.peerCertificate);
      socket.destroy();
    },
    onError: (Object error) {
      if (!outcome.isCompleted) outcome.complete(error);
    },
  );
  SecureSocket? socket;
  try {
    socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      listener.port,
      context: client,
      onBadCertificate: (c) => fingerprintOf(c.der) == server.fingerprint,
    );
  } on IOException {
    socket = null;
  }
  try {
    return await outcome.future.timeout(const Duration(seconds: 5));
  } finally {
    socket?.destroy();
    await listener.close();
  }
}

void main() {
  final sep = Platform.pathSeparator;
  final clock = DateTime(2026, 10, 21, 9, 5, 3);
  const backupName = 'identity.broken-20261021-090503';

  late Directory dataDir;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('nexus_identity_store_');
    addTearDown(() => dataDir.delete(recursive: true));
  });

  Future<Directory> otherDataDir() async {
    final dir = await Directory.systemTemp.createTemp('nexus_identity_store_');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  File certificateIn(Directory dir) =>
      File('${dir.path}${sep}identity${sep}certificate.pem');
  File keyIn(Directory dir) =>
      File('${dir.path}${sep}identity${sep}private-key.dpapi');

  IdentityStore storeFor(Directory dir, SecretProtector protector) =>
      IdentityStore(dataDir: dir, protector: protector, now: () => clock);

  Future<DeviceIdentity> createIn(Directory dir) async =>
      (await storeFor(dir, _XorProtector()).loadOrCreate()).identity;

  String storedPrivateKeyPem(Directory dir) =>
      utf8.decode(_XorProtector().unprotect(keyIn(dir).readAsBytesSync())!);

  Future<void> expectBackupNamed(Directory backup, String name) async {
    expect(backup.uri.pathSegments.lastWhere((s) => s.isNotEmpty), name);
    expect(
      await FileSystemEntity.identical(backup.parent.path, dataDir.path),
      isTrue,
    );
    expect(await backup.exists(), isTrue);
  }

  Future<List<String>> namesIn(Directory dir) async {
    final names = await dir
        .list()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList();
    return names..sort();
  }

  Future<Map<String, List<int>>> contentsOf(Directory dir) async => {
    await for (final entity in dir.list())
      if (entity is File)
        entity.uri.pathSegments.last: await entity.readAsBytes(),
  };

  group('first start (RF-1)', () {
    test('an empty data folder gives IdentityCreated', () async {
      final result = await storeFor(dataDir, _XorProtector()).loadOrCreate();

      expect(result, isA<IdentityCreated>());
    });

    test(
      'writes the certificate and the protected key, nothing else',
      () async {
        final result = await storeFor(dataDir, _XorProtector()).loadOrCreate();

        expect(await namesIn(dataDir), ['identity']);
        expect(await namesIn(Directory('${dataDir.path}${sep}identity')), [
          'certificate.pem',
          'private-key.dpapi',
        ]);
        expect(
          await certificateIn(dataDir).readAsString(),
          result.identity.certificatePem,
        );
      },
    );

    test('the key goes through the protector, never in plain text', () async {
      final protector = _XorProtector();

      await storeFor(dataDir, protector).loadOrCreate();

      final onDisk = await keyIn(dataDir).readAsBytes();
      expect(protector.protectCalls, 1);
      expect(latin1.decode(onDisk), isNot(contains('PRIVATE KEY')));
      expect(storedPrivateKeyPem(dataDir), contains('PRIVATE KEY'));
    });
  });

  group('reuse (RF-4)', () {
    test('a second call loads the same fingerprint', () async {
      final store = storeFor(dataDir, _XorProtector());
      final created = await store.loadOrCreate();

      final loaded = await store.loadOrCreate();

      expect(loaded, isA<IdentityLoaded>());
      expect(loaded.identity.fingerprint, created.identity.fingerprint);
    });

    test('a new store on the same folder loads the same identity', () async {
      final created = await createIn(dataDir);

      final loaded = await storeFor(dataDir, _XorProtector()).loadOrCreate();

      expect(loaded, isA<IdentityLoaded>());
      expect(loaded.identity.fingerprint, created.fingerprint);
      expect(loaded.identity.certificatePem, created.certificatePem);
      expect(
        await certificateIn(dataDir).readAsString(),
        created.certificatePem,
      );
    });
  });

  group('damaged identity (RF-5, RF-6)', () {
    final damages = <String, Future<void> Function(Directory dir)>{
      'key with garbage bytes': (dir) =>
          keyIn(dir).writeAsBytes(List<int>.generate(300, (i) => i * 7 % 256)),
      'key with bytes flipped in the middle': (dir) async {
        final bytes = await keyIn(dir).readAsBytes();
        for (var i = 35; i < 70; i++) {
          bytes[i] ^= 0x01;
        }
        await keyIn(dir).writeAsBytes(bytes);
      },
      'empty key file': (dir) => keyIn(dir).writeAsBytes(const []),
      'only the certificate': (dir) => keyIn(dir).delete(),
      'only the key': (dir) => certificateIn(dir).delete(),
      'unreadable certificate text': (dir) =>
          certificateIn(dir).writeAsString('not a certificate'),
      'certificate that is not UTF-8': (dir) =>
          certificateIn(dir).writeAsBytes(const [0xFF, 0xFE, 0x00, 0xC3]),
    };

    for (final MapEntry(key: label, value: damage) in damages.entries) {
      test('$label: backs up the old folder intact and resets', () async {
        final old = await createIn(dataDir);
        await damage(dataDir);
        final before = await contentsOf(
          Directory('${dataDir.path}${sep}identity'),
        );

        final result = await storeFor(dataDir, _XorProtector()).loadOrCreate();

        expect(result, isA<IdentityReset>());
        final reset = result as IdentityReset;
        await expectBackupNamed(reset.brokenBackup, backupName);
        expect(await contentsOf(reset.brokenBackup), before);
        expect(reset.identity.fingerprint, isNot(old.fingerprint));

        final reloaded = await storeFor(
          dataDir,
          _XorProtector(),
        ).loadOrCreate();
        expect(reloaded, isA<IdentityLoaded>());
        expect(reloaded.identity.fingerprint, reset.identity.fingerprint);
      });
    }

    test(
      'a key that decrypts but belongs to another identity resets',
      () async {
        final other = await otherDataDir();
        final old = await createIn(dataDir);
        final stranger = await createIn(other);
        final strangerKey = await keyIn(other).readAsBytes();
        await keyIn(dataDir).writeAsBytes(strangerKey);

        final result = await storeFor(dataDir, _XorProtector()).loadOrCreate();

        expect(result, isA<IdentityReset>());
        expect(result.identity.fingerprint, isNot(old.fingerprint));
        expect(result.identity.fingerprint, isNot(stranger.fingerprint));
        expect(await contentsOf((result as IdentityReset).brokenBackup), {
          'certificate.pem': utf8.encode(old.certificatePem),
          'private-key.dpapi': strangerKey,
        });
      },
    );

    test('a taken backup name gets -2, then -3', () async {
      final expected = [backupName, '$backupName-2', '$backupName-3'];

      for (final name in expected) {
        await createIn(dataDir);
        await keyIn(dataDir).delete();

        final result = await storeFor(dataDir, _XorProtector()).loadOrCreate();

        await expectBackupNamed((result as IdentityReset).brokenBackup, name);
      }
      expect(await namesIn(dataDir), ['identity', ...expected]);
    });

    test('a taken name that is a file also counts as taken', () async {
      await File('${dataDir.path}$sep$backupName').writeAsString('x');
      await createIn(dataDir);
      await keyIn(dataDir).delete();

      final result = await storeFor(dataDir, _XorProtector()).loadOrCreate();

      await expectBackupNamed(
        (result as IdentityReset).brokenBackup,
        '$backupName-2',
      );
      expect(await File('${dataDir.path}$sep$backupName').readAsString(), 'x');
    });
  });

  group('transient protector failures', () {
    test('two failures then success load the identity, no reset', () async {
      final created = await createIn(dataDir);
      final flaky = _XorProtector(unprotectFailures: 2);
      final watch = Stopwatch()..start();

      final result = await storeFor(dataDir, flaky).loadOrCreate();

      expect(result, isA<IdentityLoaded>());
      expect(result.identity.fingerprint, created.fingerprint);
      expect(flaky.unprotectCalls, 3);
      expect(watch.elapsed, greaterThanOrEqualTo(Duration(milliseconds: 380)));
      expect(await namesIn(dataDir), ['identity']);
    });

    test('three failures reset after waiting between attempts', () async {
      final created = await createIn(dataDir);
      final failing = _XorProtector(unprotectFailures: 3);
      final watch = Stopwatch()..start();

      final result = await storeFor(dataDir, failing).loadOrCreate();

      expect(result, isA<IdentityReset>());
      expect(result.identity.fingerprint, isNot(created.fingerprint));
      expect(failing.unprotectCalls, 3);
      expect(watch.elapsed, greaterThanOrEqualTo(Duration(milliseconds: 380)));
    });
  });

  group('unique subject per device (plan v2.3)', () {
    test(
      'two stores get distinct NexusBridges-<16 hex> common names',
      () async {
        final other = await otherDataDir();
        final first = await createIn(dataDir);
        final second = await createIn(other);

        String commonNameOf(DeviceIdentity identity) =>
            X509Utils.x509CertificateFromPem(identity.certificatePem)
                    .tbsCertificate!
                    .subject['2.5.4.3']
                as String;

        final names = [commonNameOf(first), commonNameOf(second)];
        for (final name in names) {
          expect(name, matches(RegExp(r'^NexusBridges-[0-9A-Fa-f]{16}$')));
        }
        expect(names[0], isNot(names[1]));
      },
    );

    test('a server trusting both accepts each of them', () async {
      final other = await otherDataDir();
      final first = await createIn(dataDir);
      final second = await createIn(other);
      final server = DeviceIdentity.generate(commonName: 'NexusBridges-server');
      final trusted = [first.certificatePem, second.certificatePem];

      final fromFirst = await _serverOutcome(
        server: server,
        trusted: trusted,
        client: _clientWithCertificate(
          first.certificatePem,
          storedPrivateKeyPem(dataDir),
        ),
      );
      final fromSecond = await _serverOutcome(
        server: server,
        trusted: trusted,
        client: _clientWithCertificate(
          second.certificatePem,
          storedPrivateKeyPem(other),
        ),
      );

      expect(fromFirst, isA<X509Certificate>(), reason: '$fromFirst');
      expect(fromSecond, isA<X509Certificate>(), reason: '$fromSecond');
      expect(
        fingerprintOf((fromFirst as X509Certificate).der),
        first.fingerprint,
      );
      expect(
        fingerprintOf((fromSecond as X509Certificate).der),
        second.fingerprint,
      );
    });
  });

  group('creation failures and RF-3', () {
    test(
      'a data folder that is a file throws IdentityCreationException',
      () async {
        final file = File('${dataDir.path}${sep}not-a-folder');
        await file.writeAsString('x');

        await expectLater(
          storeFor(Directory(file.path), _XorProtector()).loadOrCreate(),
          throwsA(
            isA<IdentityCreationException>().having(
              (e) => e.reason,
              'reason',
              matches(RegExp(r'^could not create identity: [A-Za-z_]+$')),
            ),
          ),
        );
        expect(await file.readAsString(), 'x');
      },
    );

    test(
      'a protector that throws gives a message with only its type',
      () async {
        final leaky = _LeakyThrowingProtector();

        final error = await storeFor(
          dataDir,
          leaky,
        ).loadOrCreate().then<Object?>((_) => null, onError: (Object e) => e);

        expect(error, isA<IdentityCreationException>());
        final exception = error as IdentityCreationException;
        expect(exception.reason, 'could not create identity: StateError');
        expect(leaky.receivedPem, contains('PRIVATE KEY'));
        _expectNoKeyMaterial(exception.reason, leaky.receivedPem!);
        _expectNoKeyMaterial(exception.toString(), leaky.receivedPem!);
      },
    );

    test('a protector that throws leaves no key on disk', () async {
      await expectLater(
        storeFor(dataDir, _LeakyThrowingProtector()).loadOrCreate(),
        throwsA(isA<IdentityCreationException>()),
      );

      expect(await keyIn(dataDir).exists(), isFalse);
      await for (final entity in dataDir.list(recursive: true)) {
        if (entity is File) {
          expect(
            latin1.decode(await entity.readAsBytes()),
            isNot(contains('PRIVATE KEY')),
            reason: entity.path,
          );
        }
      }

      final next = await storeFor(dataDir, _XorProtector()).loadOrCreate();
      expect(next, anyOf(isA<IdentityCreated>(), isA<IdentityReset>()));
      expect(await keyIn(dataDir).exists(), isTrue);
    });

    test('load results never print the private key', () async {
      final store = storeFor(dataDir, _XorProtector());
      final created = await store.loadOrCreate();
      final loaded = await store.loadOrCreate();
      final firstKeyPem = storedPrivateKeyPem(dataDir);
      await certificateIn(dataDir).delete();
      final reset = await store.loadOrCreate();
      final resetKeyPem = storedPrivateKeyPem(dataDir);

      for (final (result, keyPem) in [
        (created, firstKeyPem),
        (loaded, firstKeyPem),
        (reset, resetKeyPem),
      ]) {
        _expectNoKeyMaterial('$result ${result.identity}', keyPem);
      }
      expect(reset, isA<IdentityReset>());
    });
  });
}
