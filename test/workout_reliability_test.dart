// Regressions for the "app closed mid-ride" class of failure.
//
// The live-workout path had several independent ways to lose a run or ride:
// heavy derivation firing an isolate mid-session, the display sleeping, and
// (platform-side) the foreground-service location type being stripped by an
// unrelated restart. These cover the parts that are testable in pure Dart —
// the two platform-channel behaviours are asserted at the seam.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gps/screen_wake.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Wait until [condition] holds, or give up after [timeout].
///
/// Returns as soon as the condition is met, so the generous timeout costs
/// nothing on a fast machine — it only buys headroom on a loaded CI runner.
/// Deliberately does NOT assert; the caller asserts afterwards so the failure
/// message names the real expectation rather than "timed out".
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Releasing the gate re-arms the scheduler, which reads the durable
  // compute_jobs queue — so this needs a real (in-memory-ish) DB.
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_workout_reliability_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('DeriveScheduler — live-workout gate', () {
    late List<String> logs;
    late int runs;
    late DeriveScheduler s;

    setUp(() {
      logs = [];
      runs = 0;
      s = DeriveScheduler(
        run: ({required DeriveJobKind kind}) async => runs++,
        log: logs.add,
        onChanged: () {},
        lightSettle: const Duration(milliseconds: 10),
        heavySettle: const Duration(milliseconds: 10),
      );
    });

    tearDown(() => s.dispose());

    test('holding is idempotent — repeated starts log once', () {
      s.setWorkoutActive(true);
      s.setWorkoutActive(true);
      expect(
        logs.where((l) => l.contains('workout live')).length,
        1,
        reason: 'a re-entrant start must not re-log or re-arm',
      );
    });

    test('releasing after a hold logs the drain exactly once', () {
      s.setWorkoutActive(true);
      s.setWorkoutActive(false);
      s.setWorkoutActive(false);
      expect(logs.where((l) => l.contains('workout ended')).length, 1);
    });

    test('a release without a preceding hold is a no-op', () {
      s.setWorkoutActive(false);
      expect(logs, isEmpty);
    });

    test('the gate is visible in the snapshot', () {
      expect(s.snapshot()['workout_active'], isFalse);
      s.setWorkoutActive(true);
      expect(s.snapshot()['workout_active'], isTrue);
      s.setWorkoutActive(false);
      expect(s.snapshot()['workout_active'], isFalse);
    });

    test(
      'a queued job stays parked for the session, then runs on release',
      () async {
        // This MUST enqueue real work. An earlier version asserted runs == 0
        // without queueing anything, so it passed even with the gate deleted —
        // CodeRabbit caught it on the PR, and it was right.
        s.setWorkoutActive(true);
        s.markStoredData(); // enqueues a durable derive_light job

        // A fixed wait is correct HERE and only here: you cannot poll for
        // "this never happens". Comfortably past the 10 ms settle.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(runs, 0,
            reason: 'a queued job must not run while a workout is live');

        s.setWorkoutActive(false);
        // But the positive direction MUST poll. The drain does several DB
        // round-trips, and a fixed 120 ms sleep here passed locally and failed
        // on a slower CI runner — a flake I introduced in the previous commit.
        await _until(() => runs == 1);
        expect(runs, 1,
            reason: 'and it must drain once the session ends, not be dropped');
      },
    );
  });

  group('requeueComputeJob (the post-claim gate race)', () {
    // `_drain()` clears the gate, then awaits takeNextComputeJob(). A workout
    // starting inside that window leaves a job already marked `running` that
    // must be handed back rather than run — otherwise it sits claimed until
    // the next recoverComputeJobs().
    //
    // Deliberately tests the PRIMITIVE rather than simulating the interleaving.
    // Hitting that window means racing a real DB round-trip, which is a coin
    // flip dressed up as a test — the kind that passes locally and fails on a
    // loaded runner (this file already had one of those). What is worth
    // pinning is the guarantee the drain path depends on: a claimed job comes
    // back claimable, and being deferred does not burn an attempt.
    setUp(() async {
      // Leave no jobs behind from an earlier group.
      for (var i = 0; i < 8; i++) {
        final j = await LocalDb.takeNextComputeJob();
        if (j == null) break;
        await LocalDb.completeComputeJob(j['id'].toString());
      }
    });

    test('a claimed job returns to the queue and stays runnable', () async {
      await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');

      final claimed = await LocalDb.takeNextComputeJob();
      expect(claimed, isNotNull, reason: 'the job should be claimable');
      expect(claimed!['state'], 'running');
      final id = claimed['id'].toString();
      // NOTE: takeNextComputeJob returns the row as it was BEFORE its own
      // update, so `attempts` here is the pre-increment value. That makes the
      // comparison below the meaningful one: if the requeue failed to undo the
      // increment, the second claim would report a higher number than the
      // first.
      final attemptsAtFirstClaim = (claimed['attempts'] as num).toInt();

      // While claimed, nothing else can take it.
      expect(await LocalDb.takeNextComputeJob(), isNull,
          reason: 'a running job must not be handed out twice');

      await LocalDb.requeueComputeJob(id);

      final again = await LocalDb.takeNextComputeJob();
      expect(again, isNotNull,
          reason: 'a requeued job must be claimable again, not stranded');
      expect(again!['id'].toString(), id);
      expect(
        (again['attempts'] as num).toInt(),
        attemptsAtFirstClaim,
        reason: 'the requeue undid the increment, so the second claim starts '
            'from the same count as the first — a deferral is not a retry',
      );

      await LocalDb.completeComputeJob(id);
      expect(await LocalDb.takeNextComputeJob(), isNull);
    });

    test('requeueing an unknown id is harmless', () async {
      await LocalDb.requeueComputeJob('no-such-job');
      expect(await LocalDb.takeNextComputeJob(), isNull);
    });
  });

  group('ScreenWake', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      ScreenWake.resetForTest();
      // Platform.isAndroid/isIOS are BOTH false on the host VM, so without this
      // the dispatch short-circuits and these mocks are never reached — the
      // call-count and failure assertions below asserted nothing at all.
      ScreenWake.platformOverride = 'android';
      for (final ch in const [
        MethodChannel('openstrap/edge_tracking'),
        MethodChannel('openstrap/ios_config'),
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ch, (c) async {
          calls.add(c);
          return true;
        });
      }
    });

    test('enable then release round-trips the flag and hits the channel',
        () async {
      expect(ScreenWake.isHeld, isFalse);
      await ScreenWake.enable();
      expect(ScreenWake.isHeld, isTrue);
      expect(calls.single.method, 'keepAwake');
      expect((calls.single.arguments as Map)['on'], isTrue);
      await ScreenWake.release();
      expect(ScreenWake.isHeld, isFalse);
      expect((calls.last.arguments as Map)['on'], isFalse);
    });

    test('a platform that refuses does NOT latch, so a retry can succeed',
        () async {
      // Android answers false when no activity is attached. Latching the
      // requested value there left Dart believing the screen was held and
      // suppressed every later attempt.
      var refuse = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('openstrap/edge_tracking'),
        (c) async {
          calls.add(c);
          return !refuse;
        },
      );
      await ScreenWake.enable();
      expect(ScreenWake.isHeld, isFalse, reason: 'refusal must not latch');

      refuse = false;
      await ScreenWake.enable();
      expect(ScreenWake.isHeld, isTrue, reason: 'the retry must go through');
      expect(calls.length, 2);
    });

    test(
      'repeated enables do not spam the platform channel',
      () async {
        await ScreenWake.enable();
        final afterFirst = calls.length;
        await ScreenWake.enable();
        await ScreenWake.enable();
        expect(
          calls.length,
          afterFirst,
          reason: 'the 1 Hz session tick must not hit the channel every second',
        );
      },
    );

    test('a release fired while an enable is in flight still wins', () async {
      // `_on` only updates AFTER the platform await, so a release arriving
      // mid-enable used to read the stale `false`, decide it had nothing to do,
      // and return — then the in-flight enable latched true and the display
      // stayed held for the rest of the app's life. Both call sites in
      // AppState are fire-and-forget, so starting a workout and immediately
      // stopping it was enough to hit this.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('openstrap/edge_tracking'),
        (c) async {
          calls.add(c);
          // A real channel hop is not instantaneous; this is the window the
          // race lived in.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return true;
        },
      );

      await Future.wait([ScreenWake.enable(), ScreenWake.release()]);

      expect(ScreenWake.isHeld, isFalse,
          reason: 'the release must win — the screen cannot stay held');
      expect(
        [for (final c in calls) (c.arguments as Map)['on']],
        [true, false],
        reason: 'both transitions must reach the platform, in order',
      );
    });

    test('a release with nothing held is a no-op', () async {
      await ScreenWake.release();
      expect(calls, isEmpty);
    });

    test('a channel failure never throws into the workout path', () async {
      for (final ch in const [
        MethodChannel('openstrap/edge_tracking'),
        MethodChannel('openstrap/ios_config'),
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                ch, (c) async => throw PlatformException(code: 'boom'));
      }
      // Losing the wake flag degrades to "the screen sleeps" — it must never
      // propagate and interrupt a session.
      await expectLater(ScreenWake.enable(), completes);
      expect(ScreenWake.isHeld, isFalse,
          reason: 'a throwing channel must not latch either');
    });
  });

  group('live milestones', () {
    test(
      'a milestone fires once per SESSION, surviving screen re-entry',
      () {
        // The live screen is disposed and rebuilt every time the athlete
        // navigates away and back. The dedup set therefore lives on the
        // workout, not the screen — a screen-local set re-fired "5 MINUTES"
        // (banner + haptic + confetti) on every single return.
        final w = LiveWorkoutState(
          startTime: DateTime.now().subtract(const Duration(minutes: 6)),
          targetKcal: 300,
          workoutId: 'w1',
          type: 'run',
        );
        expect(w.firedMilestones.add('t5'), isTrue, reason: 'first announce');
        expect(w.firedMilestones.add('t5'), isFalse,
            reason: 're-entering the screen must not re-fire it');
        // A genuinely new milestone still gets through.
        expect(w.firedMilestones.add('t10'), isTrue);
      },
    );
  });

  group('pace is MOVING pace', () {
    final units = UnitsController.seed(UnitSystem.metric);

    test(
      'standing still after a short walk does not invent an absurd pace',
      () {
        // The reported bug: ~250 m covered, then a long stationary spell.
        // Averaging over ELAPSED time produced "40:32 /km" for someone who had
        // barely moved. Over MOVING time it is a real walking pace.
        const meters = 250.0;
        const movingSec = 200; // ~3.6 km/h — a slow walk
        const elapsedSec = 608; // most of it spent standing

        expect(
          units.pace(meters, elapsedSec),
          '40:32 /km',
          reason: 'this is the wrong number the old code showed',
        );
        expect(units.pace(meters, movingSec), '13:20 /km');
      },
    );

    test('no moving time yet reports "—" rather than dividing by elapsed', () {
      expect(units.pace(120.0, 0), '—');
    });
  });
}
