// claude_connector.dart: push this phone's data to the Claude connector.
//
// Claude has no Apple Health connector, and it cannot reach a phone. So the
// app pushes a copy of what the coach can see to a small Cloudflare Worker
// (connector/ in this repo), and Claude reads it there over MCP from
// claude.ai, the desktop app and the mobile app. The phone stays the source of
// truth: the Worker only ever holds what was pushed, replaced day by day.
//
// WHAT GOES UP is the coach's view of the data, not raw sensor data: the
// metric_series scalars (band, hk_ Apple Health, wx_ weather, cal_ calendar
// counts), Hevy sets and workouts, band sessions, sleep stages, the app's own
// alerts and two baseline payloads. decoded_*/raw_* never leave the device,
// same line the coach's allow-list draws (AGENTS.md invariant 13).
//
// ONLY CHANGED DAYS ARE SENT. D1's free tier allows 100k row writes a day.
// Re-sending a 14-day window every half hour would blow through that by
// itself, so each (table, day) is hashed and a day goes up only when its hash
// differs from what was last accepted. In practice that is today's metrics
// plus whatever a sync or import just touched.
//
// Configured from .env at build time (CONNECTOR_URL, CONNECTOR_TOKEN), like the
// coach key. Unset means the whole feature is inert.
//
// Never throws: a dead network or a Worker outage degrades to a failed result
// the Profile card shows, never an exception into sync.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../data/day_label.dart';
import '../data/db.dart';

enum ConnectorOutcome { notConfigured, skipped, upToDate, pushed, failed }

class ConnectorResult {
  final ConnectorOutcome outcome;
  final int rows;
  final int days;
  final String? message;
  final DateTime at;

  ConnectorResult(this.outcome, {this.rows = 0, this.days = 0, this.message})
      : at = DateTime.now();

  bool get isError => outcome == ConnectorOutcome.failed;
}

/// One upload, plus the hashes to record once the Worker has accepted it.
@visibleForTesting
class PlannedPush {
  final Map<String, Object?> body;
  final Map<String, Map<String, String>> hashes;
  final int rows;
  final int days;
  PlannedPush(this.body, this.hashes, this.rows, this.days);
}

class ClaudeConnector {
  ClaudeConnector({http.Client? client, String? url, String? token})
      : _http = client ?? http.Client(),
        _url = (url ?? _envUrl).replaceAll(RegExp(r'/+$'), ''),
        _token = token ?? _envToken;

  static const String _envUrl = String.fromEnvironment('CONNECTOR_URL');
  static const String _envToken = String.fromEnvironment('CONNECTOR_TOKEN');

  final http.Client _http;
  final String _url;
  final String _token;

  bool get configured => _url.isNotEmpty && _token.isNotEmpty;

  /// Days re-checked on every push. Health import rewrites the last 7 days and
  /// derivation can revise recent nights, so a fortnight covers both.
  static const int windowDays = 14;

  /// Floor between automatic pushes. A manual push ignores it.
  static const Duration minInterval = Duration(minutes: 30);

  /// Rows per upload. Well under the Worker's own cap (5000), and small enough
  /// that parsing it fits the free plan's per-request CPU budget.
  static const int maxRowsPerPush = 2000;
  static const int maxDaysPerTable = 300;

  static const String _kHashes = 'connector_day_hashes';
  static const String _kBaselineHash = 'connector_baseline_hash';

  /// Must match connector/src/schema.ts column for column. Every query takes
  /// one parameter, the earliest day to include, and returns the day first.
  /// Every column has a distinct name: rows are read back from a map, so two
  /// columns sharing a name would silently collapse into one.
  static const Map<String, String> tableQueries = {
    'metric': 'SELECT date, key, value FROM v_metric WHERE date >= ?',
    'lift_set': '''
      SELECT s.day, s.workout_id, w.name AS workout_name, s.exercise_idx, s.set_idx,
             s.exercise_title, s.muscle_group, s.equipment, s.exercise_type,
             s.indicator, s.weight_kg, s.reps, s.rpe, s.volume_kg,
             s.distance_m, s.duration_s
      FROM hevy_set s JOIN hevy_workout w ON w.id = s.workout_id
      WHERE s.day >= ?''',
    'lift_session': '''
      SELECT w.day, w.id, w.name, w.description, w.start_ts, w.end_ts,
             w.duration_s / 60.0 AS duration_min, w.total_volume_kg, w.set_count,
             (SELECT COUNT(DISTINCT exercise_title) FROM hevy_set
                WHERE workout_id = w.id) AS exercise_count,
             (SELECT GROUP_CONCAT(DISTINCT muscle_group) FROM hevy_set
                WHERE workout_id = w.id) AS muscle_groups
      FROM hevy_workout w WHERE w.day >= ?''',
    'workout': '''
      SELECT date, id, start_ts, end_ts, type, status, calories, strain,
             max_hr, duration_min, steps, hrr_bpm, source, zone_min_json
      FROM v_sessions WHERE date >= ?''',
    'sleep_stage':
        'SELECT date, start_ts, end_ts, stage FROM v_hypnogram WHERE date >= ?',
    'insight': '''
      SELECT date, id, kind, title, body, created_at
      FROM v_insights WHERE date >= ?''',
  };

