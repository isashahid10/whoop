// blended_baseline.dart — read a stored personal baseline and blend it with the
// published population reference (see analytics' population_prior.dart).
//
// Pure orchestration: the shrinkage maths and every cited norm live in the
// analytics package, per the three-repo rule. This file only fetches what is
// already persisted, hands it over, and caches the result.
//
// WHY IT EXISTS: `baselines` holds the personal EWMA state, which reports
// `calibrating` until enough nights exist — correct, but it leaves the app
// blank for one to two weeks. Blending gives a real, cited number from day one
// that converges to the individual as evidence accumulates.

import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';

class BlendedBaselines {
  BlendedBaselines._();

  /// The profile fields the priors can use. Both optional — a missing field
  /// simply means no adjustment, never a substituted default.
  static int? _age(Map<String, dynamic>? profile) =>
      (profile?['age'] as num?)?.round();
  static String? _sex(Map<String, dynamic>? profile) =>
      profile?['sex'] as String?;

  /// Rebuild the personal [ana.BaselineState] from the stored payload.
  ///
  /// Returns null when nothing is stored, which the blend treats as "no
  /// personal evidence" rather than as zero — the difference matters.
  static ana.BaselineState? _personalFrom(Map<String, dynamic>? row) {
    if (row == null) return null;
    try {
      final raw = row['payload_json'];
      if (raw is! String || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map) return null;

      final mean = (j['mean'] as num?)?.toDouble();
      final n = (j['n'] as num?)?.toInt() ?? 0;
      if (mean == null || n <= 0) return null;

      // The persisted payload records the centre and count; spread is stored
      // under a couple of historical names. Falling back to a fraction of the
      // mean would be inventing dispersion, so an absent spread means the
      // personal state cannot be reconstructed.
      final spread = (j['spread'] as num?)?.toDouble() ??
          (j['mad'] as num?)?.toDouble() ??
          (j['sd'] as num?)?.toDouble();
      if (spread == null || spread <= 0) return null;

      return ana.BaselineState(
        baseline: mean,
        spread: spread,
        nValid: n,
        nightsSinceUpdate: (j['nights_since_update'] as num?)?.toInt() ?? 0,
        status: n >= 14
            ? ana.BaselineStatus.trusted
            : ana.BaselineStatus.provisional,
      );
    } catch (_) {
      return null;
    }
  }

  /// Blended estimate for one metric, or null when neither a personal baseline
  /// nor a published reference exists.
  static Future<ana.Blended?> forMetric(
    String metricKey, {
    Map<String, dynamic>? profile,
  }) async {
    Map<String, dynamic>? row;
    try {
      final db = await LocalDb.instance;
      final rows = await db.query('baselines',
          where: 'key = ?', whereArgs: [metricKey], limit: 1);
      if (rows.isNotEmpty) row = rows.first;
    } catch (_) {
      // A missing or locked store means "no personal evidence", not a crash —
      // the population reference alone is still a useful answer.
    }

    return ana.PopulationPrior.blend(
      metricKey: metricKey,
      personal: _personalFrom(row),
      ageYears: _age(profile),
      sex: _sex(profile),
    );
  }

  /// Blended estimates for every metric that has a published reference.
  /// Metrics with neither a norm nor personal data are omitted entirely.
  static Future<Map<String, ana.Blended>> all({
    Map<String, dynamic>? profile,
  }) async {
    final out = <String, ana.Blended>{};
    for (final key in ana.PopulationPrior.supportedMetrics) {
      final b = await forMetric(key, profile: profile);
      if (b != null) out[key] = b;
    }
    return out;
  }
}
