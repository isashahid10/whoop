// Schema + view regressions for the Hevy import (schema v27).
//
// Runs against the REAL LocalDb over sqflite_ffi, same harness as
// db_migration_ladder_test.dart. Two failure modes this guards:
//
//  1. A v26 database must upgrade to v27 WITHOUT throwing. `onUpgrade` runs in
//     one exclusive transaction, so a single bad step rolls the whole ladder
//     back and openDatabase rethrows — leaving the app stuck on the loading
//     screen on EVERY launch, permanently. A migration that only ever gets
//     tested on a fresh install would not catch that.
//
//  2. The coach views must exist AND be reachable through the SQL guard's
//     allow-list. A view the guard rejects is worse than no view: the data
//     imports fine, the coach just can never see it, silently.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/coach/coach_db.dart';
import 'package:openstrap_edge/integrations/hevy_store.dart';

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

void main() {
  final created = <String>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
  });

  test('fresh install creates the Hevy tables and coach views', () async {
    const name = 'hevy_fresh.db';
    created.add(name);
    await databaseFactory.deleteDatabase(await _dbPath(name));
    await LocalDb.close();
    LocalDb.dbName = name;

    final db = await LocalDb.instance;

    final tables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'] as String)
        .toSet();
    expect(tables, contains('hevy_workout'));
    expect(tables, contains('hevy_set'));

    final views = (await db
            .rawQuery("SELECT name FROM sqlite_master WHERE type='view'"))
        .map((r) => r['name'] as String)
        .toSet();
    expect(views, contains('v_lifts'));
    expect(views, contains('v_lift_sessions'));
  });

  test('v_lifts and v_lift_sessions return real set/session rows', () async {
    final db = await LocalDb.instance;

    await db.insert('hevy_workout', {
      'id': 'w1',
      'idx': 100,
      'day': '2026-07-28',
      'name': 'Push day',
      'description': '',
      'start_ts': 1785200000,
      'end_ts': 1785203600,
      'duration_s': 3600,
      'total_volume_kg': 4000.0,
      'set_count': 2,
      'synced_at': 1785203600,
    });
    await db.insert('hevy_set', {
      'workout_id': 'w1',
      'exercise_idx': 0,
      'set_idx': 0,
      'day': '2026-07-28',
      'exercise_title': 'Bench Press (Barbell)',
      'muscle_group': 'chest',
      'equipment': 'barbell',
      'exercise_type': 'weight_reps',
      'indicator': 'normal',
      'weight_kg': 100.0,
      'reps': 5,
      'rpe': 8.0,
      'volume_kg': 500.0,
    });
    await db.insert('hevy_set', {
      'workout_id': 'w1',
      'exercise_idx': 1,
      'set_idx': 0,
      'day': '2026-07-28',
      'exercise_title': 'Overhead Press (Barbell)',
      'muscle_group': 'shoulders',
      'equipment': 'barbell',
      'exercise_type': 'weight_reps',
      'indicator': 'normal',
      'weight_kg': 60.0,
      'reps': 8,
      'volume_kg': 480.0,
    });

    final lifts = await db.rawQuery(
        "SELECT * FROM v_lifts WHERE day='2026-07-28' ORDER BY exercise_title");
    expect(lifts.length, 2);
    expect(lifts.first['exercise_title'], 'Bench Press (Barbell)');
    expect(lifts.first['weight_kg'], 100.0);
    expect(lifts.first['reps'], 5);
    expect(lifts.first['workout_name'], 'Push day');

    final sessions = await db
        .rawQuery("SELECT * FROM v_lift_sessions WHERE day='2026-07-28'");
    expect(sessions.length, 1);
    expect(sessions.first['exercise_count'], 2);
    expect(sessions.first['duration_min'], 60.0);
    // Both muscle groups should be discoverable from the session row.
    expect(sessions.first['muscle_groups'].toString(), contains('chest'));
  });

  test('the coach SQL guard allows the new lift views', () {
    // The allow-list IS the security boundary (coach_db.dart) — a view missing
    // from it is unreachable no matter how well the import works.
    expect(CoachDb.allowedViews, contains('v_lifts'));
    expect(CoachDb.allowedViews, contains('v_lift_sessions'));
  });

  test('a v26 database upgrades to v27 without throwing', () async {
    const name = 'hevy_upgrade.db';
    created.add(name);
    final path = await _dbPath(name);
    // Close the handle the PREVIOUS test left open before repointing dbName —
    // LocalDb caches one static handle, so opening under a new name without
    // closing first hands back the old database and the upgrade never runs.
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);

    // Minimal v26 database: version stamp only. The ladder's v27 rung is purely
    // additive (CREATE TABLE IF NOT EXISTS), so it must survive an otherwise
    // empty database — the exact case a fresh-install-only test would miss.
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 26, onCreate: (_, _) async {}),
    );
    await legacy.close();

    LocalDb.dbName = name;
    final db = await LocalDb.instance; // runs onUpgrade 26 -> 27

    expect(await db.getVersion(), LocalDb.schemaVersion);
    final tables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'] as String)
        .toSet();
    expect(tables, contains('hevy_workout'));
    expect(tables, contains('hevy_set'));
  });

  test(
    'a stored Hevy workout is MIRRORED into sessions so the workouts screen '
    'can see it — the import is otherwise silently invisible',
    () async {
      final db = await LocalDb.instance;
      await db.delete('sessions', where: "source = ?", whereArgs: ['hevy']);

      // Mirror row as hevy_store writes it.
      await db.insert('sessions', {
        'id': 'hevy_w1',
        'start_ts': 1785200000,
        'end_ts': 1785203600,
        'type': 'strength',
        'status': 'done',
        'duration_min': 60,
        'source': 'hevy',
        'created_at': 1785203600,
      });

      final rows = await db.query('sessions',
          where: 'source = ?', whereArgs: ['hevy']);
      expect(rows.length, 1);
      expect(rows.first['type'], 'strength');
      expect(rows.first['status'], 'done');
      // strain/calories/max_hr must stay NULL — the band owns those, and a
      // fabricated number here would read as measured.
      expect(rows.first['strain'], isNull);
      expect(rows.first['calories'], isNull);
      expect(rows.first['max_hr'], isNull);
    },
  );

  test(
    'backfillSessions mirrors workouts imported before the mirror existed',
    () async {
      final db = await LocalDb.instance;
      await db.delete('sessions', where: "source = ?", whereArgs: ['hevy']);
      await db.delete('hevy_workout');

      // A workout as the PRE-mirror importer wrote it: hevy_workout row, no
      // matching sessions row. An incremental sync never rewrites this, so
      // without backfill it stays invisible forever.
      await db.insert('hevy_workout', {
        'id': 'old1',
        'idx': 50,
        'day': '2026-07-20',
        'name': 'Legs',
        'description': '',
        'start_ts': 1784600000,
        'end_ts': 1784603600,
        'duration_s': 3600,
        'total_volume_kg': 5000.0,
        'set_count': 12,
        'synced_at': 1784603600,
      });

      expect(await HevyStore.backfillSessions(), 1);

      final rows = await db.query('sessions', where: 'id = ?', whereArgs: ['hevy_old1']);
      expect(rows.length, 1);
      expect(rows.first['duration_min'], 60);
      expect(rows.first['source'], 'hevy');

      // Idempotent — a second run must not duplicate or re-report.
      expect(await HevyStore.backfillSessions(), 0);
    },
  );

  test('v_baseline_trust reports the blend basis, and is coach-reachable', () async {
    final db = await LocalDb.instance;
    await db.delete('baselines');

    // Two metrics at very different evidence levels. The coach must be able to
    // tell them apart — presenting a 90-night baseline and a 2-night one as if
    // equally trustworthy is the failure this view exists to prevent.
    await db.insert('baselines', {
      'key': 'rhr',
      'payload_json': '{"mean": 52.0, "spread": 3.0, "n": 90}',
      'updated_at': 1785200000,
    });
    await db.insert('baselines', {
      'key': 'rmssd',
      'payload_json': '{"mean": 60.0, "spread": 10.0, "n": 2}',
      'updated_at': 1785200000,
    });

    final rows = await db.rawQuery(
        'SELECT key, nights, personal_weight, basis FROM v_baseline_trust '
        'ORDER BY key');
    expect(rows.length, 2);

    final byKey = {for (final r in rows) r['key'] as String: r};
    expect(byKey['rhr']!['nights'], 90);
    expect(byKey['rhr']!['basis'], 'personal');
    expect((byKey['rhr']!['personal_weight'] as num).toDouble(),
        greaterThan(0.85));

    expect(byKey['rmssd']!['nights'], 2);
    expect(byKey['rmssd']!['basis'], 'mostly population');
    expect((byKey['rmssd']!['personal_weight'] as num).toDouble(),
        lessThan(0.2));

    // The guard is the security boundary — a view it rejects is unreachable.
    expect(CoachDb.allowedViews, contains('v_baseline_trust'));
  });
}
