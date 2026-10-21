import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:test/test.dart';

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 31 + 7) % 256));

void main() {
  final skip = Platform.isWindows ? false : 'DPAPI only exists on Windows';

  group('DpapiSecretProtector (RF-2)', () {
    final protector = DpapiSecretProtector();

    for (final length in [0, 1, 32, 1000, 100000]) {
      test('unprotect recovers $length bytes', () {
        final data = _bytes(length);

        expect(protector.unprotect(protector.protect(data)), data);
      });
    }

    test('the output differs from and does not contain the input', () {
      final pem = Uint8List.fromList(
        utf8.encode(
          '-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEI0123456789abcdef\n'
          '-----END EC PRIVATE KEY-----\n',
        ),
      );

      final protected = protector.protect(pem);

      expect(protected, isNot(pem));
      expect(latin1.decode(protected), isNot(contains('PRIVATE KEY')));
      expect(latin1.decode(protected), isNot(contains('MHcCAQEEI')));
    });

    test('protecting the same data twice gives different blobs', () {
      final data = _bytes(64);

      expect(protector.protect(data), isNot(protector.protect(data)));
    });

    for (final (label, position) in [
      ('first', (int n) => 0),
      ('middle', (int n) => n ~/ 2),
      ('last', (int n) => n - 1),
    ]) {
      test('one byte altered in the $label part gives null', () {
        final protected = protector.protect(_bytes(1000));
        protected[position(protected.length)] ^= 0x01;

        expect(protector.unprotect(protected), isNull);
      });
    }

    test('unreadable input gives null without throwing', () {
      for (final input in [Uint8List(0), _bytes(10), _bytes(500)]) {
        expect(() => protector.unprotect(input), returnsNormally);
        expect(protector.unprotect(input), isNull);
      }
    });

    test(
      'with IdentityStore: created, then loaded, key not in clear',
      () async {
        final dataDir = await Directory.systemTemp.createTemp(
          'nexus_identity_dpapi_',
        );
        addTearDown(() => dataDir.delete(recursive: true));
        final sep = Platform.pathSeparator;

        final created = await IdentityStore(
          dataDir: dataDir,
          protector: protector,
        ).loadOrCreate();
        final loaded = await IdentityStore(
          dataDir: dataDir,
          protector: DpapiSecretProtector(),
        ).loadOrCreate();

        expect(created, isA<IdentityCreated>());
        expect(loaded, isA<IdentityLoaded>());
        expect(loaded.identity.fingerprint, created.identity.fingerprint);
        final onDisk = await File(
          '${dataDir.path}${sep}identity${sep}private-key.dpapi',
        ).readAsBytes();
        expect(latin1.decode(onDisk), isNot(contains('PRIVATE KEY')));
        expect(
          utf8.decode(protector.unprotect(onDisk)!),
          contains('PRIVATE KEY'),
        );
      },
    );
  }, skip: skip);
}
