import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('transfer paths and headers (spec 004 plan, "Rutas")', () {
    test('every transfer path has exactly the value of the plan', () {
      expect(ApiPaths.transferOffer, '/api/nexusbridges/v1/transfer/offer');
      expect(ApiPaths.transferWait, '/api/nexusbridges/v1/transfer/wait');
      expect(ApiPaths.transferCancel, '/api/nexusbridges/v1/transfer/cancel');
      expect(ApiPaths.transferUpload, '/api/nexusbridges/v1/transfer/upload');
    });

    test('no transfer path is anonymous', () {
      for (final path in [
        ApiPaths.transferOffer,
        ApiPaths.transferWait,
        ApiPaths.transferCancel,
        ApiPaths.transferUpload,
      ]) {
        expect(ApiPaths.anonymous, isNot(contains(path)), reason: path);
        expect(path, startsWith('$apiPrefix/'), reason: path);
      }
    });

    test('the headers are in lower case and share the prefix', () {
      expect(TransferHeaders.prefix, 'x-nexusbridges-');
      expect(TransferHeaders.transfer, 'x-nexusbridges-transfer');
      expect(TransferHeaders.permit, 'x-nexusbridges-permit');
      for (final header in [TransferHeaders.transfer, TransferHeaders.permit]) {
        expect(header, startsWith(TransferHeaders.prefix));
        expect(header, header.toLowerCase());
      }
    });
  });

  group('Limits added by the spec 004 (plan, "protocol", v2)', () {
    test('sizes and counts have exactly the values of the plan', () {
      expect(Limits.maxTransferBodyBytes, 8192);
      expect(Limits.maxTransferSize, 9007199254740991);
      expect(Limits.maxFileNameUnits, 255);
      expect(Limits.transferSpaceMargin, 1073741824);
      expect(Limits.transferMaxRecordsPerPeer, 16);
      expect(Limits.transferMaxRecordsTotal, 256);
      expect(Limits.maxDiscardedUploadBytes, 65536);
      expect(Limits.maxFinalPathChars, 259);
      expect(Limits.maxExtensionRunes, 16);
      expect(Limits.transferOffersPerMinute, 30);
      expect(Limits.transferPollsPerMinute, 120);
      expect(Limits.transferCancelsPerMinute, 30);
      expect(Limits.transferUploadsPerMinute, 12);
      expect(Limits.maxRelaxedConnections, 2);
    });

    test('durations have exactly the values of the plan', () {
      expect(Limits.transferPollHold, const Duration(seconds: 7));
      expect(Limits.transferMessageTimeout, const Duration(seconds: 10));
      expect(Limits.transferDecisionTimeout, const Duration(seconds: 150));
      expect(Limits.transferPromptTimeout, const Duration(seconds: 60));
      expect(Limits.transferUploadStartTimeout, const Duration(seconds: 30));
      expect(Limits.transferIdleTimeout, const Duration(seconds: 30));
      expect(Limits.transferConfirmTimeout, const Duration(seconds: 30));
      expect(Limits.transferRecentRejection, const Duration(minutes: 1));
      expect(Limits.transferRecordTtl, const Duration(seconds: 30));
      expect(Limits.transferCancelTimeout, const Duration(seconds: 2));
      expect(Limits.transferCloseCancelTimeout, const Duration(seconds: 1));
      expect(
        Limits.transferFolderCheckTimeout,
        const Duration(milliseconds: 1500),
      );
      expect(Limits.transferFolderChoiceTimeout, const Duration(seconds: 10));
      expect(Limits.transferCleanupCheckTimeout, const Duration(seconds: 4));
      expect(Limits.transferCleanupWait, const Duration(milliseconds: 500));
      expect(Limits.transferPollGap, const Duration(seconds: 20));
      expect(Limits.transferConfirmCap, const Duration(minutes: 10));
      expect(Limits.transferDecisionCap, const Duration(minutes: 10));
      expect(Limits.transferCloseBudget, const Duration(seconds: 4));
      expect(
        Limits.transferProgressInterval,
        const Duration(milliseconds: 250),
      );
    });

    test('the transfer size is 2^53 - 1', () {
      expect(Limits.maxTransferSize, (1 << 53) - 1);
    });

    test('the long poll hold and the folder check fit inside the request '
        'deadline of the server', () {
      expect(Limits.transferPollHold, lessThan(Limits.requestTimeout));
      expect(
        Limits.transferFolderCheckTimeout,
        lessThan(Limits.requestTimeout),
      );
      expect(Limits.transferCleanupWait, lessThan(Limits.requestTimeout));
    });

    test('the transfer body cap is below the general body cap', () {
      expect(Limits.maxTransferBodyBytes, lessThan(Limits.maxBodyBytes));
    });

    test('the protocol version stays at 1.0', () {
      expect(protocolVersion, '1.0');
    });
  });

  group('monotonicClock (plan v2, point 2)', () {
    test('never goes back and moves forward with real time', () async {
      final first = monotonicClock();
      final second = monotonicClock();
      expect(second, greaterThanOrEqualTo(first));

      await Future<void>.delayed(const Duration(milliseconds: 30));

      final third = monotonicClock();
      expect(
        third - second,
        greaterThanOrEqualTo(const Duration(milliseconds: 20)),
      );
    });
  });
}
