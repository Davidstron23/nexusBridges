import 'dart:convert';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/messages.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

const String transferId = '0123456789abcdef0123456789abcdef';
const String rootId = 'abcdef0123456789abcdef0123456789';
final String digest = '0123456789abcdef' * 4;

Object? wire(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> fileOffer() => {
  'protocol': protocolVersion,
  'transfer': transferId,
  'name': 'informe.pdf',
  'size': 12,
  'sha256': digest,
};

Map<String, Object?> folderOffer() => {
  'protocol': protocolVersion,
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

Map<String, Object?> destination({
  Object? root = rootId,
  Object? path = const ['docs', 'sub'],
  Object? newFolder,
  bool withNewFolder = false,
}) => {'root': root, 'path': path, if (withNewFolder) 'newFolder': newFolder};

void main() {
  group('E703 DestinationRequest with exact keys (RF-413) [SEG]', () {
    test('E703 the two valid forms are read', () {
      final plain = DestinationRequest.tryParse(wire(destination()))!;
      expect(plain.rootId, rootId);
      expect(plain.path, ['docs', 'sub']);
      expect(plain.newFolder, isNull);
      final empty = DestinationRequest.tryParse(
        wire(destination(path: const <String>[])),
      )!;
      expect(empty.path, isEmpty);
      final fresh = DestinationRequest.tryParse(
        wire(destination(newFolder: 'nueva', withNewFolder: true)),
      )!;
      expect(fresh.newFolder, 'nueva');
      expect(
        DestinationRequest.tryParse(
          wire(destination(path: List.filled(64, 'a'))),
        ),
        isNotNull,
      );
      expect(
        DestinationRequest.tryParse(wire(destination(path: ['a' * 1024]))),
        isNotNull,
      );
    });

    test('E703 toJson writes newFolder only when there is one and reads '
        'back the same', () {
      const plain = DestinationRequest(rootId: rootId, path: ['a']);
      expect(wire(plain.toJson()), {
        'root': rootId,
        'path': ['a'],
      });
      expect(DestinationRequest.tryParse(wire(plain.toJson())), plain);
      const fresh = DestinationRequest(
        rootId: rootId,
        path: [],
        newFolder: 'n',
      );
      expect(wire(fresh.toJson()), {
        'root': rootId,
        'path': <Object?>[],
        'newFolder': 'n',
      });
      expect(DestinationRequest.tryParse(wire(fresh.toJson())), fresh);
    });

    test('E703 a wrong structure gives null and never throws', () {
      final bad = <Object?>[
        null,
        'x',
        42,
        <Object?>[],
        <String, Object?>{},
        {'root': rootId},
        {
          'path': ['a'],
        },
        {...destination(), 'absolutePath': r'C:\Windows'},
        {...destination(), 'extra': 1},
        destination(root: 'ABCDEF0123456789ABCDEF0123456789'),
        destination(root: 'abc'),
        destination(root: r'C:\docs'),
        destination(root: 7),
        destination(root: null),
        destination(path: 'docs'),
        destination(path: r'docs\sub'),
        destination(path: null),
        destination(path: {'0': 'a'}),
        destination(path: [1]),
        destination(path: [null]),
        destination(path: ['']),
        destination(path: ['a' * 1025]),
        destination(path: List.filled(65, 'a')),
        destination(newFolder: '', withNewFolder: true),
        destination(newFolder: null, withNewFolder: true),
        destination(newFolder: 3, withNewFolder: true),
        destination(newFolder: ['n'], withNewFolder: true),
        destination(newFolder: 'n' * 1025, withNewFolder: true),
      ];
      for (final json in bad) {
        expect(
          DestinationRequest.tryParse(wire(json)),
          isNull,
          reason: '$json',
        );
      }
    });

    test('E703 names are left to G1: the structure accepts them as text', () {
      final traps = DestinationRequest.tryParse(
        wire(destination(path: ['..', 'CON', r'C:\Windows'])),
      );
      expect(traps?.path, ['..', 'CON', r'C:\Windows']);
    });
  });

  group('E703 offers with and without destination (RF-413) [SEG]', () {
    test('E703 a file offer without destination keeps the 006 keys', () {
      final offer = OfferRequest.tryParse(wire(fileOffer()))!;
      expect(offer.destination, isNull);
      final json = wire(offer.toJson())! as Map<String, Object?>;
      expect(json.containsKey('destination'), isFalse);
    });

    test('E703 a file offer with destination reads it and writes it back', () {
      final offer = OfferRequest.tryParse(
        wire({
          ...fileOffer(),
          'destination': destination(newFolder: 'nueva', withNewFolder: true),
        }),
      )!;
      expect(
        offer.destination,
        const DestinationRequest(
          rootId: rootId,
          path: ['docs', 'sub'],
          newFolder: 'nueva',
        ),
      );
      final back = OfferRequest.tryParse(wire(offer.toJson()))!;
      expect(back.destination, offer.destination);
      expect((wire(offer.toJson())! as Map).keys.toSet(), {
        ...fileOffer().keys,
        'destination',
      });
    });

    test('E703 a folder offer with and without destination', () {
      final without = FolderOfferRequest.tryParse(wire(folderOffer()))!;
      expect(without.destination, isNull);
      final withOne = FolderOfferRequest.tryParse(
        wire({...folderOffer(), 'destination': destination()}),
      )!;
      expect(
        withOne.destination,
        const DestinationRequest(rootId: rootId, path: ['docs', 'sub']),
      );
      final back = FolderOfferRequest.tryParse(wire(withOne.toJson()))!;
      expect(back.destination, withOne.destination);
    });

    test('E703 a malformed destination, an extra key or a path that is not '
        'a list make both offers malformed', () {
      final badDestinations = <Object?>[
        null,
        'docs',
        <Object?>[],
        destination(path: 'docs'),
        destination(path: r'docs\sub'),
        destination(root: 'XYZ'),
        {...destination(), 'absolutePath': r'C:\Windows'},
        destination(newFolder: '', withNewFolder: true),
      ];
      for (final bad in badDestinations) {
        expect(
          OfferRequest.tryParse(wire({...fileOffer(), 'destination': bad})),
          isNull,
          reason: 'file $bad',
        );
        expect(
          FolderOfferRequest.tryParse(
            wire({...folderOffer(), 'destination': bad}),
          ),
          isNull,
          reason: 'folder $bad',
        );
      }
      expect(
        OfferRequest.tryParse(
          wire({...fileOffer(), 'absolutePath': r'C:\Windows'}),
        ),
        isNull,
      );
      expect(
        OfferRequest.tryParse(
          wire({
            ...fileOffer(),
            'destination': destination(),
            'absolutePath': r'C:\Windows',
          }),
        ),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(
          wire({
            ...folderOffer(),
            'destination': destination(),
            'absolutePath': r'C:\Windows',
          }),
        ),
        isNull,
      );
      expect(
        FolderOfferRequest.tryParse(
          wire({...folderOffer(), 'absolutePath': r'C:\Windows'}),
        ),
        isNull,
      );
    });
  });

  group('E707 new answers of the offer and the final state', () {
    test('E707 offerOutcome maps the three new refusals', () {
      expect(
        offerOutcome(403, {'error': 'default_only'}),
        TransferOutcome.defaultFolderOnly,
      );
      expect(
        offerOutcome(403, {'error': 'destination_unavailable'}),
        TransferOutcome.destinationUnavailable,
      );
      expect(
        offerOutcome(404, {'error': 'destination_missing'}),
        TransferOutcome.destinationMissing,
      );
    });

    test('E707 a 404 without the code and other codes keep the old '
        'meaning', () {
      expect(offerOutcome(404, const {}), TransferOutcome.noContact);
      expect(
        offerOutcome(404, {'error': 'not_found'}),
        TransferOutcome.noContact,
      );
      expect(
        offerOutcome(404, {'error': 'default_only'}),
        TransferOutcome.noContact,
      );
      expect(
        offerOutcome(403, {'error': 'destination_missing'}),
        TransferOutcome.noContact,
      );
      expect(offerOutcome(403, const {}), TransferOutcome.noContact);
      expect(
        offerOutcome(403, {'error': 'declined'}),
        TransferOutcome.declined,
      );
    });

    test('E707 failed destination_lost reads as destinationLost and goes '
        'back on the wire', () {
      final state = RemoteState.tryParse(
        wire({'state': 'failed', 'reason': 'destination_lost'}),
      );
      expect(state, isNotNull);
      expect(outcomeOfRemote(state!), TransferOutcome.destinationLost);
      final back = remoteOf(TransferOutcome.destinationLost);
      expect(back, const RemoteState.failed(reason: 'destination_lost'));
      expect(
        RemoteState.tryParse(
          wire({'state': 'failed', 'reason': 'destination_gone'}),
        ),
        isNull,
      );
    });

    test('E707 the six new outcomes have their kind', () {
      expect(
        TransferOutcome.defaultFolderOnly.kind,
        TransferResultKind.rejected,
      );
      expect(
        TransferOutcome.destinationUnavailable.kind,
        TransferResultKind.rejected,
      );
      expect(
        TransferOutcome.destinationMissing.kind,
        TransferResultKind.rejected,
      );
      expect(TransferOutcome.destinationLost.kind, TransferResultKind.failed);
      expect(TransferOutcome.shareRemoved.kind, TransferResultKind.cancelled);
      expect(
        TransferOutcome.peerMarkedForeign.kind,
        TransferResultKind.cancelled,
      );
    });
  });
}
