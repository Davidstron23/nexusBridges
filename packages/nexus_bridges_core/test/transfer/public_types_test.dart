import 'dart:io';

import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

const OutgoingTransferView outgoing = OutgoingTransferView(
  peerFingerprint: 'F1',
  peerName: 'Portatil',
  fileName: 'informe.pdf',
  size: 10,
  isProgram: false,
  phase: OutgoingPhase.uploading,
  sentBytes: 4,
  cancelling: false,
);

const FolderQuestionView question = FolderQuestionView(
  kind: FolderQuestionKind.firstTime,
  proposedPath: r'C:\Users\u\Downloads\NexusBridges',
);

const IncomingTransferView incoming = IncomingTransferView(
  sessionId: 'S1',
  peerFingerprint: 'F1',
  peerName: 'Portatil',
  fileName: 'informe.pdf',
  size: 10,
  isProgram: false,
  stage: IncomingStage.folderQuestion,
  folder: question,
);

const TransferResultView result = TransferResultView(
  direction: TransferDirection.incoming,
  peerFingerprint: 'F1',
  peerName: null,
  fileName: 'informe (1).pdf',
  isProgram: false,
  outcome: TransferOutcome.saved,
  canReveal: true,
);

SendTarget target({
  String fingerprint = 'F1',
  String address = '127.0.0.1',
  int port = 53530,
  String interfaceId = 'eth#127.0.0.1',
  String localAddress = '127.0.0.2',
}) => SendTarget(
  fingerprint: fingerprint,
  address: InternetAddress(address),
  port: port,
  interfaceId: interfaceId,
  localAddress: InternetAddress(localAddress),
);

void expectSame(Object a, Object b) {
  expect(a, b);
  expect(a.hashCode, b.hashCode);
}

void expectDifferent(Map<String, Object> variants, Object base) {
  for (final MapEntry(key: field, value: other) in variants.entries) {
    expect(other, isNot(base), reason: field);
  }
}

