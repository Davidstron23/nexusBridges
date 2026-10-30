import 'dart:async';
import 'dart:convert';

import 'package:nexus_bridges_core/src/identity/identity.dart';
import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:nexus_bridges_core/src/transfer/transfer.dart';
import 'package:test/test.dart';

import '../server/api_server_harness.dart' show TlsClient, httpRequest;
import 'receiver_harness.dart';

void expectError(RawReply? reply, int status, String code) {
  expect(reply, isNotNull, reason: 'no reply, expected $status $code');
  expect(reply!.status, status, reason: reply.text);
  expect(reply.json, {'error': code});
}

void expectWaiting(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 202, reason: reply.text);
  expect(reply.json, {'state': 'waiting', 'picker': false});
}

String expectAccepted(RawReply? reply) {
  expect(reply, isNotNull);
  expect(reply!.status, 200, reason: reply.text);
  expect(reply.json.keys.toSet(), {'state', 'permit'});
  expect(reply.state, 'accepted');
  final permit = reply.json['permit'] as String;
  expect(permit, matches(hex32));
  return permit;
}

void main() {
  late DeviceIdentity receiver;
  late Peer laptop;
  late Peer desk;
  late Peer portatil;
  late Peer tablet;
  late DeviceIdentity stranger;

  setUpAll(() {
    receiver = DeviceIdentity.generate();
    laptop = Peer(DeviceIdentity.generate(), name: 'Laptop');
    desk = Peer(DeviceIdentity.generate(), name: 'Sobremesa');
    portatil = Peer(
      DeviceIdentity.generate(),
      name: 'PORTATIL',
      relation: PeerRelation.foreign,
    );
    tablet = Peer(
      DeviceIdentity.generate(),
      name: 'Tablet',
      relation: PeerRelation.foreign,
    );
    stranger = DeviceIdentity.generate();
  });

  Future<ReceiverStack> stack({
    bool remembered = true,
    Duration pollHold = const Duration(milliseconds: 200),
    void Function(TransferPlatform platform)? configure,
  }) => ReceiverStack.start(
    identity: receiver,
    peers: [laptop, desk, portatil, tablet],
    remembered: remembered,
    pollHold: pollHold,
    configure: configure,
  );

  group('routes (plan, Rutas y D24)', () {
    test(
      'offer, wait and cancel are paired JSON routes with their limits',
      () async {
        final s = await stack();
        final byPath = {for (final r in s.coordinator.routes) r.path: r};
        expect(byPath.keys.toSet(), {
          ApiPaths.transferOffer,
          ApiPaths.transferWait,
          ApiPaths.transferCancel,
        });
        for (final route in byPath.values) {
          expect(route.access, RouteAccess.paired);
          expect(route.maxBodyBytes, 8192);
          expect(route.limit, isNotNull);
          expect(route.limit!.maxPerWindow, 300);
          expect(route.limit!.window, const Duration(minutes: 1));
          expect(route.limit!.block, const Duration(minutes: 1));
        }
        for (final path in byPath.keys) {
          expect(ApiPaths.anonymous, isNot(contains(path)));
        }
      },
    );
  });

  group('[SEG] RF-216 unpaired sender', () {
    test('an unpaired identity never reaches a transfer handler', () async {
      final s = await stack();
      final id = newTransferId();
      final offer = await s.post(
        stranger,
        ApiPaths.transferOffer,
        s.offerBody(transfer: id),
      );
      final wait = await s.post(stranger, ApiPaths.transferWait, {
        'transfer': id,
      });
      final cancel = await s.post(stranger, ApiPaths.transferCancel, {
        'transfer': id,
        'reason': 'cancelled',
      });
      for (final reply in [offer, wait, cancel]) {
        if (reply != null) expectError(reply, 401, 'unauthorized');
      }
      final anonymous = await s.postWith(
        stranger.clientContext(),
        ApiPaths.transferOffer,
        s.offerBody(transfer: id),
      );
      if (anonymous != null) expectError(anonymous, 401, 'unauthorized');
      expect(s.handledTotal, 0);
      expect(s.incoming, isNull);
      expect(s.views, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.coordinator.busy, isFalse);
    });
  });

  group('E55 RF-143 busy', () {
    test('a second offer while the first shows the warning gets 409', () async {
      final s = await stack();
      final first = newTransferId();
      expectWaiting(await s.offer(portatil, transfer: first));
      expect(s.coordinator.busy, isTrue);
      final view = s.incoming;
      expect(view?.stage, IncomingStage.warning);
      final changes = s.views.length;

      expectError(await s.offer(laptop), 409, 'busy');
      expectError(await s.offer(tablet), 409, 'busy');
      expectError(await s.offer(portatil), 409, 'busy');

      expect(s.incoming, view);
      expect(s.views.length, changes);
      expect(s.coordinator.lastReceived, isNull);

      s.coordinator.answerWarning(s.sid, accept: false);
      expect(s.coordinator.busy, isFalse);
      expectWaiting(await s.offer(tablet));
    });

    test(
      'a second offer while the first is still being checked gets 409',
      () async {
        final gate = Completer<void>();
        final s = await stack(configure: (p) => p.volumeGate = gate);
        final pending = s.offer(laptop);
        await eventually(
          () => s.coordinator.busy,
          reason: 'first offer admitted',
        );
        expect(s.incoming, isNull);

        expectError(await s.offer(desk), 409, 'busy');
        expect(s.incoming, isNull);

        gate.complete();
        expectAccepted(await pending);
      },
    );

    test('a second offer while the first is accepted gets 409', () async {
      final s = await stack();
      expectAccepted(await s.offer(laptop));
      expect(s.coordinator.busy, isTrue);
      expectError(await s.offer(desk), 409, 'busy');
      s.coordinator.cancelIncoming(s.sid);
      expect(s.coordinator.busy, isFalse);
      expectAccepted(await s.offer(desk));
    });
  });

  group('E57 RF-144 malformed offer', () {
    test(
      'every malformed body gets 400 incompatible and shows nothing',
      () async {
        final s = await stack();
        Map<String, Object?> body() => s.offerBody(transfer: newTransferId());
        final cases = <String, Map<String, Object?>>{
          'extra key': {...body(), 'extra': 1},
          'missing name': body()..remove('name'),
          'missing size': body()..remove('size'),
          'missing sha256': body()..remove('sha256'),
          'missing transfer': body()..remove('transfer'),
          'missing protocol': body()..remove('protocol'),
          'size -1': {...body(), 'size': -1},
          'size 1.5': {...body(), 'size': 1.5},
          'size string': {...body(), 'size': '10'},
          'size 2^53': {...body(), 'size': 9007199254740992},
          'sha256 upper': {...body(), 'sha256': 'A' * 64},
          'sha256 63': {...body(), 'sha256': '0' * 63},
          'transfer 31': {...body(), 'transfer': 'a' * 31},
          'transfer upper': {...body(), 'transfer': 'A' * 32},
          'protocol 2.0': {...body(), 'protocol': '2.0'},
          'name not string': {...body(), 'name': 7},
          'name null': {...body(), 'name': null},
        };
        for (final entry in cases.entries) {
          final reply = await s.post(
            laptop.identity,
            ApiPaths.transferOffer,
            entry.value,
          );
          expect(reply?.status, 400, reason: entry.key);
          expect(reply?.json, {'error': 'incompatible'}, reason: entry.key);
        }
        for (final json in <Object?>[
          [1, 2],
          'offer',
          null,
        ]) {
          final reply = await s.post(
            laptop.identity,
            ApiPaths.transferOffer,
            json,
          );
          expect(reply?.status, 400, reason: '$json');
        }

        final broken = await s.sendRaw(
          laptop.identity,
          ApiPaths.transferOffer,
          utf8.encode('{"protocol":"1.0","transfer":'),
        );
        expect(broken?.status, 400);
        expect(broken?.json, {'error': 'bad_request'});

        final huge = await s.post(
          laptop.identity,
          ApiPaths.transferOffer,
          s.offerBody(transfer: newTransferId(), name: '${'a' * 9000}.txt'),
        );
        expect(huge?.status, 413);

        expect(s.views, isEmpty);
        expect(s.incoming, isNull);
        expect(s.coordinator.busy, isFalse);
        expect(s.coordinator.lastReceived, isNull);
        expectAccepted(await s.offer(laptop));
      },
    );
  });

  group('E58 RF-145 trap names', () {
    test('every name that is not valid gets 422 invalid_name', () async {
      final s = await stack();
      final names = <String>[
        '',
        'a' * 256,
        'a:b',
        r'..\x',
        'a/b',
        r'a\b',
        'a*b',
        'a?b',
        'a"b',
        'a<b',
        'a>b',
        'a|b',
        'a\u0000b.txt',
        'a\u0001b.txt',
        'a\u001Fb.txt',
        'a\u007Fb.txt',
        'a\u0085b.txt',
        'a\u009Fb.txt',
        'factura\u202Efdp.exe',
        'a\u202Ab.txt',
        'a\u2066b.txt',
        'a\u2069b.txt',
        'a\u200Bb.txt',
        'a\uFEFFb.txt',
        'a\u2060b.txt',
        'a\u2064b.txt',
        'a\u180Eb.txt',
        'a\u206Ab.txt',
        'a\u206Fb.txt',
        'a\uFFF9b.txt',
        'a\uFFFBb.txt',
        'a\u115Fb.txt',
        'a\u1160b.txt',
        'a\u3164b.txt',
        'a\uFFA0b.txt',
        'factura.pdf\u2028x.exe',
        'factura.pdf\u2029x.exe',
        'a\u00ADb.txt',
        'a\u{E0041}.txt',
        'a\u{E007F}.txt',
        '.',
        '..',
        'x.',
        'x ',
        'CON',
        'con.txt',
        'CON .txt',
        'aux.tar.gz',
        'NUL',
        'PRN.log',
        'COM\u00B9.txt',
        'LPT\u00B3',
        'CONIN\$',
        'conout\$.log',
        'LPT0',
        'com0.txt',
      ];
      for (final name in names) {
        final reply = await s.offer(laptop, name: name);
        expect(reply?.status, 422, reason: jsonEncode(name));
        expect(reply?.json, {
          'error': 'invalid_name',
        }, reason: jsonEncode(name));
      }

      final loneSurrogate = await s.sendRaw(
        laptop.identity,
        ApiPaths.transferOffer,
        utf8.encode(
          '{"protocol":"$protocolVersion","transfer":"${newTransferId()}",'
          '"name":"a\\ud800b.txt","size":1,"sha256":"$sampleDigest"}',
        ),
      );
      expect(loneSurrogate?.status, 422);
      expect(loneSurrogate?.json, {'error': 'invalid_name'});

      expect(s.views, isEmpty);
      expect(s.incoming, isNull);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.coordinator.busy, isFalse);
    });

    test('names the spec allows are not rejected as invalid', () async {
      final s = await stack();
      for (final name in [
        'informe.pdf',
        'familia \u{1F468}\u200D\u{1F469}\u200D\u{1F467}.jpg',
        'ne\u200Cmi.txt',
        '\u05E9\u05DC\u05D5\u05DD\u200F.txt',
        '\u2764\uFE0F.png',
        'CONSOLE.txt',
        'COM10.txt',
        'a\u061Cb.txt',
        '\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}.txt',
      ]) {
        final reply = await s.offer(laptop, name: name);
        expectAccepted(reply);
        s.coordinator.cancelIncoming(s.sid);
      }
    });

    test('a name of 255 units is valid and reaches the folder question when '
        'no folder is known yet', () async {
      final s = await stack(remembered: false);
      final name = '${'a' * 253}\u{1F600}';
      expect(name.length, 255);
      expectWaiting(await s.offer(laptop, name: name));
      await eventually(
        () => s.incoming?.stage == IncomingStage.folderQuestion,
        reason: 'folder question shown',
      );
      expect(s.incoming?.fileName, name);
      s.coordinator.cancelFolderQuestion(s.sid);
      expect(s.coordinator.busy, isFalse);
    });
  });

  group('E59 RF-214 blocked types', () {
    test(
      'every blocked type gets 415 blocked_type and shows nothing',
      () async {
        final s = await stack();
        for (final name in [
          'x.LNK',
          'a.url',
          'b.scf',
          'c.library-ms',
          'd.searchConnector-ms',
          'Desktop.ini',
          'desktop.ini',
          'x.PIF',
          'y.settingcontent-ms',
          'a.search-ms',
          'b.theme',
          'c.THEMEPACK',
          'd.deskthemepack',
          'informe.txt.{3050f4d8-98B5-11CF-BB82-00AA00BDCE0B}',
          'a.{3050F4D8-98B5-11CF-BB82-00AA00BDCE0B}.txt',
        ]) {
          final reply = await s.offer(laptop, name: name);
          expect(reply?.status, 415, reason: name);
          expect(reply?.json, {'error': 'blocked_type'}, reason: name);
        }
        expect(s.views, isEmpty);
        expect(s.incoming, isNull);
        expect(s.coordinator.lastReceived, isNull);
        expect(s.coordinator.busy, isFalse);
      },
    );
  });

  group('E60 RF-142 order of the silent checks', () {
    test('busy wins over a malformed body', () async {
      final s = await stack();
      expectWaiting(await s.offer(portatil));
      final reply = await s.post(laptop.identity, ApiPaths.transferOffer, {
        'protocol': protocolVersion,
      });
      expectError(reply, 409, 'busy');
    });

    test('busy wins over a recent rejection', () async {
      final s = await stack();
      expectWaiting(await s.offer(portatil));
      s.coordinator.answerWarning(s.sid, accept: false);
      expectWaiting(await s.offer(tablet));
      expectError(await s.offer(portatil, name: 'CON'), 409, 'busy');
    });

    test('a recent rejection wins over an invalid name', () async {
      final s = await stack();
      expectWaiting(await s.offer(portatil));
      s.coordinator.answerWarning(s.sid, accept: false);
      expectError(await s.offer(portatil, name: 'CON'), 403, 'declined');
      expectError(await s.offer(portatil, name: 'x.lnk'), 403, 'declined');
    });

    test('a malformed body wins over an invalid name', () async {
      final s = await stack();
      final body = s.offerBody(transfer: newTransferId(), name: 'CON')
        ..['size'] = -1;
      expectError(
        await s.post(laptop.identity, ApiPaths.transferOffer, body),
        400,
        'incompatible',
      );
    });

    test(
      'a cancelled id wins over an invalid name and a blocked type',
      () async {
        final s = await stack();
        final id = newTransferId();
        final cancel = await s.cancel(laptop, id);
        expect(cancel?.status, 200);
        expectError(
          await s.offer(laptop, transfer: id, name: 'CON'),
          410,
          'cancelled',
        );
        expectError(
          await s.offer(laptop, transfer: id, name: 'x.lnk'),
          410,
          'cancelled',
        );
      },
    );

    test('an invalid name wins over a blocked type', () async {
      final s = await stack();
      expectError(await s.offer(laptop, name: 'x .lnk '), 422, 'invalid_name');
    });
  });

  group('E63 RF-150 own device with a remembered folder', () {
    test('it is accepted with a permit and nothing is asked', () async {
      final s = await stack();
      final id = newTransferId();
      s.sampleViews();
      final permit = expectAccepted(await s.offer(laptop, transfer: id));
      final view = s.incoming!;
      expect(view.stage, IncomingStage.waitingData);
      expect(view.folder, isNull);
      expect(view.peerFingerprint, laptop.fingerprint);
      expect(view.peerName, 'Laptop');
      expect(view.fileName, 'informe.pdf');
      expect(view.size, 1536);
      await settle();
      expect(
        s.seen.where(
          (v) =>
              v.stage == IncomingStage.warning ||
              v.stage == IncomingStage.folderQuestion,
        ),
        isEmpty,
      );
      final wait = await s.wait(laptop, id);
      expect(wait?.status, 200);
      expect(wait?.json, {'state': 'accepted', 'permit': permit});
      expect(s.logs.where((l) => l.contains(permit)), isEmpty);
    });

    test(
      '[SEG] the permit is only handed to the fingerprint of the session',
      () async {
        final s = await stack();
        final id = newTransferId();
        final permit = expectAccepted(await s.offer(laptop, transfer: id));
        final other = await s.wait(desk, id);
        expectError(other, 404, 'not_found');
        final otherCancel = await s.cancel(desk, id);
        expect(otherCancel?.status, 200);
        expect(otherCancel?.text, isNot(contains(permit)));
        expect(s.incoming?.stage, IncomingStage.waitingData);
        final mine = await s.wait(laptop, id);
        expect(mine?.json, {'state': 'accepted', 'permit': permit});
      },
    );
  });

  group('E64 RF-151 RF-152 RF-232 warning for a foreign device', () {
    test(
      'the warning shows the saved name, fingerprint, file, size and program',
      () async {
        final s = await stack();
        final reply = await s.offer(
          portatil,
          name: 'factura.pdf.exe',
          size: 1536,
        );
        expectWaiting(reply);
        final view = s.incoming!;
        expect(view.stage, IncomingStage.warning);
        expect(view.peerName, 'PORTATIL');
        expect(view.peerFingerprint, portatil.fingerprint);
        expect(view.fileName, 'factura.pdf.exe');
        expect(view.size, 1536);
        expect(view.isProgram, isTrue);
        expect(view.withoutMark, isFalse);
        expect(view.folder, isNull);
        expect(s.coordinator.lastReceived, isNull);
      },
    );

    test('a file that is not a program is not flagged', () async {
      final s = await stack();
      expectWaiting(await s.offer(portatil, name: 'notas.txt', size: 0));
      expect(s.incoming?.isProgram, isFalse);
      expect(s.incoming?.size, 0);
    });

    test('a foreign device is never accepted without asking', () async {
      final s = await stack();
      for (var i = 0; i < 3; i++) {
        final id = newTransferId();
        expectWaiting(await s.offer(tablet, transfer: id));
        expect(s.incoming?.stage, IncomingStage.warning);
        final wait = await s.wait(tablet, id);
        expect(wait?.json, {'state': 'waiting', 'picker': false});
        await s.cancel(tablet, id);
        expectError(await s.offer(tablet), 403, 'declined');
        s.clock.advance(const Duration(seconds: 60));
      }
    });

    test(
      'RF-148 the warning says the file will be saved without the mark',
      () async {
        final s = await stack(configure: (p) => p.noMarkSupport = true);
        expectWaiting(await s.offer(portatil));
        expect(s.incoming?.stage, IncomingStage.warning);
        expect(s.incoming?.withoutMark, isTrue);
      },
    );

    test('RF-148 an own device is accepted without asking on a drive without the mark', () async {
      final s = await stack(configure: (p) => p.noMarkSupport = true);
      expectAccepted(await s.offer(laptop));
    });
  });

  group('E189 RF-232 program according to Windows', () {
    test('a type Windows calls dangerous is flagged as a program', () async {
      final s = await stack(
        configure: (p) => p.dangerous = (ext) async => ext == '.chm',
      );
      expectWaiting(await s.offer(portatil, name: 'x.chm'));
      expect(s.incoming?.isProgram, isTrue);
      expect(s.platform.dangerousAsked, ['.chm']);
    });

    test('a platform that throws falls back to the fixed list', () async {
      final s = await stack(
        configure: (p) => p.dangerous = (_) => Future.error(StateError('x')),
      );
      expectWaiting(await s.offer(portatil, name: 'x.chm'));
      expect(s.incoming?.isProgram, isFalse);
    });

    test(
      'a platform that never answers does not hold the warning past 1.5 s',
      () async {
        final never = Completer<bool>();
        final s = await stack(
          configure: (p) => p.dangerous = (_) => never.future,
        );
        final stopwatch = Stopwatch()..start();
        expectWaiting(await s.offer(portatil, name: 'x.chm'));
        expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1500)));
        expect(s.incoming?.stage, IncomingStage.warning);
        expect(s.incoming?.isProgram, isFalse);
      },
    );

    test('the fixed list wins when Windows says no', () async {
      final s = await stack(configure: (p) => p.dangerous = (_) async => false);
      expectWaiting(await s.offer(portatil, name: 'x.exe'));
      expect(s.incoming?.isProgram, isTrue);
    });
  });

  group('E82 RF-157 permits', () {
    test('1000 acceptances give 1000 different permits of 32 hex', () async {
      final s = await stack();
      final permits = <String>{};
      for (var i = 0; i < 1000; i++) {
        final permit = expectAccepted(await s.offer(laptop));
        permits.add(permit);
        s.coordinator.cancelIncoming(s.sid);
        s.clock.advance(const Duration(seconds: 1));
      }
      expect(permits, hasLength(1000));
      for (final permit in permits) {
        expect(permit, matches(hex32));
      }
      final joined = s.logs.join('\n');
      for (final permit in permits.take(50)) {
        expect(joined, isNot(contains(permit)));
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('E208 Q-3 silent rejections never flash busy', () {
    void expectNoChange(ReceiverStack s) {
      expect(s.views, isEmpty);
      expect(s.busyOnChange, isEmpty);
      expect(s.seen, isEmpty);
      expect(s.events, isEmpty);
      expect(s.coordinator.lastReceived, isNull);
      expect(s.coordinator.busy, isFalse);
    }

    test('a silent path_too_long emits no change', () async {
      final s = await stack();
      s.sampleViews();
      final name = '${'a' * 251}.txt';
      expect(name.length, 255);
      expectError(await s.offer(laptop, name: name), 422, 'path_too_long');
      expectError(await s.offer(portatil, name: name), 422, 'path_too_long');
      await settle();
      expectNoChange(s);
    });

    test('a 410 for a cancel while checking emits no change', () async {
      final gate = Completer<void>();
      final s = await stack(configure: (p) => p.volumeGate = gate);
      s.sampleViews();
      final id = newTransferId();
      final pending = s.offer(portatil, transfer: id);
      await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');
      expect(s.coordinator.busy, isTrue);
      expect((await s.cancel(portatil, id))?.status, 200);
      gate.complete();
      expectError(await pending, 410, 'cancelled');
      await settle();
      expectNoChange(s);
    });

    test(
      'an offer whose sender never gets the reply emits no change',
      () async {
        final gate = Completer<void>();
        final s = await stack(configure: (p) => p.volumeGate = gate);
        s.sampleViews();
        final client = await TlsClient.connect(
          s.port,
          serverFingerprint: receiver.fingerprint,
          context: laptop.identity.clientContext(presentCertificate: true),
        );
        client.write(
          httpRequest(
            'POST',
            ApiPaths.transferOffer,
            body: utf8.encode(
              jsonEncode(s.offerBody(transfer: newTransferId())),
            ),
            headers: const {'content-type': 'application/json; charset=utf-8'},
          ),
        );
        await eventually(() => s.platform.volumeCalls > 0, reason: 'checking');
        client.socket.destroy();
        await settle(const Duration(milliseconds: 200));
        gate.complete();
        await eventually(
          () => !s.coordinator.busy,
          reason: 'session dropped',
          limit: const Duration(seconds: 10),
        );
        await settle();
        expectNoChange(s);
      },
    );

    test('a step 1 rejection while another offer is open emits no change '
        'either', () async {
      final s = await stack();
      expectWaiting(await s.offer(portatil));
      final changes = s.busyOnChange.length;
      expectError(await s.offer(laptop), 409, 'busy');
      expectError(await s.offer(laptop, name: 'CON'), 409, 'busy');
      await settle();
      expect(s.busyOnChange.length, changes);
    });

    test('control: a normal offer emits when it is shown, with busy '
        'set', () async {
      final s = await stack();
      expectWaiting(await s.offer(portatil));
      await settle();
      expect(s.busyOnChange, isNotEmpty);
      expect(s.busyOnChange.first, isTrue);
      expect(s.views.first?.stage, IncomingStage.warning);
      s.coordinator.answerWarning(s.sid, accept: false);
      await settle();
      expect(s.busyOnChange.last, isFalse);
      expect(s.views.last, isNull);
    });
  });
}
