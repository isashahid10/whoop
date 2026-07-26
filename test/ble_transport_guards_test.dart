// Regression tests for the BLE transport guards around the offload:
// the process-wide single-owner band claim, link-down teardown, and inbound
// frame routing.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P1 — the band claim is released when no link ever came up', () {
    setUp(BleEngine.resetBandClaimForTest);
    tearDown(BleEngine.resetBandClaimForTest);

    test('a failed connect does not leave the claim held', () async {
      final logs = <String>[];
      final engine = BleEngine(
        onRecord: (sample, raw) async {},
        onState: (_) {},
        log: logs.add,
      );

      // flutter_blue_plus is unsupported in the test host, so this exercises
      // the real failure path (the throw happens in _doConnect, OUTSIDE the
      // block that used to guard it).
      final connected = await engine.connectToRemoteId('AA:BB:CC:DD:EE:FF');

      expect(connected, isFalse);
      // OLD BEHAVIOUR: _claimBand() ran BEFORE the link was up and only
      // disconnect() ever released it — which nothing calls on a failed
      // connect — so _bandOwner stayed pointing at an engine with no link for
      // the rest of the process lifetime.
      expect(BleEngine.bandClaimed, isFalse);
      expect(engine.holdsBandLink, isFalse);
    });

    test(
      'a background drainer is not starved by an earlier failed foreground '
      'connect',
      () async {
        final foreground = BleEngine(
          onRecord: (sample, raw) async {},
          onState: (_) {},
        );
        await foreground.connectToRemoteId('AA:BB:CC:DD:EE:FF');

        final drainerLogs = <String>[];
        final drainer = BleEngine(
          onRecord: (sample, raw) async {},
          onState: (_) {},
          log: drainerLogs.add,
          isBackgroundDrainer: true,
        );
        await drainer.connectToRemoteId('AA:BB:CC:DD:EE:FF');

        // OLD BEHAVIOUR: the stale foreground claim was non-null, so every
        // later background drain yielded — "strap not reachable this cycle",
        // forever.
        expect(
          drainerLogs.where((l) => l.contains('yielding')),
          isEmpty,
          reason: 'the drainer must actually attempt the band',
        );
      },
    );
  });

  group('P1 — BandClaimPolicy arbitration', () {
    test('an unclaimed band is claimed outright', () {
      expect(
        BandClaimPolicy.decide(
          incumbentPresent: false,
          incumbentLive: false,
          isBackgroundDrainer: true,
        ),
        BandClaimDecision.claim,
      );
    });

    test('a STALE claim (owner has no link) is taken, not yielded to', () {
      expect(
        BandClaimPolicy.decide(
          incumbentPresent: true,
          incumbentLive: false,
          isBackgroundDrainer: true,
        ),
        BandClaimDecision.claim,
      );
    });

    test('a background drainer yields to a LIVE owner', () {
      expect(
        BandClaimPolicy.decide(
          incumbentPresent: true,
          incumbentLive: true,
          isBackgroundDrainer: true,
        ),
        BandClaimDecision.yieldToOwner,
      );
    });

    test('a foreground engine preempts a LIVE owner', () {
      expect(
        BandClaimPolicy.decide(
          incumbentPresent: true,
          incumbentLive: true,
          isBackgroundDrainer: false,
        ),
        BandClaimDecision.preemptThenClaim,
      );
    });

    test('a foreground engine takes a stale claim without a preempt round-trip',
        () {
      expect(
        BandClaimPolicy.decide(
          incumbentPresent: true,
          incumbentLive: false,
          isBackgroundDrainer: false,
        ),
        BandClaimDecision.claim,
      );
    });
  });

  group('P1 — a dropped link tears its session down', () {
    test('the current session is torn down, not merely flagged', () {
      // OLD BEHAVIOUR: link-down only set connected=false and surfaced `idle`;
      // teardown happened solely on the NEXT connect()/disconnect(). When
      // BondRefusalGiveUp pauses auto-reconnect neither ever runs, so the dead
      // session's five timers kept firing and its four notification
      // subscriptions stayed registered — one more set leaked per drop.
      expect(
        LinkDownPolicy.evaluate(sessionIsCurrent: true),
        LinkDownAction.tearDownSession,
      );
    });

    test('a stale session\'s link-down is ignored entirely', () {
      expect(
        LinkDownPolicy.evaluate(sessionIsCurrent: false),
        LinkDownAction.ignoreStaleSession,
      );
    });
  });

  group('P2 — metadata always takes the serialized offload queue', () {
    test('metadata on the events characteristic is queued, not run inline', () {
      // OLD BEHAVIOUR: only role=='data' metadata reached the queue; metadata
      // reassembled on cmd_from/events was fired unawaited on the immediate
      // path — the ONE route that could run a HISTORY_END handler concurrently
      // with the queued drain, i.e. two handlers on the same DrainController.
      expect(
        FrameRoutePolicy.route(
          isMetadata: true,
          isHistorical: false,
          isDataRole: false,
        ),
        FrameRoute.serializedQueue,
      );
    });

    test('metadata on the data characteristic is queued', () {
      expect(
        FrameRoutePolicy.route(
          isMetadata: true,
          isHistorical: false,
          isDataRole: true,
        ),
        FrameRoute.serializedQueue,
      );
    });

    test('historical records on the data characteristic are queued', () {
      expect(
        FrameRoutePolicy.route(
          isMetadata: false,
          isHistorical: true,
          isDataRole: true,
        ),
        FrameRoute.serializedQueue,
      );
    });

    test('a historical frame off a non-data role keeps the immediate fallback',
        () {
      expect(
        FrameRoutePolicy.route(
          isMetadata: false,
          isHistorical: true,
          isDataRole: false,
        ),
        FrameRoute.immediate,
      );
    });

    test('live/command frames stay on the immediate path', () {
      expect(
        FrameRoutePolicy.route(
          isMetadata: false,
          isHistorical: false,
          isDataRole: true,
        ),
        FrameRoute.immediate,
      );
      expect(
        FrameRoutePolicy.route(
          isMetadata: false,
          isHistorical: false,
          isDataRole: false,
        ),
        FrameRoute.immediate,
      );
    });
  });
}