  /// Baseline payloads worth Claude's time: the 28-day rolling means and the
  /// illness/anomaly watch. The others are internal inputs (one is ~190 KB).
  static const String _baselineQuery = '''
    SELECT key, payload_json, updated_at FROM baselines
    WHERE key IN ('rolling', 'crossday') ORDER BY key''';

  bool _running = false;
  DateTime? _lastAttempt;

  /// Push whatever changed. [force] skips the throttle (a manual tap);
  /// [everything] re-sends all history, for a fresh Worker or after a re-derive.
  Future<ConnectorResult> push({bool force = false, bool everything = false}) async {
    if (!configured) return ConnectorResult(ConnectorOutcome.notConfigured);
    if (_running) return ConnectorResult(ConnectorOutcome.skipped);
    final now = DateTime.now();
    if (!force &&
        !everything &&
        _lastAttempt != null &&
        now.difference(_lastAttempt!) < minInterval) {
      return ConnectorResult(ConnectorOutcome.skipped);
    }
    _running = true;
    _lastAttempt = now;
    try {
      return await _push(everything: everything);
    } catch (e) {
      debugPrint('[connector] push failed: $e');
      return ConnectorResult(ConnectorOutcome.failed, message: _short(e));
    } finally {
      // Cleared on every path, including the throw: a latch left set here would
      // silently stop every future push (AGENTS.md §4.3).
      _running = false;
    }
  }

  Future<ConnectorResult> _push({required bool everything}) async {
    final db = await LocalDb.instance;
    final windowFloor =
        dayLabelOf(DateTime.now().subtract(const Duration(days: windowDays)));
    final floor = everything ? '0000-01-01' : windowFloor;

    final rowsByTable = <String, List<List<Object?>>>{};
    for (final entry in tableQueries.entries) {
      try {
        final rows = await db.rawQuery(entry.value, [floor]);
        rowsByTable[entry.key] = [for (final r in rows) r.values.toList()];
      } catch (e) {
        // A view missing on an older schema costs only its own table.
        debugPrint('[connector] ${entry.key} query failed: $e');
      }
    }
    List<List<Object?>>? baseline;
    try {
      baseline = [
        for (final r in await db.rawQuery(_baselineQuery)) r.values.toList()
      ];
    } catch (_) {}

    final sent = everything ? <String, Map<String, String>>{} : await _loadHashes();
    final baselineHash = baseline == null ? null : _hash(baseline);
    final sendBaseline = baseline != null &&
        (everything || baselineHash != await LocalDb.getCursor(_kBaselineHash));

    final pushes = plan(
      rowsByTable: rowsByTable,
      sent: sent,
      floor: floor,
      baseline: sendBaseline ? baseline : null,
      appVersion: await _appVersion(),
    );
    if (pushes.isEmpty) return ConnectorResult(ConnectorOutcome.upToDate);

    var rows = 0, days = 0;
    for (final p in pushes) {
      await _post(p.body);
      // Record per chunk, so a failure halfway keeps what already landed and the
      // next push resumes rather than starting over.
      for (final t in p.hashes.entries) {
        final table = sent.putIfAbsent(t.key, () => {});
        for (final d in t.value.entries) {
          if (d.value.isEmpty) {
            table.remove(d.key);
          } else {
            table[d.key] = d.value;
          }
        }
      }
      await _saveHashes(sent);
      rows += p.rows;
      days += p.days;
    }
    if (sendBaseline) await LocalDb.setCursor(_kBaselineHash, baselineHash!);

    // Keep only the window: older days are never re-checked, so their hashes
    // would just grow the cursor forever.
    for (final table in sent.values) {
      table.removeWhere((day, _) => day.compareTo(windowFloor) < 0);
    }
    await _saveHashes(sent);
    return ConnectorResult(ConnectorOutcome.pushed, rows: rows, days: days);
  }

