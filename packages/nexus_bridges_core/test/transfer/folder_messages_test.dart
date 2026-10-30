import 'dart:convert';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/messages.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

const String transferId = '0123456789abcdef0123456789abcdef';
const String permitValue = 'fedcba9876543210fedcba9876543210';

Object? wire(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> folderOfferJson() => {
  'protocol': '1.1',
  'transfer': transferId,
  'kind': 'folder',
  'name': 'proj',
  'entries': 5,
  'files': 2,
  'bytes': 28,
  'depth': 3,
  'longest': 40,
  'manifestBytes': 400,
};

Map<String, Object?> folderOfferWith(String key, Object? value) =>
    folderOfferJson()..[key] = value;

Map<String, Object?> folderOfferWithout(String key) =>
    folderOfferJson()..remove(key);

void main() {
  group('E440, RF-264 and RF-272: FolderOfferRequest', () {
    test('a well formed folder offer parses with every field', () {
      final offer = FolderOfferRequest.tryParse(wire(folderOfferJson()))!;
      expect(offer.transfer, transferId);
      expect(offer.name, 'proj');
      expect(offer.entries, 5);
      expect(offer.files, 2);
      expect(offer.bytes, 28);
      expect(offer.depth, 3);
      expect(offer.longest, 40);
      expect(offer.manifestBytes, 400);
    });

    test('toJson round trips with the exact keys and protocol 1.1', () {
      const offer = FolderOfferRequest(
        transfer: transferId,
        name: 'proj',
        entries: 5,
        files: 2,
        bytes: 28,
        depth: 3,
        longest: 40,
        manifestBytes: 400,
      );
      final json = wire(offer.toJson())! as Map<String, Object?>;
      expect(json, folderOfferJson());
      expect(json.containsKey('destination'), isFalse);
      final back = FolderOfferRequest.tryParse(json)!;
      expect(back.toJson(), offer.toJson());
    });

    test('RF-272: an extra key such as destination makes it malformed', () {
      expect(
        FolderOfferRequest.tryParse(
          wire(folderOfferWith('destination', 'C:\\Users\\otro')),
        ),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(
          wire(folderOfferWith('destination', {'root': 'x', 'path': ''})),
        ),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('size', 28))),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('sha256', 'a' * 64))),
        isNull,
      );
    });

    test('every missing key makes it malformed', () {
      for (final key in folderOfferJson().keys) {
        expect(
          FolderOfferRequest.tryParse(wire(folderOfferWithout(key))),
          isNull,
          reason: key,
        );
      }
    });

    test('kind must be folder and the protocol major must match', () {
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('kind', 'file'))),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('protocol', '2.0'))),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('protocol', '1.0'))),
        isNotNull,
      );
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('transfer', 'ABC'))),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('name', 7))),
        isNull,
      );
    });

    test('files greater than entries is malformed; equal is fine', () {
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('files', 6))),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('files', 5))),
        isNotNull,
      );
    });

    test('manifestBytes below entries * 6 is malformed; the boundary is '
        'fine', () {
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('manifestBytes', 29))),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(wire(folderOfferWith('manifestBytes', 30))),
        isNotNull,
      );
    });

    test('an empty chosen folder: 0 entries, 0 files and a manifest of 0 '
        'bytes is well formed', () {
      final empty = {
        ...folderOfferJson(),
        'entries': 0,
        'files': 0,
        'bytes': 0,
        'depth': 0,
        'longest': 0,
        'manifestBytes': 0,
      };
      final offer = FolderOfferRequest.tryParse(wire(empty))!;
      expect(offer.entries, 0);
      expect(offer.manifestBytes, 0);
    });

    test('negative or non integer numbers are malformed', () {
      for (final key in [
        'entries',
        'files',
        'bytes',
        'depth',
        'longest',
        'manifestBytes',
      ]) {
        expect(
          FolderOfferRequest.tryParse(wire(folderOfferWith(key, -1))),
          isNull,
          reason: '$key -1',
        );
        expect(
          FolderOfferRequest.tryParse(wire(folderOfferWith(key, 1.5))),
          isNull,
          reason: '$key 1.5',
        );
        expect(
          FolderOfferRequest.tryParse(wire(folderOfferWith(key, '5'))),
          isNull,
          reason: '$key string',
        );
      }
    });

    test('a non object is malformed', () {
      expect(FolderOfferRequest.tryParse(null), isNull);
      expect(FolderOfferRequest.tryParse([folderOfferJson()]), isNull);
      expect(FolderOfferRequest.tryParse('proj'), isNull);
    });

    test(
      'exceedsLimits flags entries, depth and manifest above the limits',
      () {
        FolderOfferRequest offer({
          int entries = 5,
          int depth = 3,
          int manifestBytes = 400,
        }) => FolderOfferRequest(
          transfer: transferId,
          name: 'proj',
          entries: entries,
          files: 0,
          bytes: 0,
          depth: depth,
          longest: 40,
          manifestBytes: manifestBytes,
        );
        expect(offer().exceedsLimits, isFalse);
        expect(
          offer(
            entries: Limits.maxFolderEntries,
            depth: Limits.maxFolderDepth,
            manifestBytes: Limits.maxManifestBytes,
          ).exceedsLimits,
          isFalse,
        );
        expect(
          offer(entries: Limits.maxFolderEntries + 1).exceedsLimits,
          isTrue,
        );
        expect(offer(depth: Limits.maxFolderDepth + 1).exceedsLimits, isTrue);
        expect(
          offer(manifestBytes: Limits.maxManifestBytes + 1).exceedsLimits,
          isTrue,
        );
      },
    );
  });

  group('E440: RemoteState.manifest and saved with a name', () {
    test('manifest carries its permit and round trips', () {
      const state = RemoteState.manifest(permit: permitValue);
      final json = wire(state.toJson());
      expect(json, {'state': 'manifest', 'permit': permitValue});
      expect(RemoteState.tryParse(json), state);
      expect(outcomeOfRemote(state), isNull);
    });

    test('manifest without permit, with a bad permit or with an extra key is '
        'malformed', () {
      expect(RemoteState.tryParse({'state': 'manifest'}), isNull);
      expect(
        RemoteState.tryParse({'state': 'manifest', 'permit': 'XYZ'}),
        isNull,
      );
      expect(
        RemoteState.tryParse({
          'state': 'manifest',
          'permit': permitValue,
          'picker': false,
        }),
        isNull,
      );
    });

    test('saved without name keeps the 004 shape', () {
      const state = RemoteState.saved(marked: true);
      final json = wire(state.toJson());
      expect(json, {'state': 'saved', 'marked': true});
      expect(RemoteState.tryParse(json), state);
      expect(RemoteState.tryParse(json)!.name, isNull);
      expect(outcomeOfRemote(state), TransferOutcome.saved);
    });

    test('saved with a name carries it and round trips', () {
      const state = RemoteState.saved(marked: false, name: 'proj (1)');
      final json = wire(state.toJson());
      expect(json, {'state': 'saved', 'marked': false, 'name': 'proj (1)'});
      final back = RemoteState.tryParse(json)!;
      expect(back, state);
      expect(back.name, 'proj (1)');
      expect(outcomeOfRemote(back), TransferOutcome.savedWithoutMark);
    });

    test('with three keys, name must be a String', () {
      for (final bad in <Object?>[
        null,
        7,
        true,
        <String>['proj'],
      ]) {
        expect(
          RemoteState.tryParse({'state': 'saved', 'marked': true, 'name': bad}),
          isNull,
          reason: '$bad',
        );
      }
      expect(
        RemoteState.tryParse({'state': 'saved', 'marked': 'yes', 'name': 'p'}),
        isNull,
      );
      expect(
        RemoteState.tryParse({
          'state': 'saved',
          'marked': true,
          'name': 'p',
          'extra': 1,
        }),
        isNull,
      );
      expect(
        RemoteState.tryParse({'state': 'saved', 'name': 'p', 'other': true}),
        isNull,
      );
    });

    test('failed with unexpected_data maps to unexpectedData both ways', () {
      const state = RemoteState.failed(reason: 'unexpected_data');
      expect(RemoteState.tryParse(wire(state.toJson())), state);
      expect(outcomeOfRemote(state), TransferOutcome.unexpectedData);
      expect(remoteOf(TransferOutcome.unexpectedData), state);
    });
  });

  group('E440: CancelRequest with entry', () {
    test('entry travels only with unreadable', () {
      const request = CancelRequest(
        transfer: transferId,
        reason: CancelReason.unreadable,
        entry: 3,
      );
      final json = wire(request.toJson());
      expect(json, {
        'transfer': transferId,
        'reason': 'unreadable',
        'entry': 3,
      });
      final back = CancelRequest.tryParse(json)!;
      expect(back.reason, CancelReason.unreadable);
      expect(back.entry, 3);
    });

    test('entry with another reason is malformed', () {
      for (final reason in ['cancelled', 'no_contact']) {
        expect(
          CancelRequest.tryParse({
            'transfer': transferId,
            'reason': reason,
            'entry': 3,
          }),
          isNull,
          reason: reason,
        );
      }
    });

    test('entry goes from 1 to 100000', () {
      for (final entry in [1, 2, 99999, Limits.maxFolderEntries]) {
        expect(
          CancelRequest.tryParse({
            'transfer': transferId,
            'reason': 'unreadable',
            'entry': entry,
          })?.entry,
          entry,
          reason: '$entry',
        );
      }
      expect(Limits.maxFolderEntries, 100000);
      for (final entry in <Object?>[0, -1, 100001, 1.5, '3', null]) {
        expect(
          CancelRequest.tryParse({
            'transfer': transferId,
            'reason': 'unreadable',
            'entry': entry,
          }),
          isNull,
          reason: '$entry',
        );
      }
    });

    test('without entry, the 004 shapes still parse and omit entry', () {
      for (final reason in CancelReason.values) {
        final back = CancelRequest.tryParse({
          'transfer': transferId,
          'reason': reason.wire,
        })!;
        expect(back.reason, reason);
        expect(back.entry, isNull);
        expect(back.toJson().containsKey('entry'), isFalse);
      }
    });

    test('an extra key besides entry is malformed', () {
      expect(
        CancelRequest.tryParse({
          'transfer': transferId,
          'reason': 'unreadable',
          'entry': 3,
          'path': 'a\\b.txt',
        }),
        isNull,
      );
    });
  });

  group('E440: offerOutcome with 413', () {
    test('413 too_large is tooLargeForPeer', () {
      expect(
        offerOutcome(413, {'error': 'too_large'}),
        TransferOutcome.tooLargeForPeer,
      );
    });

    test('413 without that error is incompatible', () {
      expect(offerOutcome(413, {}), TransferOutcome.incompatible);
      expect(
        offerOutcome(413, {'error': 'other'}),
        TransferOutcome.incompatible,
      );
    });

    test('tooLargeForPeer is a rejected outcome', () {
      expect(TransferOutcome.tooLargeForPeer.kind, TransferResultKind.rejected);
    });
  });
}
