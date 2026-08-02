// sleep_score_service.dart — compute the nightly sleep score from stored data.
//
// Orchestration only. The scoring curves, the weights and the abstention rules
// live in analytics' sleep_score.dart, per the three-repo rule; this file finds
// the inputs, decides what "need" means for this person tonight, and persists
// the result.
//
// SLEEP NEED is the one genuine judgement here. Kitamura's optimal-sleep-
// duration idea estimates it from the rebound plateau on UNCONSTRAINED nights
// (no alarm), which needs months of history. Until that exists we fall back to
// the population reference via the prior layer — so the score works from the
// first night and quietly becomes about this person as evidence accumulates,
// exactly as the rest of the stack does.

import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, Database;

import '../data/db.dart';

class SleepScoreService {
  SleepScoreService._();

  /// metric_series keys written by this service.
  static const String kScore = 'sleep_score';
  static const String kCoverage = 'sleep_score_coverage';

  /// Read one scalar for a day.
  static Future<double?> _metric(Database db, String date, String key) async {
    final rows = await db.query(
      'metric_series',
      columns: ['value'],
      where: 'date = ? AND key = ?',
      whereArgs: [date, key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['value'] as num?)?.toDouble();
  }

  /// The decoded rollup, so a caller needing several figures from it can read
  /// it once and pass it in rather than re-decoding per call.
  static Future<Map?> crossDayBundle() => _crossDay();

  /// The sleep need, in minutes, that [scoreFor] would use for this person.
  /// Exposed so the UI's need/debt gauge and the score's duration component are
  /// driven by the same number instead of two independent guesses.
  static Future<double?> needMinFor({
    Map<String, dynamic>? profile,
    Map? crossDay,
  }) async => _needMin(crossDay ?? await _crossDay(), profile);

  /// The cross-day rollup, which holds both the Phillips SRI and the Kitamura
  /// optimal-sleep-duration estimate. It is a rolling artifact over the recent
  /// window, not a per-night record, so both figures describe the period the
  /// night sits in rather than the night alone.
  static Future<Map?> _crossDay() async {
    try {
      final row = await LocalDb.baseline('crossday');
      final Object? raw = row?['payload_json'];
      if (raw is! String || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      return j is Map ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// Unwrap analytics' `Metric` envelope: `{value: …|'—', confidence, tier}`.
  /// An absent metric encodes its value as the string '—', so anything that is
  /// not a Map is an abstention.
  static Map? _metricValue(Map? bundle, String key) {
    final m = bundle?[key];
    if (m is! Map) return null;
    final v = m['value'];
    return v is Map ? v : null;
  }

  /// Sleep regularity index.
  ///
  /// SRI compares each epoch with the same epoch 24 h later, so it is
  /// structurally unavailable until several nights exist — absence here is
  /// expected early on, not a fault.
  static double? _sri(Map? bundle) =>
      (_metricValue(bundle, 'regularity')?['sri'] as num?)?.toDouble();

  /// Nightly sleep need in minutes, in descending order of how personal it is.
  ///
  /// 1. The Kitamura optimal sleep duration, but ONLY when the estimator saw an
  ///    unconstrained night. Without a free night it reports habitual sleep
  ///    instead, and habitual is what you DO sleep, not what you NEED — using
  ///    it would score every night against its own bad habit and hand out full
  ///    marks for chronic restriction.
  /// 2. Otherwise the blended personal/population duration, which at least
  ///    carries a published reference behind it.
  ///
  /// Null only when neither exists, in which case the duration component
  /// abstains rather than being scored against a guess.
  static Future<double?> _needMin(
    Map? bundle,
    Map<String, dynamic>? profile,
  ) async {
    final debt = _metricValue(bundle, 'sleep_debt');
    if (debt != null && debt['has_free_night'] == true) {
      final osdH = (debt['osd_hours'] as num?)?.toDouble();
      // Same physiological band the sleep coach clamps to: a noisy OSD from a
      // handful of nights can read implausibly low, and scoring against 5.6 h
      // of "need" would call a badly short night perfect.
      if (osdH != null && osdH.isFinite) return osdH.clamp(7.0, 9.5) * 60.0;
    }
    return (await _blendedTst(profile))?.center;
  }

  static Future<ana.Blended?> _blendedTst(Map<String, dynamic>? profile) async {
    // The prior layer already knows how to weigh personal history against the
    // cohort; reuse it rather than inventing a second rule for sleep.
    try {
      final db = await LocalDb.instance;
      final rows = await db.query(
        'baselines',
        where: 'key = ?',
        whereArgs: ['tst_min'],
        limit: 1,
      );
      ana.BaselineState? personal;
      if (rows.isNotEmpty) {
        final raw = rows.first['payload_json'];
        if (raw is String && raw.isNotEmpty) {
          final j = jsonDecode(raw);
          if (j is Map) {
            final mean = (j['mean'] as num?)?.toDouble();
            final n = (j['n'] as num?)?.toInt() ?? 0;
            final spread =
                (j['spread'] as num?)?.toDouble() ??
                (j['mad'] as num?)?.toDouble();
            if (mean != null && n > 0 && spread != null && spread > 0) {
              personal = ana.BaselineState(
                baseline: mean,
                spread: spread,
                nValid: n,
                nightsSinceUpdate: 0,
                status: n >= 14
                    ? ana.BaselineStatus.trusted
                    : ana.BaselineStatus.provisional,
              );
            }
          }
        }
      }
      return ana.PopulationPrior.blend(
        metricKey: 'tst_min',
        personal: personal,
        ageYears: (profile?['age'] as num?)?.round(),
        sex: profile?['sex'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Score one night. Returns the score object even when it abstains, so the
  /// UI can explain WHY there is no number rather than showing a blank.
  static Future<ana.SleepScore> scoreFor(
    String date, {
    Map<String, dynamic>? profile,
    Map? crossDay,
  }) async {
    try {
      final db = await LocalDb.instance;
      final bundle = crossDay ?? await _crossDay();

      final tst = await _metric(db, date, 'tst_min');
      final eff = await _metric(db, date, 'efficiency');
      final deep = await _metric(db, date, 'deep_min');
      final rem = await _metric(db, date, 'rem_min');

      // WASO is persisted directly since the pipeline change. Nights derived
      // before that have no value stored, so fall back to reconstructing it
      // from efficiency (which is defined as TST/TIB, making time-in-bed and
      // therefore wake-after-onset exact) rather than losing the component on
      // historical nights.
      var waso = await _metric(db, date, 'waso_min');
      if (waso == null && tst != null && eff != null && eff > 0 && eff <= 100) {
        final w = tst / (eff / 100.0) - tst;
        if (w.isFinite && w >= 0) waso = w;
      }

      final score = ana.SleepScorer.score(
        tstMin: tst,
        needMin: await _needMin(bundle, profile),
        efficiencyPct: eff,
        wasoMin: waso,
        sri: _sri(bundle),
        deepMin: deep,
        remMin: rem,
        confidence: await _metric(db, date, 'sleep_confidence') ?? 0,
      );

      // Persist only a real number. Writing a placeholder for an abstaining
      // night would put a value in the trend that never existed.
      if (score.score != null) {
        await db.insert('metric_series', {
          'date': date,
          'key': kScore,
          'value': score.score,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await db.insert('metric_series', {
          'date': date,
          'key': kCoverage,
          'value': score.coverage,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      return score;
    } catch (_) {
      return ana.SleepScore.absent;
    }
  }

  /// Recompute the trailing [days] nights. Cheap — a handful of indexed reads
  /// per night — and idempotent, so it is safe to run after every derive.
  static Future<int> backfill({
    int days = 60,
    Map<String, dynamic>? profile,
  }) async {
    var written = 0;
    // One read for the whole pass — the rollup is a single rolling artifact,
    // not per-night, so re-decoding it 60 times would be pure waste.
    final bundle = await _crossDay();
    final now = DateTime.now();
    for (var i = 0; i < days; i++) {
      final d = now.subtract(Duration(days: i));
      final date =
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      final s = await scoreFor(date, profile: profile, crossDay: bundle);
      if (s.score != null) written++;
    }
    return written;
  }
}
