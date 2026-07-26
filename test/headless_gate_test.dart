// HeadlessSyncGate: mutual exclusion across EVERY headless wake source — the
// three iOS ones (BLE-restore, BGProcessingTask, BGAppRefreshTask) and the
// Android post-boot wake — plus the skip-streak telemetry that makes repeated
// wake-source collisions observable instead of a single easy-to-miss
// debugPrint line.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/headless_boot.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';

void main() {
  setUp(() {
    HeadlessSyncGate.resetForTest();
    BandOwnership.resetForTest();
  });

  test('a solo run is never a skip and leaves no streak', () async {
    final result = await HeadlessSyncGate.tryRun<int>('owner_a', () async => 1);
    expect(result, 1);
    expect(HeadlessSyncGate.consecutiveSkipsFor('owner_a'), 0);
    expect(HeadlessSyncGate.totalSkips, 0);
  });

  test('a collision skips the second caller and returns null', () async {
    final gateHeld = Completer<void>();
    final releaseGate = Completer<void>();
    final firstRun = HeadlessSyncGate.tryRun<void>('owner_a', () async {
      gateHeld.complete();
      await releaseGate.future;
    });
    await gateHeld.future;

    final second = await HeadlessSyncGate.tryRun<int>('owner_b', () async => 2);
    expect(second, isNull);
    expect(HeadlessSyncGate.consecutiveSkipsFor('owner_b'), 1);
    expect(HeadlessSyncGate.totalSkips, 1);

    releaseGate.complete();
    await firstRun;
  });

  test('consecutive skips accumulate per-owner independently', () async {
    final gateHeld = Completer<void>();
    final releaseGate = Completer<void>();
    final firstRun = HeadlessSyncGate.tryRun<void>('owner_a', () async {
      gateHeld.complete();
      await releaseGate.future;
    });
    await gateHeld.future;

    await HeadlessSyncGate.tryRun<int>('owner_b', () async => 2); // skip #1
    await HeadlessSyncGate.tryRun<int>('owner_b', () async => 2); // skip #2
    await HeadlessSyncGate.tryRun<int>('owner_c', () async => 3); // owner_c skip #1

    expect(HeadlessSyncGate.consecutiveSkipsFor('owner_b'), 2);
    expect(HeadlessSyncGate.consecutiveSkipsFor('owner_c'), 1);
    expect(HeadlessSyncGate.totalSkips, 3);

    releaseGate.complete();
    await firstRun;
  });

  test('a successful run resets that owner\'s own streak, not others\'',
      () async {
    final gateHeld = Completer<void>();
    final releaseGate = Completer<void>();
    final firstRun = HeadlessSyncGate.tryRun<void>('owner_a', () async {
      gateHeld.complete();
      await releaseGate.future;
    });
    await gateHeld.future;
    await HeadlessSyncGate.tryRun<int>('owner_b', () async => 2); // skip
    await HeadlessSyncGate.tryRun<int>('owner_c', () async => 3); // skip
    releaseGate.complete();
    await firstRun;

    expect(HeadlessSyncGate.consecutiveSkipsFor('owner_b'), 1);
    expect(HeadlessSyncGate.consecutiveSkipsFor('owner_c'), 1);

    // owner_b finally gets to run — its OWN streak clears; owner_c's doesn't.
    await HeadlessSyncGate.tryRun<int>('owner_b', () async => 4);
    expect(HeadlessSyncGate.consecutiveSkipsFor('owner_b'), 0);
    expect(HeadlessSyncGate.consecutiveSkipsFor('owner_c'), 1);
  });

  test('busy reflects gate ownership across the run', () async {
    expect(HeadlessSyncGate.busy, isFalse);
    final gateHeld = Completer<void>();
    final releaseGate = Completer<void>();
    final run = HeadlessSyncGate.tryRun<void>('owner_a', () async {
      gateHeld.complete();
      await releaseGate.future;
    });
    await gateHeld.future;
    expect(HeadlessSyncGate.busy, isTrue);
    releaseGate.complete();
    await run;
    expect(HeadlessSyncGate.busy, isFalse);
  });

  group('P2 — the Android boot wake goes through the gate too', () {
    test('the gate is BUSY for the whole duration of a boot drain', () async {
      final lease = BandOwnership.tryAcquireHeadless()!;
      final started = Completer<void>();
      final finish = Completer<void>();

      final run = runBootSyncThroughGate(
        lease,
        runner: (l) async {
          started.complete();
          await finish.future;
          return true;
        },
      );

      await started.future;
      // OLD BEHAVIOUR: the boot path called runHeadlessSync(lease: lease)
      // directly and fire-and-forget, so `busy` read false for the entire
      // boot drain and any other wake source would have run concurrently.
      expect(HeadlessSyncGate.busy, isTrue);
      expect(
        await HeadlessSyncGate.tryRun<int>('ble_restore_wake', () async => 7),
        isNull,
        reason: 'another wake source must SKIP while the boot drain holds it',
      );

      finish.complete();
      expect(await run, isTrue);
      expect(HeadlessSyncGate.busy, isFalse);
    });

    test('a boot wake that loses the race skips AND releases its band lease',
        () async {
      final lease = BandOwnership.tryAcquireHeadless()!;
      expect(BandOwnership.owner, BandOwnerKind.headless);

      final finish = Completer<void>();
      final holder = HeadlessSyncGate.tryRun<void>('ios_bg_task', () async {
        await finish.future;
      });

      var ran = false;
      final result = await runBootSyncThroughGate(
        lease,
        runner: (l) async {
          ran = true;
          return true;
        },
      );

      expect(result, isNull);
      expect(ran, isFalse);
      // The lease was acquired before the gate was consulted; a skipped cycle
      // must hand it back or the band stays owned by a run that never happened.
      expect(BandOwnership.owner, isNull);
      expect(HeadlessSyncGate.consecutiveSkipsFor(kBootWakeGateOwner), 1);

      finish.complete();
      await holder;
    });
  });
}