  /// Turn query results into uploads. Pure, so the change detection and
  /// chunking are testable without a database or a network.
  ///
  /// A day is sent when its hash differs from the last accepted one. A day that
  /// was sent before but now has no rows (a deleted Hevy workout) is sent EMPTY,
  /// which clears it on the Worker.
  @visibleForTesting
  static List<PlannedPush> plan({
    required Map<String, List<List<Object?>>> rowsByTable,
    required Map<String, Map<String, String>> sent,
    required String floor,
    List<List<Object?>>? baseline,
    String? appVersion,
  }) {
    final out = <PlannedPush>[];
    var tables = <String, ({List<String> days, List<List<Object?>> rows})>{};
    var hashes = <String, Map<String, String>>{};
    var rowCount = 0, dayCount = 0;

    void flush() {
      if (tables.isEmpty) return;
      out.add(PlannedPush(
        {
          'version': 1,
          'app_version': ?appVersion,
          'tables': [
            for (final e in tables.entries)
              {'table': e.key, 'days': e.value.days, 'rows': e.value.rows},
          ],
        },
        hashes,
        rowCount,
        dayCount,
      ));
      tables = {};
      hashes = {};
      rowCount = 0;
      dayCount = 0;
    }

    for (final entry in rowsByTable.entries) {
      final table = entry.key;
      final byDay = <String, List<List<Object?>>>{};
      for (final r in entry.value) {
        final day = r.first;
        if (day is! String) continue;
        byDay.putIfAbsent(day, () => []).add(r);
      }
      final previous = sent[table] ?? const <String, String>{};
      final changed = <String, String>{}; // day -> new hash ('' = cleared)
      for (final d in byDay.entries) {
        final h = _hash(d.value);
        if (previous[d.key] != h) changed[d.key] = h;
      }
      for (final day in previous.keys) {
        if (day.compareTo(floor) >= 0 && !byDay.containsKey(day)) changed[day] = '';
      }

      for (final day in changed.keys.toList()..sort()) {
        final dayRows = byDay[day] ?? const <List<Object?>>[];
        final slot = tables[table];
        if (rowCount > 0 &&
            (rowCount + dayRows.length > maxRowsPerPush ||
                (slot != null && slot.days.length >= maxDaysPerTable))) {
          flush();
        }
        final s = tables.putIfAbsent(table, () => (days: <String>[], rows: <List<Object?>>[]));
        s.days.add(day);
        s.rows.addAll(dayRows);
        hashes.putIfAbsent(table, () => {})[day] = changed[day]!;
        rowCount += dayRows.length;
        dayCount++;
      }
    }

    if (baseline != null) {
      if (rowCount + baseline.length > maxRowsPerPush) flush();
      tables['baseline'] = (days: <String>[], rows: baseline);
      rowCount += baseline.length;
    }
    flush();
    return out;
  }

  Future<void> _post(Map<String, Object?> body) async {
    final res = await _http
        .post(
          Uri.parse('$_url/ingest'),
          headers: {
            'Authorization': 'Bearer $_token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      final detail = res.body.length > 160 ? res.body.substring(0, 160) : res.body;
      throw Exception(res.statusCode == 401
          ? 'Connector rejected the token (401). Check CONNECTOR_TOKEN.'
          : 'Connector returned ${res.statusCode}: $detail');
    }
  }

  // ── bookkeeping ───────────────────────────────────────────────────────────

  static Future<Map<String, Map<String, String>>> _loadHashes() async {
    final raw = await LocalDb.getCursor(_kHashes);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry(
            k as String,
            (v as Map).map((d, h) => MapEntry(d as String, h as String)),
          ));
    } catch (_) {
      return {}; // unreadable: re-send the window, which is harmless
    }
  }

  static Future<void> _saveHashes(Map<String, Map<String, String>> h) =>
      LocalDb.setCursor(_kHashes, jsonEncode(h));

  /// Forget what was sent, so the next push re-sends the whole window.
  static Future<void> resetSent() async {
    await LocalDb.setCursor(_kHashes, '');
    await LocalDb.setCursor(_kBaselineHash, '');
  }

  static Future<String?> _appVersion() async {
    try {
      final p = await PackageInfo.fromPlatform();
      return '${p.version}+${p.buildNumber}';
    } catch (_) {
      return null;
    }
  }

  /// FNV-1a over the day's rows as JSON. Change detection only, not security:
  /// a collision would delay one day's update until its next change.
  static String _hash(List<List<Object?>> rows) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(jsonEncode(rows))) {
      h ^= b;
      h *= 0x100000001b3;
    }
    return h.toUnsigned(64).toRadixString(16);
  }

  static String _short(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 160 ? '${s.substring(0, 160)}...' : s;
  }
}
