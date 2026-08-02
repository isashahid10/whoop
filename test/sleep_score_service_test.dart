// Edge-side sleep score wiring.
//
// The curves and weights are analytics' problem and are tested there. What this
// file defends is the part only edge can get wrong: WHICH number becomes "sleep
// need", and whether the view actually exposes the score.
//
// The need choice is the one with teeth. Scoring against habitual sleep would
// give a chronically sleep-restricted person full marks for staying restricted,
// because their habit IS the target. The whole point of the free-night gate is
// to refuse that.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/sleep_score_service.dart';
import 'package:openstrap_edge/data/db.dart';

/// A crossday bundle in the shape the pipeline actually writes: analytics'
/// `Metric` envelope, where an absent value encodes as the string '—'.
String _bundle({
  double? osdHours,
  bool hasFreeNight = false,
  double habitualHours = 6.0,
  double? sri,
}) {
  // jsonEncode, not string interpolation - interpolating a Dart Map yields
  // Map.toString() with unquoted keys, which is not JSON and silently sends the
  // service down its no-rollup fallback path instead of the one under test.
  return jsonEncode({
    'sleep_debt': {
      'value': {
        'osd_hours': ?osdHours,
        'habitual_hours': habitualHours,
        'has_free_night': hasFreeNight,
      },
      'confidence': 0.8,
      'tier': 'a',
      'inputs_used': 1,
    },
    'regularity': {
      'value': sri == null ? '—' : {'sri': sri},
      'confidence': 0.8,
      'tier': 'a',
      'inputs_used': 1,
    },
  });
}