void main() {
  group('TransferOutcome.kind (plan, public types)', () {
    final expected = <TransferOutcome, TransferResultKind>{
      TransferOutcome.saved: TransferResultKind.saved,
      TransferOutcome.savedWithoutMark: TransferResultKind.saved,
      TransferOutcome.declined: TransferResultKind.rejected,
      TransferOutcome.busy: TransferResultKind.rejected,
      TransferOutcome.unanswered: TransferResultKind.rejected,
      TransferOutcome.invalidName: TransferResultKind.rejected,
      TransferOutcome.blockedType: TransferResultKind.rejected,
      TransferOutcome.incompatible: TransferResultKind.rejected,
      TransferOutcome.noSpace: TransferResultKind.rejected,
      TransferOutcome.noFolder: TransferResultKind.rejected,
      TransferOutcome.pathTooLong: TransferResultKind.rejected,
      TransferOutcome.cancelledHere: TransferResultKind.cancelled,
      TransferOutcome.cancelledByPeer: TransferResultKind.cancelled,
      TransferOutcome.unpaired: TransferResultKind.cancelled,
      TransferOutcome.unreadable: TransferResultKind.failed,
      TransferOutcome.noContact: TransferResultKind.failed,
      TransferOutcome.uploadNotStarted: TransferResultKind.failed,
      TransferOutcome.connectionLost: TransferResultKind.failed,
      TransferOutcome.idle: TransferResultKind.failed,
      TransferOutcome.tooManyBytes: TransferResultKind.failed,
      TransferOutcome.writeFailed: TransferResultKind.failed,
      TransferOutcome.diskFull: TransferResultKind.failed,
      TransferOutcome.damaged: TransferResultKind.failed,
      TransferOutcome.markFailed: TransferResultKind.failed,
      TransferOutcome.moveFailed: TransferResultKind.failed,
      TransferOutcome.noFreeName: TransferResultKind.failed,
      TransferOutcome.interfaceDown: TransferResultKind.failed,
      TransferOutcome.unconfirmed: TransferResultKind.unconfirmed,
      TransferOutcome.shortcut: TransferResultKind.rejected,
      TransferOutcome.wholeDrive: TransferResultKind.rejected,
      TransferOutcome.protectedData: TransferResultKind.rejected,
      TransferOutcome.notFound: TransferResultKind.failed,
      TransferOutcome.tooManyEntries: TransferResultKind.rejected,
      TransferOutcome.tooDeep: TransferResultKind.rejected,
      TransferOutcome.tooLargeForPeer: TransferResultKind.rejected,
      TransferOutcome.unexpectedData: TransferResultKind.failed,
    };

    test('the table covers every outcome of the plan, in its order', () {
      expect(TransferOutcome.values, expected.keys.toList());
    });

    for (final MapEntry(key: outcome, value: kind) in expected.entries) {
      test('${outcome.name} is ${kind.name}', () {
        expect(outcome.kind, kind);
      });
    }
  });

  group('the public enums have the values of the plan', () {
    test('directions, kinds, phases, stages, questions and problems', () {
      expect(TransferDirection.values, [
        TransferDirection.outgoing,
        TransferDirection.incoming,
      ]);
      expect(TransferResultKind.values.map((v) => v.name), [
        'saved',
        'rejected',
        'cancelled',
        'failed',
        'unconfirmed',
      ]);
      expect(OutgoingPhase.values.map((v) => v.name), [
        'preparing',
        'requesting',
        'waiting',
        'uploading',
        'verifying',
      ]);
      expect(IncomingStage.values.map((v) => v.name), [
        'warning',
        'folderQuestion',
        'waitingData',
        'receiving',
        'verifying',
        'ended',
      ]);
      expect(FolderQuestionKind.values.map((v) => v.name), [
        'firstTime',
        'thisTime',
      ]);
      expect(FolderProblem.values.map((v) => v.name), [
        'rememberedUnavailable',
        'forbidden',
        'cannotUse',
        'unknownVolume',
        'stillUnavailable',
        'adminShare',
      ]);
      expect(AfterEndResult.values.map((v) => v.name), [
        'remembered',
        'notUsable',
        'needsConfirmation',
      ]);
      expect(RevealResult.values.map((v) => v.name), [
        'shown',
        'folderOnly',
        'unavailable',
      ]);
      expect(SendStart.values.map((v) => v.name), [
        'started',
        'nothingChosen',
        'alreadySending',
      ]);
    });
  });

  group('the views and SendTarget compare by value', () {
    test('OutgoingTransferView', () {
      OutgoingTransferView copy({
        String peerFingerprint = 'F1',
        String? peerName = 'Portatil',
        String fileName = 'informe.pdf',
        int size = 10,
        bool isProgram = false,
        OutgoingPhase phase = OutgoingPhase.uploading,
        int sentBytes = 4,
        bool cancelling = false,
      }) => OutgoingTransferView(
        peerFingerprint: peerFingerprint,
        peerName: peerName,
        fileName: fileName,
        size: size,
        isProgram: isProgram,
        phase: phase,
        sentBytes: sentBytes,
        cancelling: cancelling,
      );
      expectSame(outgoing, copy());
      expectDifferent({
        'peerFingerprint': copy(peerFingerprint: 'F2'),
        'peerName': copy(peerName: null),
        'fileName': copy(fileName: 'otro.pdf'),
        'size': copy(size: 11),
        'isProgram': copy(isProgram: true),
        'phase': copy(phase: OutgoingPhase.verifying),
        'sentBytes': copy(sentBytes: 5),
        'cancelling': copy(cancelling: true),
      }, outgoing);
    });

    test('FolderQuestionView, with its defaults', () {
      expect(question.problem, isNull);
      expect(question.problemPath, isNull);
      expect(question.cautionPath, isNull);
      expect(question.cautionNoMark, isFalse);
      expect(question.cautionRemote, isFalse);
      expect(question.pickerOpen, isFalse);
      expect(question.inspecting, isFalse);
      expect(question.afterEnd, isNull);
      expect(question.afterEndPath, isNull);

      FolderQuestionView copy({
        FolderQuestionKind kind = FolderQuestionKind.firstTime,
        String proposedPath = r'C:\Users\u\Downloads\NexusBridges',
        FolderProblem? problem,
        String? problemPath,
        String? cautionPath,
        bool cautionNoMark = false,
        bool cautionRemote = false,
        bool pickerOpen = false,
        bool inspecting = false,
        AfterEndResult? afterEnd,
        String? afterEndPath,
      }) => FolderQuestionView(
        kind: kind,
        proposedPath: proposedPath,
        problem: problem,
        problemPath: problemPath,
        cautionPath: cautionPath,
        cautionNoMark: cautionNoMark,
        cautionRemote: cautionRemote,
        pickerOpen: pickerOpen,
        inspecting: inspecting,
        afterEnd: afterEnd,
        afterEndPath: afterEndPath,
      );
      expectSame(question, copy());
      expectDifferent({
        'kind': copy(kind: FolderQuestionKind.thisTime),
        'proposedPath': copy(proposedPath: r'D:\x'),
        'problem': copy(problem: FolderProblem.unknownVolume),
        'problemPath': copy(problemPath: r'E:\'),
        'cautionPath': copy(cautionPath: r'E:\'),
        'cautionNoMark': copy(cautionNoMark: true),
        'cautionRemote': copy(cautionRemote: true),
        'pickerOpen': copy(pickerOpen: true),
        'inspecting': copy(inspecting: true),
        'afterEnd': copy(afterEnd: AfterEndResult.remembered),
        'afterEndPath': copy(afterEndPath: r'D:\Recibidos'),
      }, question);
    });

    test('E271 (f) RF-209: two ended views that differ only in afterEndPath '
        'are different and hash differently', () {
      const remembered = FolderQuestionView(
        kind: FolderQuestionKind.firstTime,
        proposedPath: r'C:\Users\u\Downloads\NexusBridges',
        afterEnd: AfterEndResult.remembered,
        afterEndPath: r'D:\Recibidos',
      );
      const other = FolderQuestionView(
        kind: FolderQuestionKind.firstTime,
        proposedPath: r'C:\Users\u\Downloads\NexusBridges',
        afterEnd: AfterEndResult.remembered,
        afterEndPath: r'E:\Otra',
      );
      const none = FolderQuestionView(
        kind: FolderQuestionKind.firstTime,
        proposedPath: r'C:\Users\u\Downloads\NexusBridges',
        afterEnd: AfterEndResult.remembered,
      );
      expect(remembered, isNot(other));
      expect(remembered.hashCode, isNot(other.hashCode));
      expect(remembered, isNot(none));
      expect(remembered.hashCode, isNot(none.hashCode));
      expectSame(
        remembered,
        const FolderQuestionView(
          kind: FolderQuestionKind.firstTime,
          proposedPath: r'C:\Users\u\Downloads\NexusBridges',
          afterEnd: AfterEndResult.remembered,
          afterEndPath: r'D:\Recibidos',
        ),
      );
    });

    test('IncomingTransferView, with its defaults and the nested question', () {
      const bare = IncomingTransferView(
        sessionId: 'S1',
        peerFingerprint: 'F1',
        peerName: null,
        fileName: 'a',
        size: 0,
        isProgram: false,
        stage: IncomingStage.warning,
      );
      expect(bare.withoutMark, isFalse);
      expect(bare.folder, isNull);
      expect(bare.receivedBytes, 0);

      IncomingTransferView copy({
        String sessionId = 'S1',
        String peerFingerprint = 'F1',
        String? peerName = 'Portatil',
        String fileName = 'informe.pdf',
        int size = 10,
        bool isProgram = false,
        IncomingStage stage = IncomingStage.folderQuestion,
        bool withoutMark = false,
        FolderQuestionView? folder = question,
        int receivedBytes = 0,
      }) => IncomingTransferView(
        sessionId: sessionId,
        peerFingerprint: peerFingerprint,
        peerName: peerName,
        fileName: fileName,
        size: size,
        isProgram: isProgram,
        stage: stage,
        withoutMark: withoutMark,
        folder: folder,
        receivedBytes: receivedBytes,
      );
      expectSame(incoming, copy());
      expectSame(
        incoming,
        copy(
          folder: FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: question.proposedPath,
          ),
        ),
      );
      expectDifferent({
        'sessionId': copy(sessionId: 'S2'),
        'peerFingerprint': copy(peerFingerprint: 'F2'),
        'peerName': copy(peerName: 'Otro'),
        'fileName': copy(fileName: 'b'),
        'size': copy(size: 9),
        'isProgram': copy(isProgram: true),
        'stage': copy(stage: IncomingStage.receiving),
        'withoutMark': copy(withoutMark: true),
        'folder': copy(folder: null),
        'nested folder': copy(
          folder: const FolderQuestionView(
            kind: FolderQuestionKind.firstTime,
            proposedPath: r'C:\Users\u\Downloads\NexusBridges',
            inspecting: true,
          ),
        ),
        'receivedBytes': copy(receivedBytes: 1),
      }, incoming);
      expect(copy(sessionId: 'S2').hashCode, isNot(incoming.hashCode));
      expect(incoming.sessionId, 'S1');
    });

    test('TransferResultView', () {
      TransferResultView copy({
        TransferDirection direction = TransferDirection.incoming,
        String peerFingerprint = 'F1',
        String? peerName,
        String fileName = 'informe (1).pdf',
        bool isProgram = false,
        TransferOutcome outcome = TransferOutcome.saved,
        bool canReveal = true,
      }) => TransferResultView(
        direction: direction,
        peerFingerprint: peerFingerprint,
        peerName: peerName,
        fileName: fileName,
        isProgram: isProgram,
        outcome: outcome,
        canReveal: canReveal,
      );
      expectSame(result, copy());
      expectDifferent({
        'direction': copy(direction: TransferDirection.outgoing),
        'peerFingerprint': copy(peerFingerprint: 'F2'),
        'peerName': copy(peerName: 'Portatil'),
        'fileName': copy(fileName: 'informe.pdf'),
        'isProgram': copy(isProgram: true),
        'outcome': copy(outcome: TransferOutcome.savedWithoutMark),
        'canReveal': copy(canReveal: false),
      }, result);
    });

    test('SendTarget, comparing the addresses by value', () {
      expectSame(target(), target());
      expectDifferent({
        'fingerprint': target(fingerprint: 'F2'),
        'address': target(address: '127.0.0.3'),
        'port': target(port: 53531),
        'interfaceId': target(interfaceId: 'wifi#127.0.0.1'),
        'localAddress': target(localAddress: '127.0.0.1'),
      }, target());
    });
  });

  group('TransferEvent', () {
    String describe(TransferEvent event) => switch (event) {
      ReceiveFolderNotSaved(:final path) => 'not saved $path',
      PeerCancelledTransfer(:final peerFingerprint, :final peerName) =>
        'cancelled by ${peerName ?? peerFingerprint}',
    };

    test('has exactly the two events of the plan', () {
      expect(
        describe(const ReceiveFolderNotSaved(r'D:\Recibidos')),
        r'not saved D:\Recibidos',
      );
      expect(
        describe(
          const PeerCancelledTransfer(peerFingerprint: 'F1', peerName: null),
        ),
        'cancelled by F1',
      );
      expect(
        describe(
          const PeerCancelledTransfer(peerFingerprint: 'F1', peerName: 'PC'),
        ),
        'cancelled by PC',
      );
    });
  });

  group('ReceiveFolder and ReceiveFolderStore', () {
    test('a folder keeps its path and its volume', () {
      const folder = ReceiveFolder(
        path: r'D:\Recibidos',
        volumeId: 'NTFS-1a2b3c4d',
      );
      expect(folder.path, r'D:\Recibidos');
      expect(folder.volumeId, 'NTFS-1a2b3c4d');
    });

    test('the store is an interface that the node can implement', () async {
      final ReceiveFolderStore store = _MemoryStore();
      expect(await store.load(), isNull);
      expect(
        await store.save(
          const ReceiveFolder(path: r'D:\R', volumeId: 'NTFS-1'),
        ),
        isTrue,
      );
      expect((await store.load())!.path, r'D:\R');
    });
  });
}

final class _MemoryStore implements ReceiveFolderStore {
  ReceiveFolder? _folder;

  @override
  Future<ReceiveFolder?> load() async => _folder;

  @override
  Future<bool> save(ReceiveFolder folder) async {
    _folder = folder;
    return true;
  }
}
