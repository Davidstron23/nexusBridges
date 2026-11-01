@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import 'transfer_stacks_harness.dart';

const int mib = 1048576;

Uint8List randomBytes(int length, int seed) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

typedef MultiPick = Future<List<String>> Function(TransferCoordinator c);

final Map<String, MultiPick> pickers = {
  'pickFilesToSend': (c) => c.pickFilesToSend(),
  'pickFoldersToSend': (c) => c.pickFoldersToSend(),
};

int callsOf(ScriptedPicker picker, String name) =>
    name == 'pickFilesToSend' ? picker.filesCalls : picker.foldersCalls;

Completer<void> holdMany(TransferStack s, List<String> answer) {
  final gate = Completer<void>();
  addTearDown(() {
    if (!gate.isCompleted) gate.complete();
  });
  s.picker
    ..manyGate = gate
    ..nextMany = answer;
  return gate;
}

Completer<void> holdSingle(TransferStack s) {
  final gate = Completer<void>();
  addTearDown(() {
    if (!gate.isCompleted) gate.complete();
  });
  s.picker
    ..gate = gate
    ..next = null;
  return gate;
}

Future<void> advanceWithPolls(TransferStack s, Duration total) async {
  var left = total;
  while (left > Duration.zero) {
    final span = left < const Duration(seconds: 10)
        ? left
        : const Duration(seconds: 10);
    s.clock.advance(span);
    left -= span;
    final target = s.handledOn(ApiPaths.transferWait) + 1;
    await eventually(
      () => s.handledOn(ApiPaths.transferWait) >= target,
      reason: 'a poll after advancing ${s.name}',
    );
  }
}

Future<TransferStack> lone() => TransferStack.start(name: 'A', address: hostA);

Future<(TransferStack, TransferStack)> stacks({
  PeerRelation senderAtReceiver = PeerRelation.mine,
  WriteBytes? writesAtB,
}) async {
  final a = await TransferStack.start(name: 'A', address: hostA);
  final b = await TransferStack.start(
    name: 'B',
    address: hostB,
    writeBytes: writesAtB,
  );
  await link(a, b, senderAtReceiver: senderAtReceiver);
  return (a, b);
}

