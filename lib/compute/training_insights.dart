// training_insights.dart — feed the bulk-quality and overreaching analyses.
//
// Orchestration only: every threshold, formula and citation lives in
// analytics' bulk_quality.dart / overreaching.dart, per the three-repo rule.
// This file finds the series and hands them over.
//
// The two share most of their inputs — the e1RM trend from the Hevy log and
// the nightly HRV/RHR series — so they are gathered once here rather than each
// re-querying the store.

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import 'strength_service.dart';

class TrainingInsights {
  final ana.BulkAssessment bulk;
  final ana.OverreachingSignal overreaching;

  const TrainingInsights({required this.bulk, required this.overreaching});

  static const TrainingInsights absent = TrainingInsights(
    bulk: ana.BulkAssessment.absent,
    overreaching: ana.OverreachingSignal.absent,
  );
}

class TrainingInsightsService {
  TrainingInsightsService._();

  /// Days of history to read.
  ///
  /// 90 covers a full training block plus the baseline either analysis needs,
  /// and is small enough to stay a couple of indexed reads.
  static const int windowDays = 90;

  static String _dayLabel(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// A metric's daily series over the window, as (dayNumber, value) pairs.
  ///
  /// dayNumber is days since epoch so downstream slopes are per REAL elapsed
  /// time — a fortnight with three weigh-ins and a fortnight with fourteen are
  /// not the same trend, and indexing by reading would treat them alike.
  static Future<List<(double, double)>> _series(String key, int days) async {
    try {
      final db = await LocalDb.instance;
      final cutoff = _dayLabel(DateTime.now().subtract(Duration(days: days)));
      final rows = await db.query(
        'metric_series',
        columns: ['date', 'value'],
        where: 'key = ? AND date >= ?',
        whereArgs: [key, cutoff],
        orderBy: 'date ASC',
      );
      final out = <(double, double)>[];
      for (final r in rows) {
        final d = DateTime.tryParse(r['date'] as String? ?? '');
        final v = (r['value'] as num?)?.toDouble();
        if (d == null || v == null) continue;
        out.add((d.millisecondsSinceEpoch / 86400000.0, v));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Nightly HRV + resting HR, oldest first, for the overreaching baseline.
  static Future<List<ana.TrainingDay>> _trainingDays(int days) async {
    try {
      final db = await LocalDb.instance;
      final cutoff = _dayLabel(DateTime.now().subtract(Duration(days: days)));
      // One pass over both keys, pivoted in Dart — two round trips for two
      // columns of the same table would be wasteful.
      final rows = await db.query(
        'metric_series',
        columns: ['date', 'key', 'value'],
        where: 'key IN (?, ?) AND date >= ?',
        whereArgs: ['rmssd', 'rhr', cutoff],
        orderBy: 'date ASC',
      );
      final byDay = <String, Map<String, double>>{};
      for (final r in rows) {
        final date = r['date'] as String?;
        final key = r['key'] as String?;
        final v = (r['value'] as num?)?.toDouble();
        if (date == null || key == null || v == null) continue;
        (byDay[date] ??= {})[key] = v;
      }
      final dates = byDay.keys.toList()..sort();
      return [
        for (final d in dates)
          ana.TrainingDay(
            date: d,
            rmssd: byDay[d]?['rmssd'],
            restingHr: byDay[d]?['rhr'],
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Mean daily energy intake over the window, or null when nothing is logged.
  static Future<double?> _meanCaloriesIn(int days) async {
    final s = await _series('hk_kcal_in', days);
    if (s.isEmpty) return null;
    return s.map((e) => e.$2).reduce((a, b) => a + b) / s.length;
  }

  /// Both analyses, from one pass over the store.
  static Future<TrainingInsights> load() async {
    try {
      // The e1RM trends both analyses lean on. Only lifts with a MEANINGFUL
      // trend contribute — including a flat two-session lift would drag the
      // median toward zero and read as stalled progress.
      final progress = await StrengthService.summary();
      final slopes = [
        for (final p in progress.progress)
          if (p.trendMeaningful) p.slopeKgPerWeek!,
      ];

      final weights = await _series('hk_weight_kg', windowDays);
      final calories = await _meanCaloriesIn(windowDays);
      final days = await _trainingDays(windowDays);

      // Median across lifts, not mean: one exercise added mid-block with a
      // steep beginner slope should not decide the verdict.
      double? medianSlope;
      if (slopes.isNotEmpty) {
        final sorted = [...slopes]..sort();
        final mid = sorted.length ~/ 2;
        medianSlope = sorted.length.isOdd
            ? sorted[mid]
            : (sorted[mid - 1] + sorted[mid]) / 2.0;
      }

      return TrainingInsights(
        bulk: ana.assessBulk(
          weights: weights,
          strengthSlopes: slopes,
          meanCaloriesIn: calories,
        ),
        overreaching: ana.assessOverreaching(
          days: days,
          strengthKgPerWeek: medianSlope,
        ),
      );
    } catch (_) {
      return TrainingInsights.absent;
    }
  }
}
