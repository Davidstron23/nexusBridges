import 'dart:convert';

import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/transfer/messages.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

const String transferId = '0123456789abcdef0123456789abcdef';
const String acceptedValue = 'fedcba9876543210fedcba9876543210';
final String digest = '0123456789abcdef' * 4;

Object? wire(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> offerJson() => {
  'protocol': '1.0',
  'transfer': transferId,
  'name': 'informe.pdf',
  'size': 123456,
  'sha256': digest,
};

Map<String, Object?> offerWith(String key, Object? value) =>
    offerJson()..[key] = value;

Map<String, Object?> offerWithout(String key) => offerJson()..remove(key);

const Map<String, TransferOutcome> rejectedReasons = {
  'declined': TransferOutcome.declined,
  'unanswered': TransferOutcome.unanswered,
  'no_folder': TransferOutcome.noFolder,
  'no_space': TransferOutcome.noSpace,
  'path_too_long': TransferOutcome.pathTooLong,
};

const Map<String, TransferOutcome> failedReasons = {
  'upload_not_started': TransferOutcome.uploadNotStarted,
  'connection_lost': TransferOutcome.connectionLost,
  'idle': TransferOutcome.idle,
  'too_many_bytes': TransferOutcome.tooManyBytes,
  'write_failed': TransferOutcome.writeFailed,
  'disk_full': TransferOutcome.diskFull,
  'damaged': TransferOutcome.damaged,
  'mark_failed': TransferOutcome.markFailed,
  'move_failed': TransferOutcome.moveFailed,
  'no_free_name': TransferOutcome.noFreeName,
  'interface_down': TransferOutcome.interfaceDown,
  'unreadable': TransferOutcome.unreadable,
};

Map<String, Map<String, Object?>> tableRows() => {
  'waiting, no picker': {'state': 'waiting', 'picker': false},
  'waiting, picker open': {'state': 'waiting', 'picker': true},
  'accepted': {'state': 'accepted', 'permit': acceptedValue},
  'uploading': {'state': 'uploading'},
  'saving': {'state': 'saving'},
  'saved with mark': {'state': 'saved', 'marked': true},
  'saved without mark': {'state': 'saved', 'marked': false},
  for (final reason in rejectedReasons.keys)
    'rejected $reason': {'state': 'rejected', 'reason': reason},
  'cancelled': {'state': 'cancelled'},
  for (final reason in failedReasons.keys)
    'failed $reason': {'state': 'failed', 'reason': reason},
};

void main() {
  group('E8, RF-144: OfferRequest', () {
    test('a well formed offer parses with its fields', () {
      final offer = OfferRequest.tryParse(wire(offerJson()))!;

      expect(offer.transfer, transferId);
      expect(offer.name, 'informe.pdf');
      expect(offer.size, 123456);
      expect(offer.sha256, digest);
    });

    test('toJson gives exactly the keys of the format, with the protocol '
        'version, and parses back', () {
      const offer = OfferRequest(
        transfer: transferId,
        name: 'informe.pdf',
        size: 0,
        sha256:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );

      final json = offer.toJson();

      expect(json.keys.toSet(), {
        'protocol',
        'transfer',
        'name',
        'size',
        'sha256',
      });
      expect(json['protocol'], protocolVersion);
      final back = OfferRequest.tryParse(wire(json))!;
      expect(back.transfer, offer.transfer);
      expect(back.name, offer.name);
      expect(back.size, offer.size);
      expect(back.sha256, offer.sha256);
    });

    test('size 0 and size 2^53 - 1 are accepted', () {
      expect(OfferRequest.tryParse(wire(offerWith('size', 0)))!.size, 0);
      expect(
        OfferRequest.tryParse(wire(offerWith('size', Limits.maxTransferSize)))!
            .size,
        9007199254740991,
      );
    });

    test('another minor version of the same major is compatible', () {
      expect(
        OfferRequest.tryParse(wire(offerWith('protocol', '1.7'))),
        isNotNull,
      );
    });

    test('the name is not validated here: any string parses', () {
      final offer = OfferRequest.tryParse(wire(offerWith('name', 'CON')))!;
      expect(offer.name, 'CON');
      expect(OfferRequest.tryParse(wire(offerWith('name', '')))!.name, '');
    });

    test('a key too many gives null', () {
      expect(OfferRequest.tryParse(wire(offerWith('extra', 1))), isNull);
      expect(OfferRequest.tryParse(wire(offerWith('permit', null))), isNull);
    });

    test('each missing key gives null', () {
      for (final key in offerJson().keys) {
        expect(
          OfferRequest.tryParse(wire(offerWithout(key))),
          isNull,
          reason: key,
        );
      }
    });

    test('size -1, 1.5, "10" and 2^53 give null', () {
      expect(OfferRequest.tryParse(wire(offerWith('size', -1))), isNull);
      expect(OfferRequest.tryParse(jsonDecode(_offerText('1.5'))), isNull);
      expect(OfferRequest.tryParse(wire(offerWith('size', '10'))), isNull);
      expect(
        OfferRequest.tryParse(jsonDecode(_offerText('9007199254740992'))),
        isNull,
      );
      expect(OfferRequest.tryParse(wire(offerWith('size', null))), isNull);
    });

    test('a sha256 in upper case, of 63 or 65 characters, or not hex gives '
        'null', () {
      for (final value in <Object?>[
        digest.toUpperCase(),
        digest.substring(1),
        '${digest}0',
        'g${digest.substring(1)}',
        null,
        64,
      ]) {
        expect(
          OfferRequest.tryParse(wire(offerWith('sha256', value))),
          isNull,
          reason: '$value',
        );
      }
    });

    test('a transfer of 31 or 33 characters, in upper case or not a string '
        'gives null', () {
      for (final value in <Object?>[
        transferId.substring(1),
        '${transferId}0',
        transferId.toUpperCase(),
        'z${transferId.substring(1)}',
        null,
        12,
      ]) {
        expect(
          OfferRequest.tryParse(wire(offerWith('transfer', value))),
          isNull,
          reason: '$value',
        );
      }
    });

    test('protocol "2.0" or a malformed protocol gives null', () {
      for (final value in <Object?>[
        '2.0',
        '0.9',
        '1',
        'v1.0',
        '1.0.0',
        1.0,
        null,
      ]) {
        expect(
          OfferRequest.tryParse(wire(offerWith('protocol', value))),
          isNull,
          reason: '$value',
        );
      }
    });

    test('a name that is not a string gives null', () {
      for (final value in <Object?>[
        5,
        null,
        true,
        <Object?>[],
        <String, Object?>{},
      ]) {
        expect(
          OfferRequest.tryParse(wire(offerWith('name', value))),
          isNull,
          reason: '$value',
        );
      }
    });

    test('anything that is not an object gives null and never throws', () {
      for (final value in <Object?>[
        null,
        'offer',
        42,
        <Object?>[offerJson()],
        <Object?, Object?>{1: 2},
      ]) {
        expect(OfferRequest.tryParse(value), isNull, reason: '$value');
      }
    });
  });

  group('WaitRequest and CancelRequest (plan, "Formatos")', () {
    test('a wait parses and goes back to exactly its format', () {
      final wait = WaitRequest.tryParse(wire({'transfer': transferId}))!;

      expect(wait.transfer, transferId);
      expect(wait.toJson(), {'transfer': transferId});
    });

    test('a wait with a key too many, a bad id or no id gives null', () {
      for (final value in <Object?>[
        {'transfer': transferId, 'extra': 1},
        {'transfer': transferId.toUpperCase()},
        {'transfer': transferId.substring(1)},
        {'transfer': 7},
        <String, Object?>{},
        null,
        'x',
      ]) {
        expect(WaitRequest.tryParse(wire(value)), isNull, reason: '$value');
      }
    });

    test('a cancel with each reason goes and comes back exactly', () {
      final wires = {
        CancelReason.cancelled: 'cancelled',
        CancelReason.unreadable: 'unreadable',
        CancelReason.noContact: 'no_contact',
      };
      expect(wires.keys.toSet(), CancelReason.values.toSet());

      for (final MapEntry(key: reason, value: text) in wires.entries) {
        final json = CancelRequest(
          transfer: transferId,
          reason: reason,
        ).toJson();
        expect(json, {'transfer': transferId, 'reason': text});
        final back = CancelRequest.tryParse(wire(json))!;
        expect(back.reason, reason);
        expect(back.transfer, transferId);
      }
    });

    test('a cancel with an unknown reason, a key too many or a bad id gives '
        'null', () {
      for (final value in <Object?>[
        {'transfer': transferId, 'reason': 'noContact'},
        {'transfer': transferId, 'reason': 'declined'},
        {'transfer': transferId, 'reason': 3},
        {'transfer': transferId},
        {'transfer': transferId, 'reason': 'cancelled', 'extra': true},
        {'transfer': transferId.toUpperCase(), 'reason': 'cancelled'},
        null,
      ]) {
        expect(CancelRequest.tryParse(wire(value)), isNull, reason: '$value');
      }
    });
  });

  group('E9, RF-157: external states', () {
    for (final MapEntry(key: label, value: json) in tableRows().entries) {
      test('$label goes and comes back exactly', () {
        final state = RemoteState.tryParse(wire(json));

        expect(state, isNotNull);
        expect(state!.toJson(), json);
        expect(RemoteState.tryParse(wire(state.toJson())), state);
      });
    }

    test('the constructors give the rows of the table', () {
      expect(const RemoteState.waiting(picker: true).toJson(), {
        'state': 'waiting',
        'picker': true,
      });
      expect(const RemoteState.accepted(permit: acceptedValue).toJson(), {
        'state': 'accepted',
        'permit': acceptedValue,
      });
      expect(const RemoteState.uploading().toJson(), {'state': 'uploading'});
      expect(const RemoteState.saving().toJson(), {'state': 'saving'});
      expect(const RemoteState.saved(marked: false).toJson(), {
        'state': 'saved',
        'marked': false,
      });
      expect(const RemoteState.rejected(reason: 'no_space').toJson(), {
        'state': 'rejected',
        'reason': 'no_space',
      });
      expect(const RemoteState.cancelled().toJson(), {'state': 'cancelled'});
      expect(const RemoteState.failed(reason: 'disk_full').toJson(), {
        'state': 'failed',
        'reason': 'disk_full',
      });
    });

    test('an unknown reason gives null', () {
      for (final json in <Map<String, Object?>>[
        {'state': 'rejected', 'reason': 'busy'},
        {'state': 'rejected', 'reason': 'idle'},
        {'state': 'rejected', 'reason': ''},
        {'state': 'failed', 'reason': 'declined'},
        {'state': 'failed', 'reason': 'exploded'},
        {'state': 'failed', 'reason': 'Disk_Full'},
      ]) {
        expect(RemoteState.tryParse(wire(json)), isNull, reason: '$json');
      }
    });

    test('an unknown state, a missing or wrong field, or a key too many '
        'gives null', () {
      for (final json in <Object?>[
        {'state': 'paused'},
        {'state': 'WAITING', 'picker': false},
        {'state': 'waiting'},
        {'state': 'waiting', 'picker': 'true'},
        {'state': 'waiting', 'picker': false, 'extra': 1},
        {'state': 'accepted'},
        {'state': 'accepted', 'permit': acceptedValue.toUpperCase()},
        {'state': 'accepted', 'permit': acceptedValue.substring(1)},
        {'state': 'uploading', 'picker': true},
        {'state': 'saving', 'reason': 'x'},
        {'state': 'saved'},
        {'state': 'saved', 'marked': 1},
        {'state': 'rejected'},
        {'state': 'rejected', 'reason': 'declined', 'extra': null},
        {'state': 'cancelled', 'reason': 'cancelled'},
        {'state': 'failed'},
        {'state': 7},
        <String, Object?>{},
        null,
        'saved',
        <Object?>[],
      ]) {
        expect(RemoteState.tryParse(wire(json)), isNull, reason: '$json');
      }
    });

    test('equal states are equal and have the same hash code', () {
      expect(
        RemoteState.tryParse(wire({'state': 'saved', 'marked': true})),
        const RemoteState.saved(marked: true),
      );
      expect(
        const RemoteState.saved(marked: true).hashCode,
        const RemoteState.saved(marked: true).hashCode,
      );
      expect(
        const RemoteState.saved(marked: true),
        isNot(const RemoteState.saved(marked: false)),
      );
      expect(
        const RemoteState.waiting(picker: true),
        isNot(const RemoteState.waiting(picker: false)),
      );
    });

    test('outcomeOfRemote reads each final row of the table', () {
      expect(
        outcomeOfRemote(const RemoteState.saved(marked: true)),
        TransferOutcome.saved,
      );
      expect(
        outcomeOfRemote(const RemoteState.saved(marked: false)),
        TransferOutcome.savedWithoutMark,
      );
      for (final MapEntry(key: reason, value: outcome)
          in rejectedReasons.entries) {
        expect(
          outcomeOfRemote(RemoteState.rejected(reason: reason)),
          outcome,
          reason: reason,
        );
      }
      for (final MapEntry(key: reason, value: outcome)
          in failedReasons.entries) {
        expect(
          outcomeOfRemote(RemoteState.failed(reason: reason)),
          outcome,
          reason: reason,
        );
      }
      expect(
        outcomeOfRemote(const RemoteState.cancelled()),
        TransferOutcome.cancelledByPeer,
      );
    });

    test('outcomeOfRemote gives null for the states that are not final', () {
      for (final state in const [
        RemoteState.waiting(picker: false),
        RemoteState.waiting(picker: true),
        RemoteState.accepted(permit: acceptedValue),
        RemoteState.uploading(),
        RemoteState.saving(),
      ]) {
        expect(outcomeOfRemote(state), isNull, reason: '${state.toJson()}');
      }
    });

    test('remoteOf gives the row of the table for each outcome of the '
        'receiver', () {
      expect(
        remoteOf(TransferOutcome.saved),
        const RemoteState.saved(marked: true),
      );
      expect(
        remoteOf(TransferOutcome.savedWithoutMark),
        const RemoteState.saved(marked: false),
      );
      for (final MapEntry(key: reason, value: outcome)
          in rejectedReasons.entries) {
        expect(remoteOf(outcome), RemoteState.rejected(reason: reason));
      }
      for (final MapEntry(key: reason, value: outcome)
          in failedReasons.entries) {
        expect(remoteOf(outcome), RemoteState.failed(reason: reason));
      }
      for (final outcome in const [
        TransferOutcome.cancelledHere,
        TransferOutcome.cancelledByPeer,
        TransferOutcome.unpaired,
      ]) {
        expect(
          remoteOf(outcome),
          const RemoteState.cancelled(),
          reason: '$outcome',
        );
      }
    });

    test('remoteOf gives null for the outcomes that have no row in the '
        'table', () {
      final withoutRow = {
        for (final outcome in TransferOutcome.values)
          if (remoteOf(outcome) == null) outcome,
      };

      expect(withoutRow, {
        TransferOutcome.busy,
        TransferOutcome.invalidName,
        TransferOutcome.blockedType,
        TransferOutcome.incompatible,
        TransferOutcome.noContact,
        TransferOutcome.unconfirmed,
      });
    });

    test('every outcome with a row goes through the wire and comes back the '
        'same, except a cancellation, which the other side sees as by the '
        'peer', () {
      for (final outcome in TransferOutcome.values) {
        final state = remoteOf(outcome);
        if (state == null) continue;
        final back = outcomeOfRemote(
          RemoteState.tryParse(wire(state.toJson()))!,
        );
        expect(
          back,
          outcome.kind == TransferResultKind.cancelled
              ? TransferOutcome.cancelledByPeer
              : outcome,
          reason: '$outcome',
        );
      }
    });
  });

  group('offerOutcome (plan, "Mensajes")', () {
    TransferOutcome of(int status, [String? error]) =>
        offerOutcome(status, error == null ? const {} : {'error': error});

    test('409, 429 and 503 are busy', () {
      expect(of(409, 'busy'), TransferOutcome.busy);
      expect(of(429), TransferOutcome.busy);
      expect(of(503, 'busy'), TransferOutcome.busy);
    });

    test('403 with declined is declined, and any other 403 is no contact', () {
      expect(of(403, 'declined'), TransferOutcome.declined);
      expect(of(403, 'forbidden'), TransferOutcome.noContact);
      expect(of(403), TransferOutcome.noContact);
    });

    test('400 and 413 are incompatible', () {
      expect(of(400, 'incompatible'), TransferOutcome.incompatible);
      expect(of(413), TransferOutcome.incompatible);
    });

    test('422 with path_too_long is pathTooLong and with any other code is '
        'invalidName', () {
      expect(of(422, 'path_too_long'), TransferOutcome.pathTooLong);
      expect(of(422, 'invalid_name'), TransferOutcome.invalidName);
      expect(of(422), TransferOutcome.invalidName);
    });

    test('415 is blockedType and 507 is noSpace', () {
      expect(of(415, 'blocked_type'), TransferOutcome.blockedType);
      expect(of(507, 'no_space'), TransferOutcome.noSpace);
    });

    test('any other status is noContact', () {
      for (final status in [200, 202, 401, 404, 410, 500, 502, 0]) {
        expect(of(status, 'x'), TransferOutcome.noContact, reason: '$status');
      }
    });
  });
}

String _offerText(String size) =>
    '{"protocol":"1.0","transfer":"$transferId","name":"informe.pdf",'
    '"size":$size,"sha256":"$digest"}';
