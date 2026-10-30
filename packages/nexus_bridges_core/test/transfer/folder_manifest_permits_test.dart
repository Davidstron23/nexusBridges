@TestOn('windows')
library;

import 'dart:io';

import 'package:nexus_bridges_core/src/pairing/pairing.dart';
import 'package:nexus_bridges_core/src/transport/transport.dart';
import 'package:test/test.dart';

import 'attacks_harness.dart';
import 'receiver_folder_support.dart' show FolderJob, folderJob, smallFile;

const Timeout long = Timeout(Duration(minutes: 2));

const String forbiddenText = '{"error":"forbidden"}';

void main() {
  group('E461, SEC-08: the permit of the manifest is bound to the session, '
      'the sender and the interface', () {
    Future<(TransferNode, TransferNode, TransferNode)> nodes() async {
      final [a, b, c] = await transferNodes(
        ['Laptop', 'Sobremesa', 'Tableta'],
        extraHosts: const ['127.0.0.4'],
      );
      await a.trust([(b, PeerRelation.mine)]);
      await c.trust([(b, PeerRelation.mine)]);
      await b.trust([(a, PeerRelation.mine), (c, PeerRelation.mine)]);
      await b.rememberReceiveFolder();
      b.interfaces = [
        (adapterId: wifiId, address: b.address),
        (adapterId: ethernetId, address: '127.0.0.4'),
      ];
      await startAll([a, b, c]);
      await meetAll([a, b, c]);
      await canSend(a, b);
      await canSend(c, b);
      return (a, b, c);
    }

    RawReply? answered(StreamPostResult result) => answeredOf(result);

    test('the right permit through another interface of B or from another '
        'paired device is 403 without spending it; the right sender and '
        'interface go on', () async {
      final (a, b, c) = await nodes();
      final other = InternetAddress('127.0.0.4');
      final FolderJob job = folderJob([('a.txt', smallFile)]);
      final forged = b.forgedAs(a);
      final offer = await forged.offerFolder(job.declared);
      expect(offer?.status, 202, reason: offer?.text);
      expect(offer?.state, 'manifest');
      final permit = offer!.json['permit'] as String;

      final viaOther = answered(
        await forged.manifest(
          transfer: job.transfer,
          permit: permit,
          bytes: job.encoded,
          at: other,
        ),
      );
      expect(viaOther?.status, 403);
      expect(viaOther?.text, forbiddenText);

      final fromC = answered(
        await b
            .forgedAs(c)
            .manifest(
              transfer: job.transfer,
              permit: permit,
              bytes: job.encoded,
            ),
      );
      expect(fromC?.status, 403);
      expect(fromC?.text, forbiddenText);
      expect(b.state.incoming, isNull);
      expect((await b.forgedAs(c).offerFolder(job.declared))?.status, 409);

      final good = answered(
        await forged.manifest(
          transfer: job.transfer,
          permit: permit,
          bytes: job.encoded,
        ),
      );
      expect(good?.status, 200, reason: good?.text);
      expect(good?.state, 'accepted');
      expect(treeOf(b.receiveDir), isEmpty);
    }, timeout: long);
  });
}
