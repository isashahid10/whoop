// Edge-side strength wiring.
//
// The formulas are analytics' problem and are tested there. What this file
// defends is the mapping from `hevy_set` rows onto the analytics input - the
// place where a wrong column or a wrong warm-up rule silently changes every
// downstream number without anything failing.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/strength_service.dart';
import 'package:openstrap_edge/data/db.dart';

String _day(int daysAgo) {
  final d = DateTime.now().subtract(Duration(days: daysAgo));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

var _seq = 0;

Future<void> _putSet(
  String day,
  String exercise, {
  double? kg,
  int? reps,
  double? rpe,
  String? muscle,
  String indicator = 'normal',
}) async {
  final db = await LocalDb.instance;
  await db.insert('hevy_workout', {
    'id': 'w$_seq',
    'idx': _seq, // Hevy's own sync cursor; NOT NULL
    'day': day,
    'name': 'Session',
    'start_ts': 0,
    'end_ts': 0,
    'duration_s': 0,
    'total_volume_kg': 0,
    'set_count': 1,
    'synced_at': 0,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await db.insert('hevy_set', {
    'workout_id': 'w$_seq',
    'exercise_idx': 0,
    'set_idx': 0,
    'day': day,
    'exercise_title': exercise,
    'muscle_group': muscle,
    'indicator': indicator,
    'weight_kg': kg,
    'reps': reps,
    'rpe': rpe,
    'volume_kg': (kg != null && reps != null) ? kg * reps : null,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  _seq++;
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_strength_test.db';
  });

  setUp(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    _seq = 0;
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('an empty log is an empty summary, not zeroes', () async {
    expect(await StrengthService.hasData(), isFalse);
    final s = await StrengthService.summary();
    expect(s.workingSets, 0);
    expect(s.progress, isEmpty);
    expect(s.tonnage.hasBase, isFalse);
  });

  test('warm-ups are excluded but failure and dropset sets are NOT', () async {
    await _putSet(
      _day(1),
      'Bench',
      kg: 20,
      reps: 5,
      muscle: 'Chest',
      indicator: 'warmup',
    );
    await _putSet(_day(1), 'Bench', kg: 100, reps: 5, muscle: 'Chest');
    await _putSet(
      _day(1),
      'Bench',
      kg: 95,
      reps: 5,
      muscle: 'Chest',
      indicator: 'failure',
    );
    await _putSet(
      _day(1),
      'Bench',
      kg: 70,
      reps: 8,
      muscle: 'Chest',
      indicator: 'dropset',
    );

    final s = await StrengthService.summary();
    expect(
      s.workingSets,
      3,
      reason: 'a set taken to failure is the most working set there is',
    );
    // The warm-up must not become the best e1RM either.
    expect(s.progress.single.currentKg, greaterThan(100));
  });

  test('rpe is read through and raises the estimate', () async {
    await _putSet(_day(1), 'Squat', kg: 100, reps: 5, rpe: 8);
    final withRpe = (await StrengthService.summary()).progress.single.currentKg;

    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    _seq = 0;
    await _putSet(_day(1), 'Squat', kg: 100, reps: 5);
    final without = (await StrengthService.summary()).progress.single.currentKg;

    expect(
      withRpe!,
      greaterThan(without!),
      reason: 'reps-in-reserve must survive the DB round trip',
    );
  });

  test('volume is weekly over the window, not a raw count', () async {
    // 8 working sets spread across the 28-day window is 2 per week.
    for (var i = 0; i < 8; i++) {
      await _putSet(_day(i * 3), 'Row', kg: 60, reps: 8, muscle: 'Back');
    }
    final s = await StrengthService.summary();
    final back = s.muscleVolume.firstWhere((m) => m.muscle == 'Back');
    expect(back.setsPerWeek, closeTo(2.0, 1e-9));
  });

  test('progression uses a LONGER history than the volume window', () async {
    // Sessions 100 days back are outside the 28-day volume window but must
    // still count toward whether the lift is moving.
    await _putSet(_day(100), 'Deadlift', kg: 100, reps: 1);
    await _putSet(_day(70), 'Deadlift', kg: 120, reps: 1);
    await _putSet(_day(40), 'Deadlift', kg: 140, reps: 1);

    final s = await StrengthService.summary();
    expect(
      s.progress.single.sessions,
      3,
      reason: 'a 28-day window would have seen none of these',
    );
    expect(s.progress.single.slopeKgPerWeek!, greaterThan(0));
    // But they contribute nothing to recent volume.
    expect(s.workingSets, 0);
  });

  test('an unlabelled set is counted as unlabelled, never guessed into a '
      'muscle bucket', () async {
    await _putSet(_day(1), 'Bench Press', kg: 100, reps: 5); // no muscle
    final s = await StrengthService.summary();
    expect(s.muscleVolume, isEmpty);
    expect(s.unlabelledSets, 1);
  });

  test('personal records rank by best estimated max', () async {
    await _putSet(_day(5), 'Deadlift', kg: 180, reps: 1);
    await _putSet(_day(5), 'Squat', kg: 140, reps: 1);
    final prs = await StrengthService.personalRecords();
    expect(prs.map((e) => e.exercise), ['Deadlift', 'Squat']);
  });
}
