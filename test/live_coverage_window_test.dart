// live_coverage — regression coverage for the ZERO-WIDTH window bug.
//
// `live_coverage` rows record the period the live 100 Hz pedometer actually
// counted, so the derivation pass can exclude those minutes from the 1 Hz
// estimate (real count wins, nothing counted twice). The old writer took BOTH
// ends of that window from the band record timestamp carried on live frames —
// a value that does not advance during a live session — so real databases are
// full of rows claiming hundreds of steps over ZERO seconds. A zero-width
// window excludes ~one minute instead of the streamed period (so the rest gets
// double counted) and destroys the only alignment between real 100 Hz counts
// and 1 Hz minutes.
//
// Three layers are covered:
//   1. deriveLiveCoverageWindow — the pure policy that decides the window.
//   2. AppState — a full session whose recTs never advances must still persist
//      a window spanning the streamed period (this is the bug, end to end).
//   3. LocalDb.addLiveCoverage — the persistence guard, so an upstream
//      regression cannot silently write a degenerate row again.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/live_coverage_policy.dart';
import 'package:openstrap_edge/state/app_state.dart';

/// One 100 Hz frame of walking-shaped |a|(g): a ~2 Hz gait oscillation riding
/// the 1 g gravity baseline, which is what the AN-2554 counter expects.
List<double> _walkFrame(int frameIndex, int samples) => [
      for (var i = 0; i < samples; i++)
        1.0 +
            0.45 *
                math.sin(
                  2 * math.pi * 2.0 * ((frameIndex * samples + i) / 100.0),
                ),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_live_coverage_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── 1. the pure policy ─────────────────────────────────────────────────────
  group('deriveLiveCoverageWindow', () {
    const t0 = 1785000000; // band record timestamp (device epoch sec)

    test('a band recTs that never advances still yields the streamed period',
        () {
      // THE BUG: every live frame of the session carried the same recTs, so the
      // old writer stored start == end == t0.
      final w = deriveLiveCoverageWindow(
        steps: 1657,
        samples100Hz: 100 * 1800, // 30 min of 100 Hz samples
        bandStartTs: t0,
        bandEndTs: t0, // never advanced
        firstIngestMs: 1785000000000,
        lastIngestMs: 1785000000000 + 1800 * 1000,
      );
      expect(w, isNotNull);
      expect(w!.seconds, 1800);
      expect(w.startTs, t0);
    });

    test('the window is anchored in the BAND record-time base, not the phone '
        'clock', () {
      // Phone and band clocks deliberately disagree here: the window must be
      // placed on the band's timeline (what decoded_onehz.rec_ts uses) while
      // taking its DURATION from the phone-clock hull.
      final w = deriveLiveCoverageWindow(
        steps: 200,
        samples100Hz: 100 * 300,
        bandStartTs: t0,
        bandEndTs: t0,
        firstIngestMs: 1000000000000, // a completely different epoch
        lastIngestMs: 1000000000000 + 300 * 1000,
      );
      expect(w!.startTs, t0);
      expect(w.endTs, t0 + 300);
    });

    test('falls back to the phone clock only when the band never reported a '
        'record timestamp', () {
      final w = deriveLiveCoverageWindow(
        steps: 200,
        samples100Hz: 100 * 120,
        bandStartTs: null,
        bandEndTs: 0,
        firstIngestMs: t0 * 1000,
        lastIngestMs: (t0 + 120) * 1000,
      );
      expect(w!.startTs, t0);
      expect(w.seconds, 120);
    });

    test('a near-continuous stream claims the full wall hull (small dropouts '
        'stay inside the counted period)', () {
      // 570 s sampled inside a 600 s hull — 95 % duty.
      final w = deriveLiveCoverageWindow(
        steps: 700,
        samples100Hz: 100 * 570,
        bandStartTs: t0,
        bandEndTs: t0,
        firstIngestMs: t0 * 1000,
        lastIngestMs: (t0 + 600) * 1000,
      );
      expect(w!.seconds, 600);
    });

    test('a mostly-absent stream claims only the sampled duration, never the '
        'hull', () {
      // 60 s of samples spread over an hour: claiming the hull would delete an
      // hour of 1 Hz estimate for one minute of real counting.
      final w = deriveLiveCoverageWindow(
        steps: 46,
        samples100Hz: 100 * 60,
        bandStartTs: t0,
        bandEndTs: t0,
        firstIngestMs: t0 * 1000,
        lastIngestMs: (t0 + 3600) * 1000,
      );
      expect(w!.seconds, 60);
    });

    test('the sampled duration can never exceed the wall hull', () {
      // Duplicate/backlogged frames inflate the sample count past real time.
      final w = deriveLiveCoverageWindow(
        steps: 100,
        samples100Hz: 100 * 900,
        bandStartTs: t0,
        bandEndTs: t0,
        firstIngestMs: t0 * 1000,
        lastIngestMs: (t0 + 300) * 1000,
      );
      expect(w!.seconds, 300);
    });

    test('never returns a zero-width window when it claims steps', () {
      // No sample accounting and no phone timestamps at all: the only surviving
      // evidence is the step count, whose physiological floor still bounds the
      // window away from zero.
      final w = deriveLiveCoverageWindow(
        steps: 1657,
        samples100Hz: 0,
        bandStartTs: t0,
        bandEndTs: t0,
      );
      expect(w!.seconds, greaterThan(0));
      expect(w.seconds, minCoverageSecondsForSteps(1657));
    });

    test('a window is widened to the time its steps could physically span', () {
      // 400 steps cannot happen in 10 s at any human cadence.
      final w = deriveLiveCoverageWindow(
        steps: 400,
        samples100Hz: 100 * 10,
        bandStartTs: t0,
        bandEndTs: t0,
        firstIngestMs: t0 * 1000,
        lastIngestMs: (t0 + 10) * 1000,
      );
      expect(w!.seconds, minCoverageSecondsForSteps(400));
      expect(w.seconds, greaterThan(10));
    });

    test('no steps → no window, and no timeline → no window', () {
      expect(
        deriveLiveCoverageWindow(
          steps: 0,
          samples100Hz: 100 * 600,
          bandStartTs: t0,
          bandEndTs: t0,
          firstIngestMs: t0 * 1000,
          lastIngestMs: (t0 + 600) * 1000,
        ),
        isNull,
      );
      // Steps with nothing to place them on: a misplaced window would exclude
      // the wrong minutes, so nothing is recorded.
      expect(
        deriveLiveCoverageWindow(steps: 500, samples100Hz: 100 * 600),
        isNull,
      );
    });
  });

  // ── 2. the real AppState session (end-to-end regression) ───────────────────
  group('AppState live session', () {
    test('a session whose band recTs NEVER advances still persists a window '
        'covering the streamed period', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);

      // 4 minutes of 100 Hz walking, delivered 10 frames/s like the 0x33 IMU
      // stream, every single frame carrying the SAME record timestamp (the
      // behaviour observed on real hardware).
      const recTs = 1785600000; // 2026-08-02T… device epoch sec
      const frames = 4 * 60 * 10;
      const samplesPerFrame = 10;
      const startMs = recTs * 1000;
      for (var i = 0; i < frames; i++) {
        app.debugFeedLiveAccel(
          _walkFrame(i, samplesPerFrame),
          recTs: recTs,
          atMs: startMs + i * 100,
        );
      }
      expect(app.liveSteps, greaterThan(0), reason: 'walk must count steps');

      await app.debugFinalizeLivePedometer();

      final db = await LocalDb.instance;
      final rows = await db.query(
        'live_coverage',
        where: 'start_ts >= ? AND start_ts < ?',
        whereArgs: [recTs, recTs + 3600],
      );
      expect(rows, hasLength(1));
      final start = (rows.first['start_ts'] as num).toInt();
      final end = (rows.first['end_ts'] as num).toInt();
      // Pre-fix this was start == end == recTs — a 0 s window.
      expect(end - start, greaterThan(0));
      // The streamed period was ~240 s (the last frame's ingest is 100 ms shy).
      expect(end - start, closeTo(240, 2));
      expect(start, recTs, reason: 'window stays in the band record-time base');
      expect((rows.first['steps'] as num).toInt(), greaterThan(0));
    });

    test('a session that streamed nothing writes no window', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.debugFinalizeLivePedometer();
      final db = await LocalDb.instance;
      final rows = await db.query(
        'live_coverage',
        where: 'day = ?',
        whereArgs: ['1970-01-01'],
      );
      expect(rows, isEmpty);
    });
  });

  // ── 3. the persistence guard ───────────────────────────────────────────────
  group('LocalDb.addLiveCoverage', () {
    test('a zero-duration window that claims steps is never persisted as-is — '
        'and its steps are not lost', () async {
      const start = 1786000000;
      await LocalDb.addLiveCoverage(start, start, 1657, '2026-08-06');

      final db = await LocalDb.instance;
      final rows = await db.query(
        'live_coverage',
        where: 'day = ?',
        whereArgs: ['2026-08-06'],
      );
      expect(rows, hasLength(1), reason: 'the real 100 Hz count must survive');
      final end = (rows.first['end_ts'] as num).toInt();
      // Pre-fix the row went in verbatim with end_ts == start_ts.
      expect(end, greaterThan(start));
      expect(end - start, minCoverageSecondsForSteps(1657));
      expect((rows.first['steps'] as num).toInt(), 1657);
      expect(await LocalDb.liveStepsForDay('2026-08-06'), 1657);
    });

    test('an impossibly short window is widened to what its steps imply',
        () async {
      const start = 1786100000;
      await LocalDb.addLiveCoverage(start, start + 3, 600, '2026-08-07');
      final windows = await LocalDb.coverageWindowsOverlapping(
        start,
        start + 3600,
      );
      expect(windows, hasLength(1));
      expect(windows.first[1] - windows.first[0],
          minCoverageSecondsForSteps(600));
    });

    test('an inverted window is rejected, and a zero-step window is not stored',
        () async {
      const start = 1786200000;
      await LocalDb.addLiveCoverage(start, start - 60, 500, '2026-08-08');
      await LocalDb.addLiveCoverage(start, start + 600, 0, '2026-08-08');
      final db = await LocalDb.instance;
      final rows = await db.query(
        'live_coverage',
        where: 'day = ?',
        whereArgs: ['2026-08-08'],
      );
      expect(rows, isEmpty);
    });

    test('an honest window is stored exactly as measured', () async {
      const start = 1786300000;
      await LocalDb.addLiveCoverage(start, start + 1800, 2000, '2026-08-09');
      final windows = await LocalDb.coverageWindowsOverlapping(
        start,
        start + 3600,
      );
      expect(windows.first, [start, start + 1800]);
    });
  });

  // ── 4. historical degenerate rows stay readable ────────────────────────────
  group('legacy zero-width rows already on disk', () {
    test('are tolerated by the coverage readers (left alone, not migrated)',
        () async {
      // Written the way the old code did, bypassing the guard, to prove the
      // readers still behave on the rows real users already have.
      const start = 1786400000;
      final db = await LocalDb.instance;
      await db.insert('live_coverage', {
        'start_ts': start,
        'end_ts': start, // zero width
        'steps': 1230,
        'day': '2026-08-10',
      });
      expect(await LocalDb.liveStepsForDay('2026-08-10'), 1230);
      final windows = await LocalDb.coverageWindowsOverlapping(
        start,
        start + 3600,
      );
      expect(windows, hasLength(1));
      expect(windows.first, [start, start]);
    });
  });
}