Future<void> _putNight(
  String date, {
  double? tst,
  double? eff,
  double? waso,
  double? deep,
  double? rem,
}) async {
  final db = await LocalDb.instance;
  Future<void> put(String k, double? v) async {
    if (v == null) return;
    await db.insert('metric_series', {'date': date, 'key': k, 'value': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  await put('tst_min', tst);
  await put('efficiency', eff);
  await put('waso_min', waso);
  await put('deep_min', deep);
  await put('rem_min', rem);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_sleep_score_test.db';
  });

  // A fresh store per test: these assert on what IS and ISN'T written, so a
  // row surviving from a previous test would quietly invalidate the point.
  setUp(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('sleep need', () {
    test('uses the personal OSD when a free night justified it', () async {
      await _putNight('2026-07-20',
          tst: 450, eff: 92, waso: 15, deep: 90, rem: 100);
      await LocalDb.putBaseline(
          'crossday', _bundle(osdHours: 7.5, hasFreeNight: true, sri: 85));

      final s = await SleepScoreService.scoreFor('2026-07-20');
      final dur = s.components.firstWhere((c) => c.key == 'duration');
      expect(dur.measured, isTrue);
      // 450 min against a 450 min need is exactly on target.
      expect(dur.detail, contains('7.5 h needed'));
      expect(dur.score, 100);
    });

    test('REFUSES the OSD when no free night existed - habitual sleep is what '
        'you do, not what you need', () async {
      // 6 h habitual. If the score adopted that as "need", this 6 h night
      // would score a perfect duration and quietly bless the restriction.
      await _putNight('2026-07-20', tst: 360, eff: 92, waso: 15);
      await LocalDb.putBaseline('crossday',
          _bundle(osdHours: 6.0, hasFreeNight: false, habitualHours: 6.0));

      final s = await SleepScoreService.scoreFor('2026-07-20');
      final dur = s.components.firstWhere((c) => c.key == 'duration');
      expect(dur.score, lessThan(100),
          reason: '6 h scored against the population reference is short');
    });

    test('an implausibly low OSD is clamped, not trusted', () async {
      // A noisy OSD from few nights can read ~5 h. Scoring a 5 h night as
      // perfect would be the estimator's noise becoming the user's target.
      await _putNight('2026-07-20', tst: 300, eff: 92, waso: 15);
      await LocalDb.putBaseline(
          'crossday', _bundle(osdHours: 5.0, hasFreeNight: true));

      final s = await SleepScoreService.scoreFor('2026-07-20');
      final dur = s.components.firstWhere((c) => c.key == 'duration');
      expect(dur.detail, contains('7.0 h needed'));
      // Unclamped, a 5 h night against a 5 h "need" would score a perfect 100.
      expect(dur.score, lessThan(100));
    });

    test('an implausibly HIGH OSD is clamped too', () async {
      // The low bound coincides with the population reference (7 h), so only
      // the upper bound proves the clamp itself ran rather than the fallback.
      await _putNight('2026-07-20', tst: 480, eff: 92, waso: 15);
      await LocalDb.putBaseline(
          'crossday', _bundle(osdHours: 12.0, hasFreeNight: true));

      final s = await SleepScoreService.scoreFor('2026-07-20');
      final dur = s.components.firstWhere((c) => c.key == 'duration');
      expect(dur.detail, contains('9.5 h needed'));
    });

    test('falls back to the population reference with no rollup at all',
        () async {
      await _putNight('2026-07-20', tst: 450, eff: 92, waso: 15);
      final s = await SleepScoreService.scoreFor('2026-07-20');
      expect(s.score, isNotNull, reason: 'night one must still score');
      expect(s.components.firstWhere((c) => c.key == 'duration').measured,
          isTrue);
      // Regularity has nothing to stand on yet and must say so.
      final reg = s.components.firstWhere((c) => c.key == 'regularity');
      expect(reg.measured, isFalse);
      expect(reg.absentReason, isNotNull);
    });
  });

  group('inputs', () {
    test('prefers stored WASO, and reconstructs it for older nights', () async {
      await _putNight('2026-07-20', tst: 400, eff: 80, waso: 12);
      final stored = await SleepScoreService.scoreFor('2026-07-20');
      expect(stored.components.firstWhere((c) => c.key == 'continuity').detail,
          contains('12 min'));

      // Same night as derived before waso_min was persisted: 400 min at 80%
      // efficiency means 500 min in bed, so 100 min awake.
      await _putNight('2026-07-21', tst: 400, eff: 80);
      final derived = await SleepScoreService.scoreFor('2026-07-21');
      expect(derived.components.firstWhere((c) => c.key == 'continuity').detail,
          contains('100 min'));
    });

    test('an unmeasurable night writes NOTHING rather than a placeholder',
        () async {
      await _putNight('2026-07-20', eff: 90); // efficiency alone
      final s = await SleepScoreService.scoreFor('2026-07-20');
      expect(s.score, isNull);

      final db = await LocalDb.instance;
      final rows = await db.query('metric_series',
          where: 'date = ? AND key = ?',
          whereArgs: ['2026-07-20', SleepScoreService.kScore]);
      expect(rows, isEmpty,
          reason: 'a stored 0 would enter the trend as a real bad night');
    });
  });

  group('persistence', () {
    test('score and coverage reach v_daily', () async {
      await _putNight('2026-07-20',
          tst: 450, eff: 92, waso: 15, deep: 90, rem: 100);
      await LocalDb.putBaseline(
          'crossday', _bundle(osdHours: 8.0, hasFreeNight: true, sri: 85));

      final s = await SleepScoreService.scoreFor('2026-07-20');
      expect(s.score, isNotNull);

      final db = await LocalDb.instance;
      final rows = await db.rawQuery(
        'SELECT sleep_score, sleep_score_coverage, waso_min FROM v_daily '
        'WHERE date = ?',
        ['2026-07-20'],
      );
      expect(rows, hasLength(1));
      expect((rows.first['sleep_score'] as num).toDouble(),
          closeTo(s.score!, 1e-9));
      expect((rows.first['sleep_score_coverage'] as num).toDouble(), 1.0);
      expect((rows.first['waso_min'] as num).toDouble(), 15);
    });

    test('rescoring replaces rather than duplicating', () async {
      await _putNight('2026-07-20', tst: 450, eff: 92, waso: 15);
      await SleepScoreService.scoreFor('2026-07-20');
      await SleepScoreService.scoreFor('2026-07-20');

      final db = await LocalDb.instance;
      final rows = await db.query('metric_series',
          where: 'date = ? AND key = ?',
          whereArgs: ['2026-07-20', SleepScoreService.kScore]);
      expect(rows, hasLength(1));
    });
  });
}
