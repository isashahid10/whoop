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
      'a live workout never runs a derive pass, even once the settle elapses',
      () async {
        s.setWorkoutActive(true);
        // Long enough that an unheld scheduler would have drained twice over.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(runs, 0, reason: 'derivation must stay parked for the session');
      },
    );
  });

  group('ScreenWake', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      ScreenWake.resetForTest();
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

    test('enable then release round-trips the flag', () async {
      expect(ScreenWake.isHeld, isFalse);
      await ScreenWake.enable();
      expect(ScreenWake.isHeld, isTrue);
      await ScreenWake.release();
      expect(ScreenWake.isHeld, isFalse);
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
