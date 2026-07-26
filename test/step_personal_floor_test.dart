// The 1 Hz activity estimator's PERSONAL floor — the edge half of the fix for
// the "39,384 steps" bug.
//
// The analytics package decides activity from a calibration-invariant dynamic
// amplitude, but it is pure: it cannot read history, so it cannot know what
// "moving" means for this wearer. Edge supplies that. Each day persists its own
// high quantile of the dynamic amplitude (`dyn_p90`), and the next day's derive
// takes the MEDIAN across trailing days as its floor.
//
// Two properties matter here and neither is obvious from the analytics tests:
//
//   1. COLD START ABSTAINS. Below the minimum history there is no floor, and the
//      estimator must return absent rather than fall back to a constant.
//      Falling back to a constant is precisely the bug: the old estimator's
//      absolute 0.05 g floor was the same magnitude as the gravity-reference
//      error, so a quiet day's sedentary minutes cleared it for hours.
//
//   2. A SINGLE ANOMALOUS DAY CANNOT MOVE THE FLOOR. That is why the anchor is
//      a median across days rather than a same-day quantile — a same-day floor
//      collapses on a quiet day and passes everything, the mirror image of the
//      absolute-constant failure.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

/// Per-minute rows carrying DELIBERATELY MISLEADING ENMO: every sedentary
/// minute sits at 0.055 g, just above the absolute 0.05 g floor the old
/// estimator used. If an ENMO-based decision path is ever reintroduced these
/// tests fail loudly instead of shipping tens of thousands of phantom steps.
List<ana.MotionMinute> rows(List<double> dyn) => [
      for (var i = 0; i < dyn.length; i++)
        ana.MotionMinute(i * 60000.0, 60, 0.055, 0.02, 1.055, dyn[i]),
    ];

void main() {
  group('personal ambulatory floor — cold start', () {
    test('no trailing history → no floor → the estimator ABSTAINS', () {
      // Exactly what a fresh install has on day one.
      final floor = ana.personalDynFloorFromDailySummaries(const []);
      expect(floor, isNull);

      final est = ana.dailyStepEstimate(
        rows(List<double>.filled(600, 0.60)), // plenty of real movement
        personalDynFloorG: floor,
      );
      expect(est.present, isFalse,
          reason: 'without a personal baseline the honest answer is "unknown", '
              'not a number computed against a guessed threshold');
    });

    test('a day just under the minimum history still abstains', () {
      final tooFew = List<double>.filled(ana.personalDynFloorMinDays - 1, 0.44);
      expect(ana.personalDynFloorFromDailySummaries(tooFew), isNull);
    });

    test('once enough days exist the floor appears and the estimate follows',
        () {
      final enough = List<double>.filled(ana.personalDynFloorMinDays, 0.44);
      final floor = ana.personalDynFloorFromDailySummaries(enough);
      expect(floor, isNotNull);

      final est = ana.dailyStepEstimate(
        rows(List<double>.filled(600, 0.60)),
        personalDynFloorG: floor,
      );
      expect(est.present, isTrue);
      expect(est.value!.activeMinutes, greaterThan(0));
    });
  });

  group('personal ambulatory floor — stability', () {
    test('a sedentary day produces no active minutes against a real floor', () {
      // The 39,384 shape: a full day of sitting still. Every minute carries an
      // ENMO above the OLD absolute floor, so this is the exact input that used
      // to inflate — it must now yield nothing.
      final floor =
          ana.personalDynFloorFromDailySummaries(List<double>.filled(7, 0.44))!;
      final est = ana.dailyStepEstimate(
        rows(List<double>.filled(900, 0.02)), // sedentary dynamic amplitude
        personalDynFloorG: floor,
      );
      expect(est.present, isTrue);
      expect(est.value!.activeMinutes, 0);
      expect(est.value!.steps, 0);
    });

    test('one anomalous day cannot drag the floor (median across days)', () {
      final normal = <double>[0.44, 0.43, 0.45, 0.44, 0.46, 0.43, 0.45];
      final clean = ana.personalDynFloorFromDailySummaries(normal)!;
      final polluted =
          ana.personalDynFloorFromDailySummaries([...normal, 9.0, 8.0])!;
      expect((clean - polluted).abs(), lessThan(0.02));
    });

    test('the floor a quiet day contributes does not collapse the threshold',
        () {
      // A same-day threshold would collapse here and pass everything; the
      // multi-day median holds the line.
      final withQuietDay =
          <double>[0.44, 0.43, 0.45, 0.001, 0.44, 0.46, 0.45];
      final floor = ana.personalDynFloorFromDailySummaries(withQuietDay)!;
      expect(floor, greaterThan(0.4));

      final est = ana.dailyStepEstimate(
        rows(List<double>.filled(900, 0.02)),
        personalDynFloorG: floor,
      );
      expect(est.value!.activeMinutes, 0);
    });
  });

  group('what edge persists each day', () {
    test('dailyDynSummary produces the per-day value the floor pools', () {
      final day = rows([for (var i = 0; i < 600; i++) i / 1000.0]);
      final summary = ana.dailyDynSummary(day);
      expect(summary, isNotNull);
      expect(summary!, greaterThan(0));
    });

    test('a day too thin to summarise stores nothing, not a zero', () {
      // Storing 0 would poison the median for every later day.
      expect(ana.dailyDynSummary(rows(List<double>.filled(10, 0.4))), isNull);
    });
  });
}
