// hevy_store.dart — persist fetched Hevy workouts and drive incremental sync.
//
// Sits between [HevyClient] (transport) and the DB. Everything is keyed so a
// re-sync is idempotent: hevy_workout by id, hevy_set by
// (workout_id, exercise_idx, set_idx), both written with REPLACE. Re-importing
// the same workout overwrites rather than duplicating, which matters because an
// edited workout in Hevy keeps its id.

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/day_label.dart';
import '../data/db.dart';
import 'hevy_client.dart';

/// Outcome of a sync attempt. Distinguishes the states the UI must treat
/// differently — "nothing new" and "your sign-in died" look identical if both
/// just return 0, and the second must NOT be silent (see hevy_client.dart).
enum HevySyncOutcome { ok, notLinked, authExpired, failed }

@immutable
class HevySyncResult {
  final HevySyncOutcome outcome;
  final int workouts;
  final int sets;
  final String? message;

  const HevySyncResult(this.outcome,
      {this.workouts = 0, this.sets = 0, this.message});

  bool get isError =>
      outcome == HevySyncOutcome.authExpired || outcome == HevySyncOutcome.failed;
}

class HevyStore {
  final HevyClient client;
  HevyStore({HevyClient? client}) : client = client ?? HevyClient();

  /// Hevy's own monotonic `index` of the newest workout we already hold. The
  /// incremental high-water mark: the client stops paging once it sees it.
  static Future<int> lastSyncedIndex() async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery('SELECT MAX(idx) AS m FROM hevy_workout');
    return (rows.first['m'] as num?)?.toInt() ?? 0;
  }

  /// Fetch anything newer than the high-water mark and store it.
  ///
  /// [full] ignores the mark and re-pulls everything — for the first sync after
  /// linking, or a manual "re-import all".
  Future<HevySyncResult> sync({bool full = false}) async {
    if (!await client.isLinked) {
      return const HevySyncResult(HevySyncOutcome.notLinked,
          message: 'Not signed in to Hevy');
    }

    final List<HevyWorkout> workouts;
    try {
      workouts = await client.fetchWorkouts(
        sinceIndex: full ? 0 : await lastSyncedIndex(),
        // A full backfill may be years deep; a routine sync only needs the
        // newest page or two, so keep it cheap on battery and radio.
        maxPages: full ? 200 : 5,
      );
    } on HevyAuthExpired catch (e) {
      return HevySyncResult(HevySyncOutcome.authExpired, message: e.message);
    } on HevyError catch (e) {
      return HevySyncResult(HevySyncOutcome.failed, message: e.message);
    } catch (e) {
      return HevySyncResult(HevySyncOutcome.failed, message: '$e');
    }

    if (workouts.isEmpty) return const HevySyncResult(HevySyncOutcome.ok);

    final db = await LocalDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var setCount = 0;

    await db.transaction((txn) async {
      for (final w in workouts) {
        // Day label from the workout's START in local time — a 9pm session that
        // ends after midnight belongs to the day it began, and that is the day
        // whose recovery it affects.
        final day = dayLabelOf(w.start);

        await txn.insert(
          'hevy_workout',
          {
            'id': w.id,
            'idx': w.index,
            'day': day,
            'name': w.name,
            'description': w.description,
            'start_ts': w.start.millisecondsSinceEpoch ~/ 1000,
            'end_ts': w.end.millisecondsSinceEpoch ~/ 1000,
            'duration_s': w.duration.inSeconds,
            'total_volume_kg': w.totalVolumeKg,
            'set_count': w.setCount,
            'synced_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        // Mirror into `sessions` so the workout actually SHOWS UP.
        //
        // The workouts screen reads `sessions`; hevy_workout/hevy_set are the
        // coach's detailed store and are invisible to the UI. Without this the
        // import silently succeeds and the user sees an empty screen — which is
        // exactly what happened first time round.
        //
        // `source: 'hevy'` keeps these distinguishable from band-detected
        // sessions, and the id is prefixed so a Hevy id can never collide with
        // a band session id. strain/max_hr/calories stay NULL: the band owns
        // those, and inventing them here would be fabrication.
        await txn.insert(
          'sessions',
          {
            'id': 'hevy_${w.id}',
            'start_ts': w.start.millisecondsSinceEpoch ~/ 1000,
            'end_ts': w.end.millisecondsSinceEpoch ~/ 1000,
            'type': 'strength',
            'status': 'done',
            'duration_min': (w.duration.inSeconds / 60).round(),
            'source': 'hevy',
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        // Clear this workout's sets first: an edit in Hevy can REMOVE a set,
        // and a pure upsert would leave the deleted row orphaned forever,
        // silently inflating volume.
        await txn.delete('hevy_set',
            where: 'workout_id = ?', whereArgs: [w.id]);

        for (var ei = 0; ei < w.exercises.length; ei++) {
          final ex = w.exercises[ei];
          for (final s in ex.sets) {
            await txn.insert(
              'hevy_set',
              {
                'workout_id': w.id,
                'exercise_idx': ei,
                'set_idx': s.index,
                'day': day,
                'exercise_title': ex.title,
                'template_id': ex.templateId,
                'exercise_type': ex.exerciseType,
                'equipment': ex.equipment,
                'muscle_group': ex.muscleGroup,
                'superset_id': ex.supersetId,
                'indicator': s.indicator,
                'weight_kg': s.weightKg,
                'reps': s.reps,
                'rpe': s.rpe,
                'distance_m': s.distanceMeters,
                'duration_s': s.durationSeconds,
                'volume_kg': s.volumeKg,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            setCount++;
          }
        }
      }
    });

    debugPrint('[hevy] stored ${workouts.length} workouts, $setCount sets');
    return HevySyncResult(HevySyncOutcome.ok,
        workouts: workouts.length, sets: setCount);
  }

  /// Sign out: drop the tokens and every imported row. Deleting the data too
  /// is deliberate — leaving a stale copy of someone's training history behind
  /// after they unlink is not what "unlink" means.
  Future<void> unlink() async {
    await client.clear();
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      await txn.delete('hevy_set');
      await txn.delete('hevy_workout');
      // Also drop the mirrored rows, or unlinking would leave orphaned
      // workouts on the workouts screen with no source to refresh them.
      await txn.delete('sessions', where: "source = ?", whereArgs: ['hevy']);
    });
  }

  /// Newest stored session day, or null. Used by the staleness nudge.
  static Future<String?> lastWorkoutDay() async {
    final db = await LocalDb.instance;
    final rows = await db
        .rawQuery('SELECT MAX(day) AS d FROM hevy_workout');
    return rows.first['d'] as String?;
  }
}
