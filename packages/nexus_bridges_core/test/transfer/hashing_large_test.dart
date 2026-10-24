@TestOn('windows')
@Tags(['large'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/transfer/hashing.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart'
    show AbortSignal;
import 'package:test/test.dart';

const int mib = 1048576;

const int gib = 1024 * mib;

void main() {
  group('E194, NFR: digest speed with CNG', () {
    test('hashFile of a cached 1 GiB file takes less than 5 s', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_t4b_large_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}\\one-gib.bin');
      final random = Random(194);
      final block = Uint8List(mib);
      for (var i = 0; i < mib; i++) {
        block[i] = random.nextInt(256);
      }
      final sink = await file.open(mode: FileMode.writeOnly);
      try {
        for (var n = 0; n < gib ~/ mib; n++) {
          block[0] = n & 0xFF;
          block[1] = n >> 8;
          await sink.writeFrom(block);
        }
      } finally {
        await sink.close();
      }
      expect(await file.length(), gib);

      final warm = await hashFile(file.path, abort: AbortSignal());
      final clock = Stopwatch()..start();
      final timed = await hashFile(file.path, abort: AbortSignal());
      clock.stop();

      print('E194 hashFile of 1 GiB: ${clock.elapsedMilliseconds} ms');
      expect(timed!.size, gib);
      expect(timed.sha256, warm!.sha256);
      expect(timed.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
