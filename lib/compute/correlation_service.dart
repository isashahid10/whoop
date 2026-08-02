// correlation_service.dart — what to test, and with what data.
//
// The statistics live in analytics' correlations.dart. What lives HERE is the
// judgement about which relationships are worth testing at all, and that is the
// part that decides whether this feature is useful or noise.
//
// TESTING EVERYTHING AGAINST EVERYTHING IS THE WRONG MOVE. With ~20 metrics
// that is 400 pairs; FDR correction would then demand such small p-values that
// a genuine moderate effect over 30 days could never clear the bar. The
// multiple-comparison correction protects against false positives by making
// true positives harder to find, so the family has to be kept small and
// deliberate.
//
// So the list below is hypothesis-driven: each pair is something with a
// plausible physiological mechanism and an actionable answer. "Does protein
// move recovery" earns a slot. "Does humidity correlate with step count" does
// not, however easy it would be to add.
//
// LAG DIRECTION encodes the causal story. A predictor is measured against the
// FOLLOWING day's outcome wherever the mechanism is overnight — protein eaten
// today cannot be caused by tomorrow's recovery, which rules out the reverse
// arrow. Same-day pairs (lag 0) are used only where the mechanism is
// simultaneous, and are labelled as associations with no direction claimed.

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import '../notify/ramadan.dart';

class CorrelationService {
  CorrelationService._();

  /// How far back to look. Long enough to accumulate the 14 paired days each
  /// test needs, short enough that a training block from six months ago does
  /// not dilute the current one.
  static const int windowDays = 120;

  /// The hypotheses worth testing.
  ///
  /// Each has a mechanism and an action attached to the answer; a pair that
  /// would change nothing about what you do next does not belong here, because
  /// its only effect is to make every other test harder to detect.
  static const List<ana.CorrelationSpec> specs = [
    // ── nutrition → recovery ─────────────────────────────────────────────
    ana.CorrelationSpec(
      predictor: 'hk_protein_g',
      outcome: 'readiness',
      predictorLabel: 'protein',
      outcomeLabel: 'readiness',
    ),
    ana.CorrelationSpec(
      predictor: 'hk_kcal_in',
      outcome: 'readiness',
      predictorLabel: 'calories eaten',
      outcomeLabel: 'readiness',
    ),
    ana.CorrelationSpec(
      predictor: 'hk_water_l',
      outcome: 'rmssd',
      predictorLabel: 'water',
      outcomeLabel: 'HRV',
    ),

    // ── training load → recovery ─────────────────────────────────────────
    ana.CorrelationSpec(
      predictor: 'strain',
      outcome: 'rmssd',
      predictorLabel: 'strain',
      outcomeLabel: 'HRV',
    ),
    ana.CorrelationSpec(
      predictor: 'strain',
      outcome: 'sleep_score',
      predictorLabel: 'strain',
      outcomeLabel: 'sleep quality',
    ),
    ana.CorrelationSpec(
      predictor: 'strain',
      outcome: 'rhr',
      predictorLabel: 'strain',
      outcomeLabel: 'resting heart rate',
    ),

    // ── sleep → next-day capacity ────────────────────────────────────────
    ana.CorrelationSpec(
      predictor: 'sleep_score',
      outcome: 'readiness',
      predictorLabel: 'sleep quality',
      outcomeLabel: 'readiness',
    ),
    ana.CorrelationSpec(
      predictor: 'tst_min',
      outcome: 'strain',
      predictorLabel: 'sleep duration',
      outcomeLabel: 'next-day strain',
    ),
    ana.CorrelationSpec(
      predictor: 'waso_min',
      outcome: 'readiness',
      predictorLabel: 'time awake in bed',
      outcomeLabel: 'readiness',
    ),

    // ── environment → sleep ──────────────────────────────────────────────
    //
    // Lag 0: the night's heat acts on the SAME night's sleep, so this is a
    // same-day association and no direction is implied.
    ana.CorrelationSpec(
      predictor: 'wx_temp_max_c',
      outcome: 'sleep_score',
      predictorLabel: 'daytime heat',
      outcomeLabel: 'sleep quality',
      lagDays: 0,
    ),
    ana.CorrelationSpec(
      predictor: 'wx_temp_max_c',
      outcome: 'rmssd',
      predictorLabel: 'daytime heat',
      outcomeLabel: 'HRV',
      lagDays: 0,
    ),

    // ── schedule load → stress and sleep ─────────────────────────────────
    ana.CorrelationSpec(
      predictor: 'cal_busy_min',
      outcome: 'stress',
      predictorLabel: 'booked hours',
      outcomeLabel: 'stress',
      lagDays: 0,
    ),
    ana.CorrelationSpec(
      predictor: 'cal_busy_min',
      outcome: 'sleep_score',
      predictorLabel: 'booked hours',
      outcomeLabel: 'sleep quality',
      lagDays: 0,
    ),

    // ── movement → sleep ─────────────────────────────────────────────────
    ana.CorrelationSpec(
      predictor: 'hk_steps',
      outcome: 'sleep_score',
      predictorLabel: 'steps',
      outcomeLabel: 'sleep quality',
      lagDays: 0,
    ),
  ];

  /// Every key any spec needs, so the query fetches exactly those.
  static Set<String> get _keys => {
        for (final s in specs) ...[s.predictor, s.outcome],
      };

  /// Run the family.
  static Future<ana.CorrelationReport> analyse() async {
    try {
      final db = await LocalDb.instance;
      final from = DateTime.now().subtract(const Duration(days: windowDays));
      final cutoff = '${from.year.toString().padLeft(4, '0')}-'
          '${from.month.toString().padLeft(2, '0')}-'
          '${from.day.toString().padLeft(2, '0')}';

      final keys = _keys.toList();
      final placeholders = List.filled(keys.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT date, key, value FROM metric_series '
        'WHERE key IN ($placeholders) AND date >= ? AND value IS NOT NULL',
        [...keys, cutoff],
      );

      // Fasted days are a DIFFERENT POPULATION. Ramadan compresses the eating
      // window, shifts sleep around suhoor and moves training — so a month of
      // fasted days mixed into the same series does not add statistical power,
      // it adds a confounder correlated with almost every variable at once.
      // The honest options are to model fasting explicitly or to exclude it;
      // excluding is the one that cannot produce a wrong answer.
      final fasted = await RamadanService.fastingDays();

      final byDay = <String, Map<String, double>>{};
      for (final r in rows) {
        final date = r['date'] as String?;
        final key = r['key'] as String?;
        final v = (r['value'] as num?)?.toDouble();
        if (date == null || key == null || v == null) continue;
        if (fasted.contains(date)) continue;
        (byDay[date] ??= {})[key] = v;
      }

      return ana.analyseCorrelations(byDay: byDay, specs: specs);
    } catch (_) {
      return ana.CorrelationReport.empty;
    }
  }
}
