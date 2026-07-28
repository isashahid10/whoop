// hevy_detail.dart — lift breakdown + energy estimate for an imported session.
//
// The workouts detail screen was built for BAND sessions: it reads heart rate,
// strain and zone minutes off the 1 Hz substrate. A Hevy session has none of
// those when the band wasn't worn, so it rendered "No data" while thousands of
// rows of sets, reps and load sat unused in `hevy_set`.
//
// ENERGY — two paths, and which one ran is always reported:
//
//   MEASURED   the band WAS worn over the session window, so Keytel (2005)
//              runs off real HR. Handled upstream in getWorkout's enrichment;
//              nothing here overrides it.
//   ESTIMATED  no HR overlap. Falls back to the Ainsworth Compendium MET value
//              for resistance training × body mass × duration. This is a
//              POPULATION estimate, not a measurement, and is labelled as such
//              wherever it is shown.
//
// The estimate is deliberately not written into `sessions.calories`: that column
// is where measured values live, and blending the two would make a real number
// indistinguishable from a guess. It is computed on read and carries its method.

import '../data/db.dart';

/// How an energy figure was arrived at. Surfaced in the UI — a measured value
/// and a population estimate must never look alike.
enum EnergyMethod { measured, estimated, unavailable }

class HevySetRow {
  final String exercise;
  final String? muscleGroup;
  final String? equipment;
  final int setIndex;
  final String indicator; // normal | warmup | failure | dropset
  final double? weightKg;
  final int? reps;
  final double? rpe;
  final double? volumeKg;
  final double? distanceM;
  final int? durationS;

  const HevySetRow({
    required this.exercise,
    required this.setIndex,
    required this.indicator,
    this.muscleGroup,
    this.equipment,
    this.weightKg,
    this.reps,
    this.rpe,
    this.volumeKg,
    this.distanceM,
    this.durationS,
  });

  /// True for sets that count toward working volume. Warm-ups are logged but
  /// must not inflate volume or PR comparisons.
  bool get isWorking => indicator != 'warmup';
}

/// One exercise with its sets, in the order performed.
class HevyExerciseBlock {
  final String title;
  final String? muscleGroup;
  final String? equipment;
  final List<HevySetRow> sets;

  const HevyExerciseBlock({
    required this.title,
    required this.sets,
    this.muscleGroup,
    this.equipment,
  });

  List<HevySetRow> get workingSets => sets.where((s) => s.isWorking).toList();

  /// Heaviest working set — the number that actually tracks strength.
  HevySetRow? get topSet {
    HevySetRow? best;
    for (final s in workingSets) {
      if (s.weightKg == null) continue;
      if (best == null || s.weightKg! > best.weightKg!) best = s;
    }
    return best;
  }

  double get volumeKg =>
      workingSets.fold<double>(0, (a, s) => a + (s.volumeKg ?? 0));
}

class HevyWorkoutDetail {
  final List<HevyExerciseBlock> exercises;
  final double totalVolumeKg;
  final int workingSets;
  final int? energyKcal;
  final EnergyMethod energyMethod;

  const HevyWorkoutDetail({
    required this.exercises,
    required this.totalVolumeKg,
    required this.workingSets,
    required this.energyKcal,
    required this.energyMethod,
  });

  bool get isEmpty => exercises.isEmpty;
}

class HevyDetail {
  /// A `sessions.id` of the form `hevy_<workoutId>` maps back to hevy_set.
  static String? workoutIdFromSessionId(String sessionId) =>
      sessionId.startsWith('hevy_') ? sessionId.substring(5) : null;

  /// MET value for resistance training, Ainsworth 2011 Compendium of Physical
  /// Activities (code 02050, "resistance training, squats, slow or explosive
  /// effort" ≈ 6.0; general/moderate free-weight work ≈ 3.5).
  ///
  /// 5.0 is used as a mid-point: a logged Hevy session is rarely a full hour of
  /// continuous effort (most of it is inter-set rest), so the vigorous value
  /// would overstate a typical session, and the moderate value understates a
  /// heavy one. Anything derived from this is an ESTIMATE and says so.
  static const double resistanceMet = 5.0;

  /// kcal = MET × body mass (kg) × hours. Null without a body mass — an energy
  /// figure invented from a default weight is worse than no figure.
  static int? metEstimateKcal({
    required double? weightKg,
    required int durationSeconds,
  }) {
    if (weightKg == null || weightKg <= 0) return null;
    if (durationSeconds <= 0) return null;
    final hours = durationSeconds / 3600.0;
    return (resistanceMet * weightKg * hours).round();
  }

  /// Load the lift breakdown for a session, plus an energy figure.
  ///
  /// [measuredKcal] is whatever the band-derived enrichment already produced;
  /// when present it wins and the method is reported as measured.
  static Future<HevyWorkoutDetail?> forSession(
    String sessionId, {
    int? measuredKcal,
    double? weightKg,
    int? durationSeconds,
  }) async {
    final workoutId = workoutIdFromSessionId(sessionId);
    if (workoutId == null) return null;

    final db = await LocalDb.instance;
    final rows = await db.query(
      'hevy_set',
      where: 'workout_id = ?',
      whereArgs: [workoutId],
      orderBy: 'exercise_idx ASC, set_idx ASC',
    );
    if (rows.isEmpty) return null;

    // Group into exercises, preserving performed order.
    final blocks = <HevyExerciseBlock>[];
    String? currentTitle;
    var current = <HevySetRow>[];
    String? curMuscle;
    String? curEquip;

    void flush() {
      if (currentTitle != null && current.isNotEmpty) {
        blocks.add(HevyExerciseBlock(
          title: currentTitle,
          muscleGroup: curMuscle,
          equipment: curEquip,
          sets: List.of(current),
        ));
      }
      current = <HevySetRow>[];
    }

    for (final r in rows) {
      final title = (r['exercise_title'] as String?) ?? 'Unknown';
      if (title != currentTitle) {
        flush();
        currentTitle = title;
        curMuscle = r['muscle_group'] as String?;
        curEquip = r['equipment'] as String?;
      }
      current.add(HevySetRow(
        exercise: title,
        muscleGroup: r['muscle_group'] as String?,
        equipment: r['equipment'] as String?,
        setIndex: (r['set_idx'] as num?)?.toInt() ?? 0,
        indicator: (r['indicator'] as String?) ?? 'normal',
        weightKg: (r['weight_kg'] as num?)?.toDouble(),
        reps: (r['reps'] as num?)?.toInt(),
        rpe: (r['rpe'] as num?)?.toDouble(),
        volumeKg: (r['volume_kg'] as num?)?.toDouble(),
        distanceM: (r['distance_m'] as num?)?.toDouble(),
        durationS: (r['duration_s'] as num?)?.toInt(),
      ));
    }
    flush();

    final working =
        blocks.fold<int>(0, (a, b) => a + b.workingSets.length);
    final volume = blocks.fold<double>(0, (a, b) => a + b.volumeKg);

    final int? kcal;
    final EnergyMethod method;
    if (measuredKcal != null && measuredKcal > 0) {
      kcal = measuredKcal;
      method = EnergyMethod.measured;
    } else {
      final est = metEstimateKcal(
        weightKg: weightKg,
        durationSeconds: durationSeconds ?? 0,
      );
      kcal = est;
      method = est == null ? EnergyMethod.unavailable : EnergyMethod.estimated;
    }

    return HevyWorkoutDetail(
      exercises: blocks,
      totalVolumeKg: volume,
      workingSets: working,
      energyKcal: kcal,
      energyMethod: method,
    );
  }
}
