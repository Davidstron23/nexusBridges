import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ApiPaths (plan, "Rutas")', () {
    test('every path has exactly the value of the plan', () {
      expect(ApiPaths.register, '/api/nexusbridges/v1/register');
      expect(ApiPaths.pairStart, '/api/nexusbridges/v1/pair/start');
      expect(ApiPaths.pairReveal, '/api/nexusbridges/v1/pair/reveal');
      expect(ApiPaths.pairWait, '/api/nexusbridges/v1/pair/wait');
      expect(ApiPaths.pairConfirm, '/api/nexusbridges/v1/pair/confirm');
      expect(ApiPaths.pairCancel, '/api/nexusbridges/v1/pair/cancel');
      expect(ApiPaths.pairStatus, '/api/nexusbridges/v1/pair/status');
      expect(ApiPaths.unpair, '/api/nexusbridges/v1/unpair');
    });

    test('every path hangs from the API prefix', () {
      for (final path in [
        ApiPaths.register,
        ApiPaths.pairStart,
        ApiPaths.pairReveal,
        ApiPaths.pairWait,
        ApiPaths.pairConfirm,
        ApiPaths.pairCancel,
        ApiPaths.pairStatus,
        ApiPaths.unpair,
      ]) {
        expect(path, startsWith('$apiPrefix/'), reason: path);
      }
    });

    test('the anonymous set is register and the six pair paths, and never '
        'unpair (SEC-03)', () {
      expect(ApiPaths.anonymous, {
        ApiPaths.register,
        ApiPaths.pairStart,
        ApiPaths.pairReveal,
        ApiPaths.pairWait,
        ApiPaths.pairConfirm,
        ApiPaths.pairCancel,
        ApiPaths.pairStatus,
      });
      expect(ApiPaths.anonymous, hasLength(7));
      expect(ApiPaths.anonymous, isNot(contains(ApiPaths.unpair)));
    });

    test('the anonymous set cannot be changed at run time', () {
      expect(
        () => ApiPaths.anonymous.add('$apiPrefix/files'),
        throwsUnsupportedError,
      );
      expect(
        () => ApiPaths.anonymous.remove(ApiPaths.register),
        throwsUnsupportedError,
      );
    });
  });

  group('Limits added by the spec 003 (plan, "protocol")', () {
    test('have exactly the values of the plan', () {
      expect(Limits.maxPairingBodyBytes, 8192);
      expect(Limits.maxRequestNameLength, 256);
      expect(Limits.pairingTimeout, const Duration(seconds: 60));
      expect(Limits.pairingMessageTimeout, const Duration(seconds: 10));
      expect(Limits.pairingPollHold, const Duration(seconds: 7));
      expect(Limits.pairingConfirmRetry, const Duration(seconds: 1));
      expect(Limits.pairingRecordTtl, const Duration(seconds: 30));
      expect(Limits.pairingRequestsPerOrigin, 5);
      expect(Limits.pairingRequestWindow, const Duration(minutes: 10));
      expect(Limits.pairingMismatchLimit, 3);
      expect(Limits.pairingBlock, const Duration(minutes: 10));
      expect(Limits.unpairNoticeTimeout, const Duration(seconds: 5));
      expect(Limits.peerCheckInterval, const Duration(minutes: 5));
      expect(Limits.peerCheckRetry, const Duration(seconds: 30));
      expect(Limits.pairSessionRequestsPerMinute, 120);
      expect(Limits.pairStatusPerMinute, 12);
      expect(Limits.unpairPerMinute, 12);
      expect(Limits.routeBlock, const Duration(minutes: 1));
    });

    test('the global cap and the signature budget have the values of the '
        'correction v6', () {
      expect(Limits.pairingGlobalFailures, 3);
      expect(Limits.pairingGlobalWindow, const Duration(minutes: 10));
      expect(Limits.signatureChecksPerSecond, 20);
      expect(
        Limits.pairingGlobalFailures,
        lessThanOrEqualTo(Limits.pairingMismatchLimit),
      );
    });

    test('the long poll hold fits inside the request deadline of the '
        'server', () {
      expect(Limits.pairingPollHold, lessThan(Limits.requestTimeout));
    });

    test('the pairing body cap is below the general body cap', () {
      expect(Limits.maxPairingBodyBytes, lessThan(Limits.maxBodyBytes));
    });

    test('the protocol version stays at 1.0 (D9)', () {
      expect(protocolVersion, '1.2');
    });
  });
}
