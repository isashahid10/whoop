// Claude connector push: change detection, clearing, chunking, and failure.
//
// Runs against the REAL LocalDb over sqflite_ffi (same harness as
// hevy_schema_test.dart) with a fake Worker, so the SQL that reads the coach
// views is exercised for real, not mocked.
//
// What this pins:
//  1. Unchanged days are never re-sent. D1's free tier caps row writes per
//     day, and the push runs on every sync, so re-sending is not harmless.
//  2. A day that was sent but now has no rows is sent EMPTY, which is how a
//     deleted Hevy workout disappears on the Worker too.
//  3. A failed push reports failure and does not wedge the next one (the
//     in-flight latch is cleared in finally).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/integrations/claude_connector.dart';

const _dbName = 'claude_connector_test.db';

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

class _FakeWorker {
  final bodies = <Map<String, dynamic>>[];
  int status = 200;

  late final client = MockClient((req) async {
    expect(req.url.path, '/ingest');
    expect(req.headers['Authorization'], 'Bearer tok');
    if (status != 200) return http.Response('nope', status);
    bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
    return http.Response('{"ok":true}', 200);
  });

  /// Every (table, day) the Worker was told to replace, across all pushes.
  Set<String> get replaced => {
        for (final b in bodies)
          for (final t in (b['tables'] as List).cast<Map>())
            for (final d in (t['days'] as List)) '${t['table']}:$d',
      };

  List<List<dynamic>> rows(String table) => [
        for (final b in bodies)
          for (final t in (b['tables'] as List).cast<Map>())
            if (t['table'] == table) ...(t['rows'] as List).cast<List>(),
      ];
}

Future<void> _metric(String date, String key, double value) async {
  final db = await LocalDb.instance;
  await db.insert('metric_series', {'date': date, 'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);
}

void main() {
  final today = dayLabelOf(DateTime.now());
  final yesterday = dayLabelOf(DateTime.now().subtract(const Duration(days: 1)));
  final old = dayLabelOf(DateTime.now().subtract(const Duration(days: 60)));

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    PackageInfo.setMockInitialValues(
      appName: 'Whoop', packageName: 'x', version: '1.0.0', buildNumber: '7',
      buildSignature: '',
    );
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _dbPath(_dbName));
    LocalDb.dbName = _dbName;
    await ClaudeConnector.resetSent();
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _dbPath(_dbName));
  });

  test('not configured is inert and sends nothing', () async {
    final w = _FakeWorker();
    final c = ClaudeConnector(client: w.client, url: '', token: '');
    expect((await c.push(force: true)).outcome, ConnectorOutcome.notConfigured);
    expect(w.bodies, isEmpty);
  });

  test('first push sends the window, then nothing until a day changes', () async {
    await _metric(yesterday, 'rhr', 55);
    await _metric(today, 'rhr', 57);
    await _metric(today, 'hk_protein_g', 140);
    await _metric(old, 'rhr', 60); // outside the 14-day window

    final w = _FakeWorker();
    final c = ClaudeConnector(client: w.client, url: 'https://w.example/', token: 'tok');

    final first = await c.push(force: true);
    expect(first.outcome, ConnectorOutcome.pushed);
    expect(w.replaced, {'metric:$yesterday', 'metric:$today'});
    expect(w.rows('metric'), hasLength(3));
    expect(w.bodies.first['app_version'], '1.0.0+7');

    w.bodies.clear();
    final second = await c.push(force: true);
    expect(second.outcome, ConnectorOutcome.upToDate);
    expect(w.bodies, isEmpty);

    await _metric(today, 'hk_protein_g', 160);
    final third = await c.push(force: true);
    expect(third.outcome, ConnectorOutcome.pushed);
    expect(w.replaced, {'metric:$today'}, reason: 'yesterday did not change');
  });

  test('everything re-sends history outside the window', () async {
    await _metric(old, 'rhr', 60);
    await _metric(today, 'rhr', 57);
    final w = _FakeWorker();
    final c = ClaudeConnector(client: w.client, url: 'https://w.example', token: 'tok');
    await c.push(force: true, everything: true);
    expect(w.replaced, containsAll(['metric:$old', 'metric:$today']));
  });

  test('a day that lost its rows is sent empty, clearing it remotely', () async {
    final db = await LocalDb.instance;
    await db.insert('hevy_workout', {
      'id': 'w1', 'idx': 1, 'day': yesterday, 'name': 'Leg Day',
      'start_ts': 1, 'end_ts': 2, 'duration_s': 3600, 'total_volume_kg': 1000.0,
      'set_count': 1, 'synced_at': 0,
    });
    await db.insert('hevy_set', {
      'workout_id': 'w1', 'exercise_idx': 0, 'set_idx': 0, 'day': yesterday,
      'exercise_title': 'Squat (Barbell)', 'weight_kg': 100.0, 'reps': 5,
    });

    final w = _FakeWorker();
    final c = ClaudeConnector(client: w.client, url: 'https://w.example', token: 'tok');
    await c.push(force: true);
    expect(w.rows('lift_set').single[5], 'Squat (Barbell)');
    expect(w.rows('lift_session').single[2], 'Leg Day');

    await db.delete('hevy_set');
    await db.delete('hevy_workout');
    w.bodies.clear();
    await c.push(force: true);
    final tables = (w.bodies.single['tables'] as List).cast<Map>();
    final liftSet = tables.firstWhere((t) => t['table'] == 'lift_set');
    expect(liftSet['days'], [yesterday]);
    expect(liftSet['rows'], isEmpty);
  });

  test('a rejected push fails loudly and does not block the next one', () async {
    await _metric(today, 'rhr', 57);
    final w = _FakeWorker()..status = 401;
    final c = ClaudeConnector(client: w.client, url: 'https://w.example', token: 'tok');

    final r = await c.push(force: true);
    expect(r.outcome, ConnectorOutcome.failed);
    expect(r.message, contains('401'));

    w.status = 200;
    final retry = await c.push(force: true);
    expect(retry.outcome, ConnectorOutcome.pushed,
        reason: 'nothing was recorded as sent, and the latch was released');
  });

  test('automatic pushes are throttled, manual ones are not', () async {
    await _metric(today, 'rhr', 57);
    final w = _FakeWorker();
    final c = ClaudeConnector(client: w.client, url: 'https://w.example', token: 'tok');
    expect((await c.push()).outcome, ConnectorOutcome.pushed);
    await _metric(today, 'rhr', 58);
    expect((await c.push()).outcome, ConnectorOutcome.skipped);
    expect((await c.push(force: true)).outcome, ConnectorOutcome.pushed);
  });

  test('plan splits large pushes and keeps every row', () {
    final rows = [
      for (var d = 1; d <= 30; d++)
        for (var k = 0; k < 150; k++)
          ['2026-09-${d.toString().padLeft(2, '0')}', 'k$k', k.toDouble()],
    ];
    final pushes = ClaudeConnector.plan(
      rowsByTable: {'metric': rows},
      sent: const {},
      floor: '2026-09-01',
    );
    expect(pushes.length, greaterThan(1));
    for (final push in pushes) {
      expect(push.rows, lessThanOrEqualTo(ClaudeConnector.maxRowsPerPush));
    }
    expect(pushes.fold<int>(0, (n, p) => n + p.rows), rows.length);
  });
}
