// strength_service.dart — feed the strength analysis from the logged sets.
//
// Orchestration only: every formula, band and citation lives in analytics'
// strength.dart, per the three-repo rule. This file reads `hevy_set`, maps it
// onto the analytics input type, and hands it over.
//
// It reads the TABLE rather than the `v_lifts` view because the view exists for
// the coach's read-only SQL surface and is shaped for that; going through it
// here would couple the app's own analysis to a contract that only needs to
// serve SQL text.

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';

class StrengthService {
  StrengthService._();

  /// Hevy's per-set `indicator`. Only 'warmup' is excluded from working
  /// volume — 'failure' and 'dropset' are working sets by any definition, and
  /// dropping them would under-count exactly the hardest ones.
  static bool _isWorking(Object? indicator) => indicator != 'warmup';

  /// Load every logged set in the trailing [windowDays], oldest first.
  static Future<List<ana.LiftSet>> _load(int windowDays) async {
    final db = await LocalDb.instance;
    final from = DateTime.now().subtract(Duration(days: windowDays));
    final cutoff =
        '${from.year.toString().padLeft(4, '0')}-'
        '${from.month.toString().padLeft(2, '0')}-'
        '${from.day.toString().padLeft(2, '0')}';

    final rows = await db.rawQuery(
      '''
      SELECT s.day, s.exercise_title, s.muscle_group, s.indicator,
             s.weight_kg, s.reps, s.rpe
      FROM hevy_set s
      WHERE s.day >= ?
      ORDER BY s.day ASC
      ''',
      [cutoff],
    );

    final out = <ana.LiftSet>[];
    for (final r in rows) {
      final day = r['day'];
      final title = r['exercise_title'];
      // A set with no day or no exercise cannot be grouped or trended, so it
      // is dropped rather than bucketed under a placeholder name.
      if (day is! String || title is! String || title.isEmpty) continue;
      final muscle = r['muscle_group'];
      out.add(
        ana.LiftSet(
          day: day,
          exercise: title,
          muscleGroup: muscle is String && muscle.isNotEmpty ? muscle : null,
          weightKg: (r['weight_kg'] as num?)?.toDouble(),
          reps: (r['reps'] as num?)?.toInt(),
          rpe: (r['rpe'] as num?)?.toDouble(),
          isWorking: _isWorking(r['indicator']),
        ),
      );
    }
    return out;
  }

  /// The full strength summary over the trailing [windowDays].
  ///
  /// Progression is deliberately computed over a LONGER history than the
  /// volume window: four weeks is the right period for "how much am I doing",
  /// but far too short to see whether a lift is actually moving.
  static Future<ana.StrengthSummary> summary({
    int windowDays = 28,
    int progressDays = 180,
  }) async {
    final recent = await _load(windowDays);
    final long = progressDays > windowDays ? await _load(progressDays) : recent;

    final volumeOnly = ana.strengthSummary(
      recent,
      today: DateTime.now(),
      windowDays: windowDays,
    );
    // Rebuild with the long-history progression, keeping the short-window
    // volume figures — mixing the two windows inside one call would make
    // "sets per week" meaningless.
    return ana.StrengthSummary(
      progress: ana.exerciseProgress(long),
      muscleVolume: volumeOnly.muscleVolume,
      unlabelledSets: volumeOnly.unlabelledSets,
      tonnage: volumeOnly.tonnage,
      workingSets: volumeOnly.workingSets,
      windowDays: windowDays,
    );
  }

  /// Best estimated 1RM per exercise, heaviest first.
  static Future<List<ana.ExerciseProgress>> personalRecords({
    int days = 365,
    int limit = 12,
  }) async => ana.personalRecords(await _load(days), limit: limit);

  /// Whether there is anything at all to analyse. The UI uses this to show an
  /// empty state instead of a page of zeroes and dashes.
  static Future<bool> hasData() async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery('SELECT 1 FROM hevy_set LIMIT 1');
    return rows.isNotEmpty;
  }
}
