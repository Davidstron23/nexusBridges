import 'dart:async';

import 'package:nexus_bridges_core/src/protocol/protocol.dart' show Limits;
import 'package:nexus_bridges_core/src/transfer/platform.dart';
import 'package:test/test.dart';

final class TypePlatform implements FileSystemPlatform {
  TypePlatform(this.answer);

  final Future<bool> Function(String extension) answer;
  final List<String> asked = [];

  @override
  Future<bool> isDangerousType(String extension) {
    asked.add(extension);
    return answer(extension);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('only isDangerousType is used');
}

void main() {
  group('E181, RF-232: program with Windows and the fixed list as backup', () {
    test('"x.exe" is a program of the fixed list and Windows is not '
        'asked', () async {
      final fs = TypePlatform((_) async => false);

      expect(await isProgramHere('x.exe', fs), isTrue);
      expect(fs.asked, isEmpty);
    });

    test('every name of the fixed list wins without asking Windows', () async {
      final fs = TypePlatform((_) async => false);

      for (final name in ['a.MSI', 'b.ps1', 'c.hta', 'factura.pdf.exe']) {
        expect(await isProgramHere(name, fs), isTrue, reason: name);
      }
      expect(fs.asked, isEmpty);
    });

    test('"x.chm" when Windows says dangerous is a program and Windows gets '
        '".chm"', () async {
      final fs = TypePlatform((_) async => true);

      expect(await isProgramHere('x.chm', fs), isTrue);
      expect(fs.asked, ['.chm']);
    });

    test('Windows gets the last extension with its case', () async {
      final fs = TypePlatform((_) async => false);

      expect(await isProgramHere('Informe.tar.GZ', fs), isFalse);
      expect(fs.asked, ['.GZ']);
    });

    test('"x.chm" when Windows says not dangerous is not a program', () async {
      final fs = TypePlatform((_) async => false);

      expect(await isProgramHere('x.chm', fs), isFalse);
      expect(fs.asked, ['.chm']);
    });

    test('"x.chm" with a platform whose future fails gives false', () async {
      final fs = TypePlatform((_) async => throw StateError('broken'));

      expect(await isProgramHere('x.chm', fs), isFalse);
      expect(fs.asked, ['.chm']);
    });

    test('"x.chm" with a platform that throws before giving a future gives '
        'false', () async {
      final fs = TypePlatform((_) => throw StateError('broken'));

      expect(await isProgramHere('x.chm', fs), isFalse);
    });

    test('"x.chm" with a platform that never answers gives false after the '
        'timeout', () async {
      final never = Completer<bool>();
      final fs = TypePlatform((_) => never.future);
      final clock = Stopwatch()..start();

      final result = await isProgramHere(
        'x.chm',
        fs,
        timeout: const Duration(milliseconds: 50),
      );

      clock.stop();
      expect(result, isFalse);
      expect(
        clock.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 45)),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test(
      'a late answer after the timeout does not change the result',
      () async {
        final slow = Completer<bool>();
        final fs = TypePlatform((_) => slow.future);

        final result = await isProgramHere(
          'x.chm',
          fs,
          timeout: const Duration(milliseconds: 20),
        );
        slow.complete(true);
        await Future<void>.delayed(Duration.zero);

        expect(result, isFalse);
      },
    );

    test('"léeme" has no dot: false and Windows is not asked', () async {
      final fs = TypePlatform((_) async => true);

      expect(await isProgramHere('léeme', fs), isFalse);
      expect(fs.asked, isEmpty);
    });

    test('"x.b c" has a space after the last dot: false and Windows is not '
        'asked', () async {
      final fs = TypePlatform((_) async => true);

      expect(await isProgramHere('x.b c', fs), isFalse);
      expect(fs.asked, isEmpty);
    });

    test('a dot name like ".bashrc" asks Windows for ".bashrc"', () async {
      final fs = TypePlatform((_) async => false);

      expect(await isProgramHere('.bashrc', fs), isFalse);
      expect(fs.asked, ['.bashrc']);
    });

    test('the default timeout is the one second of Limits', () {
      expect(Limits.transferTypeCheckTimeout, const Duration(seconds: 1));
    });
  });
}