void main() {
  group(
    'E516 RF-250 RF-286 the multiple pickers hand back what was chosen',
    () {
      for (final MapEntry(key: name, value: pick) in pickers.entries) {
        test(
          'E516 $name returns every chosen path in the order given',
          () async {
            final a = await lone();
            final chosen = [
              '${a.sourceDir}\\uno.txt',
              '${a.sourceDir}\\Dos',
              '${a.sourceDir}\\tres.zip',
            ];
            a.picker.nextMany = chosen;
            expect(await pick(a.coordinator), chosen);
            expect(callsOf(a.picker, name), 1);
            expect(a.picker.fileCalls, 0);
            expect(a.picker.folderCalls, 0);
            expect(a.coordinator.pickerOpen, isFalse);
            expect(a.coordinator.sending, isFalse);
            expect(a.coordinator.busy, isFalse);
            expect(a.lastSent, isNull);
            expect(a.outgoing, isNull);
          },
        );

        test('E516 $name returns an empty list when the user closes it without '
            'choosing', () async {
          final a = await lone();
          a.picker.nextMany = const [];
          expect(await pick(a.coordinator), isEmpty);
          expect(callsOf(a.picker, name), 1);
          expect(a.coordinator.sending, isFalse);
          expect(a.lastSent, isNull);
        });
      }

      test('E516 the file picker opens pickFiles and the folder picker opens '
          'pickFolders', () async {
        final a = await lone();
        await a.coordinator.pickFilesToSend();
        expect((a.picker.filesCalls, a.picker.foldersCalls), (1, 0));
        await a.coordinator.pickFoldersToSend();
        expect((a.picker.filesCalls, a.picker.foldersCalls), (1, 1));
      });
    },
  );

  group('E516 RF-250 D-10 while a multiple picker is open', () {
    for (final MapEntry(key: name, value: pick) in pickers.entries) {
      test('E516 $name keeps pickerOpen, sending and busy true and announces '
          'the change both ways', () async {
        final a = await lone();
        final seen = <(bool, bool, bool)>[];
        a.coordinator.changes.listen(
          (_) => seen.add((
            a.coordinator.pickerOpen,
            a.coordinator.sending,
            a.coordinator.busy,
          )),
        );
        final gate = holdMany(a, ['${a.sourceDir}\\uno.txt']);
        final opened = pick(a.coordinator);
        await eventually(() => callsOf(a.picker, name) == 1);
        expect(a.coordinator.pickerOpen, isTrue);
        expect(a.coordinator.sending, isTrue);
        expect(a.coordinator.busy, isTrue);
        await settle();
        expect(seen, contains((true, true, true)));
        gate.complete();
        expect(await opened, ['${a.sourceDir}\\uno.txt']);
        expect(a.coordinator.pickerOpen, isFalse);
        expect(a.coordinator.sending, isFalse);
        expect(a.coordinator.busy, isFalse);
        await settle();
        expect(seen.last, (false, false, false));
      });

      test('E516 $name gives an empty list without opening a second picker '
          'while another multiple picker is open', () async {
        final a = await lone();
        final gate = holdMany(a, ['${a.sourceDir}\\uno.txt']);
        final first = a.coordinator.pickFilesToSend();
        await eventually(() => a.picker.filesCalls == 1);
        final callsBefore = callsOf(a.picker, name);
        expect(await pick(a.coordinator), isEmpty);
        expect(callsOf(a.picker, name), callsBefore);
        expect(a.coordinator.pickerOpen, isTrue);
        gate.complete();
        expect(await first, ['${a.sourceDir}\\uno.txt']);
        expect(a.coordinator.pickerOpen, isFalse);
      });

      test('E516 $name gives an empty list while the single file picker of '
          '"send a file" is open, and works again once it closes', () async {
        final (a, b) = await stacks();
        final gate = holdSingle(a);
        final single = a.coordinator.sendFile(
          a.targetOf(b),
          refresh: () => a.targetOf(b),
        );
        await eventually(() => a.picker.fileCalls == 1);
        expect(a.coordinator.pickerOpen, isTrue);
        a.picker.nextMany = ['${a.sourceDir}\\uno.txt'];
        expect(await pick(a.coordinator), isEmpty);
        expect(callsOf(a.picker, name), 0);
        gate.complete();
        expect(await single, SendStart.nothingChosen);
        expect(await pick(a.coordinator), ['${a.sourceDir}\\uno.txt']);
        expect(callsOf(a.picker, name), 1);
      });

      test('E516 $name gives an empty list when the picker fails, closes the '
          'picker state and logs no path', () async {
        final a = await lone();
        a.picker.manyFailure = FileSystemException(
          'picker exploded',
          r'C:\Users\David\secreto\clave.txt',
        );
        expect(await pick(a.coordinator), isEmpty);
        expect(callsOf(a.picker, name), 1);
        expect(a.coordinator.pickerOpen, isFalse);
        expect(a.coordinator.sending, isFalse);
        expect(a.coordinator.busy, isFalse);
        expect(a.logs.join('\n'), isNot(contains('secreto')));
        expect(a.logs.join('\n'), isNot(contains('picker exploded')));
        a.picker
          ..manyFailure = null
          ..nextMany = ['${a.sourceDir}\\uno.txt'];
        expect(await pick(a.coordinator), ['${a.sourceDir}\\uno.txt']);
      });

      test('E516 $name gives an empty list without opening the picker once '
          'the coordinator is closing or closed', () async {
        final a = await lone();
        a.picker.nextMany = ['${a.sourceDir}\\uno.txt'];
        final closing = a.coordinator.close();
        expect(await pick(a.coordinator), isEmpty);
        await closing;
        expect(await pick(a.coordinator), isEmpty);
        expect(callsOf(a.picker, name), 0);
      });

      test('E516 $name gives an empty list when the coordinator closes while '
          'the picker is open', () async {
        final a = await lone();
        final gate = holdMany(a, ['${a.sourceDir}\\uno.txt']);
        final opened = pick(a.coordinator);
        await eventually(() => callsOf(a.picker, name) == 1);
        await a.coordinator.close();
        gate.complete();
        expect(await opened, isEmpty);
        expect(a.coordinator.sending, isFalse);
      });
    }
  });

  group('E516 RF-155 D-10 a multiple picker freezes the deadlines of a warning '
      'open on this device', () {
    for (final MapEntry(key: name, value: pick) in pickers.entries) {
      test('E516 $name freezes the 60 s of the warning and the warning keeps '
          'the 10 s it had left', () async {
        final (a, b) = await stacks(senderAtReceiver: PeerRelation.foreign);
        final pickerFlags = <Object?>[];
        b.wrappers[ApiPaths.transferWait] = (call, inner) async {
          final reply = await inner(call);
          pickerFlags.add(reply.json['picker']);
          return reply;
        };
        final path = await a.sourceFile('informe.bin', randomBytes(4096, 516));
        expect(await a.send(b, path), SendStart.started);
        await eventually(() => b.incoming?.stage == IncomingStage.warning);
        await advanceWithPolls(b, const Duration(seconds: 50));
        expect(b.incoming?.stage, IncomingStage.warning);

        final chosen = ['${b.sourceDir}\\uno.txt', '${b.sourceDir}\\Dos'];
        final gate = holdMany(b, chosen);
        final opened = pick(b.coordinator);
        await eventually(() => callsOf(b.picker, name) == 1);
        expect(b.coordinator.pickerOpen, isTrue);
        pickerFlags.clear();
        await advanceWithPolls(b, const Duration(seconds: 30));
        expect(b.incoming?.stage, IncomingStage.warning);
        expect(pickerFlags, contains(true));

        gate.complete();
        expect(await opened, chosen);
        expect(b.coordinator.pickerOpen, isFalse);
        expect(b.lastSent, isNull);
        await advanceWithPolls(b, const Duration(milliseconds: 9900));
        await settle();
        expect(b.incoming?.stage, IncomingStage.warning);
        b.clock.advance(const Duration(milliseconds: 100));
        await eventually(() => b.incoming == null, reason: 'warning expired');
        expect(b.lastReceived!.outcome, TransferOutcome.unanswered);
        expect((await a.sentResult()).outcome, TransferOutcome.unanswered);
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  });

  group('E516 RF-290 clarify point 2 a multiple picker can open with a send in '
      'progress', () {
    for (final MapEntry(key: name, value: pick) in pickers.entries) {
      test('E516 $name opens during an upload, hands back its paths and the '
          'upload still ends saved', () async {
        final writes = WriteThrottle()..hold();
        final (a, b) = await stacks(writesAtB: writes.call);
        final path = await a.sourceFile('grande.bin', randomBytes(8 * mib, 7));
        expect(await a.send(b, path), SendStart.started);
        await eventually(() => writes.calls >= 1, reason: 'upload started');
        expect(a.coordinator.sending, isTrue);

        final chosen = ['${a.sourceDir}\\uno.txt'];
        final gate = holdMany(a, chosen);
        final opened = pick(a.coordinator);
        await eventually(
          () => callsOf(a.picker, name) == 1,
          reason: 'the picker opened with the send running',
        );
        expect(a.coordinator.pickerOpen, isTrue);
        expect(a.outgoing, isNotNull);
        gate.complete();
        expect(await opened, chosen);
        expect(a.outgoing, isNotNull);
        expect(a.coordinator.sending, isTrue);
        writes.open();
        expect((await a.sentResult()).outcome, TransferOutcome.saved);
        expect((await b.receivedResult()).outcome, TransferOutcome.saved);
        await eventually(() => !a.coordinator.sending);
      }, timeout: const Timeout(Duration(seconds: 60)));

      test(
        'E516 an element send starts and ends saved while $name is open',
        () async {
          final (a, b) = await stacks();
          final path = await a.sourceFile(
            'cola.bin',
            randomBytes(64 * 1024, 9),
          );
          final gate = holdMany(a, const []);
          final opened = pick(a.coordinator);
          await eventually(() => callsOf(a.picker, name) == 1);
          expect(a.coordinator.sending, isTrue);
          final result = await a.coordinator
              .sendElement(a.targetOf(b), path, refresh: () => a.targetOf(b))
              .timeout(const Duration(seconds: 30));
          expect(result, isNotNull);
          expect(result!.outcome, TransferOutcome.saved);
          expect(a.coordinator.pickerOpen, isTrue);
          expect(a.coordinator.sending, isTrue);
          gate.complete();
          expect(await opened, isEmpty);
          expect(a.coordinator.sending, isFalse);
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }
  });
}
