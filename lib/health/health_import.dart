// health_import.dart — READ from the platform health store into metric_series.
//
// Upstream Edge only ever WROTE to Apple Health (see health_export.dart). This
// is the other direction: it pulls in the things the band cannot possibly know
// — what was eaten, body mass, workouts logged in other apps — so the coach can
// correlate them against recovery.
//
// DESIGN NOTES
//
// 1. metric_series, not new tables. `metric_series (date, key, value)` is the
//    canonical scalar store and `v_daily` already pivots it, so importing there
//    means the coach can reach this data through the existing allow-listed
//    views with no new plumbing.
//
// 2. Every imported key is `hk_`-prefixed. metric_series is REPLACE-on-conflict
//    and the DerivationEngine owns the unprefixed keys; a collision would let an
//    import silently clobber a derived metric (or vice-versa on the next
//    re-derive). The prefix makes the two namespaces disjoint by construction.
//
// 3. Own-source data is dropped. Edge WRITES steps/calories/workouts to the same
//    store. Reading those back would re-import our own exports, double-count
//    them, and on the next export round-trip them again. Points whose sourceId
//    matches this app are discarded — see [_isOwnSource].
//
// 4. Day bucketing goes through dayLabelOf(). Per day_label.dart, the whole day
//    model is keyed on LOCAL calendar dates; a UTC-derived label silently points
//    at the wrong day for most of the day in +HH timezones.
//
// 5. Nothing here throws. A denied permission or a locked store yields 0, never
//    an exception — matching health_export.dart's contract.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/day_label.dart';
import '../data/db.dart';

/// How each health type is folded into a single daily scalar.
enum _Agg {
  /// Sum every sample in the day (intake, steps, durations).
  sum,

  /// Keep the last sample of the day (point-in-time measurements like mass).
  last,

  /// Mean of the day's samples (heart rate and similar continuous signals,
  /// where neither a sum nor a single reading is meaningful).
  avg,

  /// Number of samples in the day (discrete events).
  count,
}

class _ImportSpec {
  final HealthDataType type;
  final String key; // metric_series key, always `hk_`-prefixed
  final _Agg agg;
  const _ImportSpec(this.type, this.key, this.agg);
}

class HealthImporter {
  final _health = Health();

  /// True on iOS/macOS (Apple Health); false on Android (Health Connect).
  static bool get isApple => Platform.isIOS || Platform.isMacOS;

  /// Display name of the platform health store.
  static String get storeName => isApple ? 'Apple Health' : 'Health Connect';

  /// How far back to reach on the very first import. Two years is enough to
  /// give the coach seasonal context without an unbounded first-run query.
  static const int firstRunBackfillDays = 730;

  /// Re-read the trailing window on every pass. Nutrition apps routinely edit
  /// yesterday's meals, and a strictly-forward cursor would never see the edit.
  static const int _rewriteTailDays = 7;

  static const String _cursorKey = 'health_import_through';

  /// What we pull, and the daily scalar each becomes.
  ///
  /// Deliberately excludes heart rate, HRV, resting HR, respiratory rate and
  /// sleep: the band measures those directly and far better than whatever else
  /// wrote them to the store. Importing them would put a worse duplicate next
  /// to a better one with no way for the coach to tell them apart.
  static const List<_ImportSpec> _specs = [
    // ── Nutrition ── every dietary type the package exposes.
    _ImportSpec(HealthDataType.DIETARY_ENERGY_CONSUMED, 'hk_kcal_in', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_PROTEIN_CONSUMED, 'hk_protein_g', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_CARBS_CONSUMED, 'hk_carbs_g', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_FATS_CONSUMED, 'hk_fat_g', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_FIBER, 'hk_fiber_g', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_SUGAR, 'hk_sugar_g', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_SODIUM, 'hk_sodium_mg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_CAFFEINE, 'hk_caffeine_mg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_FAT_SATURATED, 'hk_satfat_g', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_FAT_MONOUNSATURATED, 'hk_monofat_g', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_FAT_POLYUNSATURATED, 'hk_polyfat_g', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_CHOLESTEROL, 'hk_cholesterol_mg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_VITAMIN_A, 'hk_vita', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_THIAMIN, 'hk_thiamin', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_RIBOFLAVIN, 'hk_riboflavin', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_NIACIN, 'hk_niacin', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_PANTOTHENIC_ACID, 'hk_pantothenic', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_VITAMIN_B6, 'hk_vitb6', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_BIOTIN, 'hk_biotin', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_VITAMIN_B12, 'hk_vitb12', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_VITAMIN_C, 'hk_vitc_mg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_VITAMIN_D, 'hk_vitd_mcg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_VITAMIN_E, 'hk_vite', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_VITAMIN_K, 'hk_vitk', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_FOLATE, 'hk_folate', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_CALCIUM, 'hk_calcium_mg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_CHLORIDE, 'hk_chloride', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_IRON, 'hk_iron_mg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_MAGNESIUM, 'hk_magnesium_mg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_PHOSPHORUS, 'hk_phosphorus', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_POTASSIUM, 'hk_potassium_mg', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_ZINC, 'hk_zinc', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_CHROMIUM, 'hk_chromium', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_COPPER, 'hk_copper', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_IODINE, 'hk_iodine', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_MANGANESE, 'hk_manganese', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_MOLYBDENUM, 'hk_molybdenum', _Agg.sum),
    _ImportSpec(HealthDataType.DIETARY_SELENIUM, 'hk_selenium', _Agg.sum),
    _ImportSpec(HealthDataType.WATER, 'hk_water_l', _Agg.sum),
    // ── Movement ──
    _ImportSpec(HealthDataType.STEPS, 'hk_steps', _Agg.sum),
    _ImportSpec(HealthDataType.DISTANCE_WALKING_RUNNING, 'hk_distance_m', _Agg.sum),
    _ImportSpec(HealthDataType.DISTANCE_CYCLING, 'hk_distance_cycling_m', _Agg.sum),
    _ImportSpec(HealthDataType.DISTANCE_SWIMMING, 'hk_distance_swim_m', _Agg.sum),
    _ImportSpec(HealthDataType.FLIGHTS_CLIMBED, 'hk_flights', _Agg.sum),
    _ImportSpec(HealthDataType.EXERCISE_TIME, 'hk_exercise_min', _Agg.sum),
    _ImportSpec(HealthDataType.MINDFULNESS, 'hk_mindful_min', _Agg.sum),
    _ImportSpec(HealthDataType.ACTIVE_ENERGY_BURNED, 'hk_active_kcal', _Agg.sum),
    _ImportSpec(HealthDataType.BASAL_ENERGY_BURNED, 'hk_basal_kcal', _Agg.sum),
    // ── Sleep (historic) ── 
    // Imported despite the band measuring sleep, because Apple Watch history
    // can predate the band by years. The hk_ prefix keeps it a SEPARATE series
    // from our own staging, so a worse source can never overwrite a better one.
    _ImportSpec(HealthDataType.SLEEP_ASLEEP, 'hk_sleep_asleep_min', _Agg.sum),
    _ImportSpec(HealthDataType.SLEEP_DEEP, 'hk_sleep_deep_min', _Agg.sum),
    _ImportSpec(HealthDataType.SLEEP_REM, 'hk_sleep_rem_min', _Agg.sum),
    _ImportSpec(HealthDataType.SLEEP_LIGHT, 'hk_sleep_light_min', _Agg.sum),
    _ImportSpec(HealthDataType.SLEEP_AWAKE, 'hk_sleep_awake_min', _Agg.sum),
    _ImportSpec(HealthDataType.SLEEP_IN_BED, 'hk_sleep_inbed_min', _Agg.sum),
    // ── Body composition ── point-in-time, so keep the day's last.
    _ImportSpec(HealthDataType.WEIGHT, 'hk_weight_kg', _Agg.last),
    _ImportSpec(HealthDataType.HEIGHT, 'hk_height_m', _Agg.last),
    _ImportSpec(HealthDataType.BODY_FAT_PERCENTAGE, 'hk_bodyfat_pct', _Agg.last),
    _ImportSpec(HealthDataType.BODY_MASS_INDEX, 'hk_bmi', _Agg.last),
    _ImportSpec(HealthDataType.BODY_WATER_MASS, 'hk_body_water_kg', _Agg.last),
    _ImportSpec(HealthDataType.WAIST_CIRCUMFERENCE, 'hk_waist_cm', _Agg.last),
    // ── Vitals ──
    _ImportSpec(HealthDataType.BLOOD_PRESSURE_SYSTOLIC, 'hk_bp_sys', _Agg.last),
    _ImportSpec(HealthDataType.BLOOD_PRESSURE_DIASTOLIC, 'hk_bp_dia', _Agg.last),
    _ImportSpec(HealthDataType.BLOOD_GLUCOSE, 'hk_glucose', _Agg.last),
    _ImportSpec(HealthDataType.BODY_TEMPERATURE, 'hk_body_temp_c', _Agg.last),
    _ImportSpec(HealthDataType.BLOOD_OXYGEN, 'hk_spo2', _Agg.last),
    _ImportSpec(HealthDataType.RESPIRATORY_RATE, 'hk_resp_rate', _Agg.last),
    _ImportSpec(HealthDataType.FORCED_EXPIRATORY_VOLUME, 'hk_fev1', _Agg.last),
    _ImportSpec(HealthDataType.PERIPHERAL_PERFUSION_INDEX, 'hk_perfusion', _Agg.last),
    // ── Cardio (historic) ── 
    // Same reasoning as sleep: separate series, never merged with band data.
    _ImportSpec(HealthDataType.HEART_RATE, 'hk_hr_avg', _Agg.avg),
    _ImportSpec(HealthDataType.RESTING_HEART_RATE, 'hk_rhr', _Agg.avg),
    _ImportSpec(HealthDataType.WALKING_HEART_RATE, 'hk_walking_hr', _Agg.avg),
    _ImportSpec(HealthDataType.HEART_RATE_VARIABILITY_SDNN, 'hk_hrv_sdnn', _Agg.avg),
    _ImportSpec(HealthDataType.HEART_RATE_VARIABILITY_RMSSD, 'hk_hrv_rmssd', _Agg.avg),
    // ── Cardiac events ──
    _ImportSpec(HealthDataType.HIGH_HEART_RATE_EVENT, 'hk_ev_high_hr', _Agg.count),
    _ImportSpec(HealthDataType.LOW_HEART_RATE_EVENT, 'hk_ev_low_hr', _Agg.count),
    _ImportSpec(HealthDataType.IRREGULAR_HEART_RATE_EVENT, 'hk_ev_irregular_hr', _Agg.count),
  ];



  List<HealthDataType> get _types => _specs.map((s) => s.type).toList();

  /// Ask for READ access. Returns false when the user declines or the store is
  /// unavailable; never throws.
  Future<bool> requestPermission() async {
    try {
      _health.configure();
      return await _health.requestAuthorization(
        _types,
        permissions: List.filled(_types.length, HealthDataAccess.READ),
      );
    } catch (e) {
      debugPrint('[health_import] permission request failed: $e');
      return false;
    }
  }

  /// A point written by THIS app, which must never be re-imported (see note 3).
  ///
  /// Matched on sourceId (the bundle id on iOS) with a sourceName fallback,
  /// because Health Connect populates the two differently.
  static bool _isOwnSource(HealthDataPoint p) {
    const ownBundle = 'com.isashahid.openstrapEdge';
    final id = p.sourceId.toLowerCase();
    final name = p.sourceName.toLowerCase();
    return id == ownBundle.toLowerCase() ||
        id.endsWith('.openstrapedge') ||
        name == 'whoop' ||
        name == 'edge' ||
        name == 'openstrap';
  }

  static double? _numeric(HealthDataPoint p) {
    final v = p.value;
    if (v is NumericHealthValue) return v.numericValue.toDouble();
    return null;
  }

  /// Pull everything since the cursor (or [firstRunBackfillDays] on first run)
  /// and fold it into metric_series. Returns the number of daily scalars
  /// written. Always safe to call; re-running is idempotent because
  /// metric_series is REPLACE-keyed on (date, key).
  Future<int> importRecent({int? backfillDays}) async {
    try {
      _health.configure();

      final now = DateTime.now();
      final cursor = await LocalDb.getCursor(_cursorKey);
      final DateTime start;
      if (cursor == null || cursor.isEmpty) {
        start = now.subtract(
            Duration(days: backfillDays ?? firstRunBackfillDays));
      } else {
        final parsed = DateTime.tryParse(cursor);
        start = (parsed ?? now.subtract(const Duration(days: 30)))
            .subtract(const Duration(days: _rewriteTailDays));
      }

      // Fetch PER TYPE rather than in one batch. getHealthDataFromTypes loops
      // internally and a single unsupported or unauthorised type throws for the
      // whole call — which, with 70+ types, would mean one odd metric silently
      // costing every other one. Slower, but a bad type now costs only itself.
      final points = <HealthDataPoint>[];
      var failedTypes = 0;
      for (final spec in _specs) {
        try {
          points.addAll(await _health.getHealthDataFromTypes(
            types: [spec.type],
            startTime: start,
            endTime: now,
          ));
        } catch (_) {
          failedTypes++;
        }
      }

      // date -> key -> value, folded per spec.
      final byDay = <String, Map<String, double>>{};
      final lastSeenAt = <String, DateTime>{}; // for _Agg.last tie-breaks
      final avgN = <String, int>{}; // running counts for _Agg.avg
      final specByType = {for (final s in _specs) s.type: s};

      var skippedOwn = 0;
      for (final p in points) {
        if (_isOwnSource(p)) {
          skippedOwn++;
          continue;
        }
        final spec = specByType[p.type];
        if (spec == null) continue;
        final value = _numeric(p);
        if (value == null || value.isNaN || value.isInfinite) continue;

        final day = dayLabelOf(p.dateFrom);
        final bucket = byDay.putIfAbsent(day, () => <String, double>{});

        switch (spec.agg) {
          case _Agg.sum:
            bucket[spec.key] = (bucket[spec.key] ?? 0) + value;
          case _Agg.count:
            bucket[spec.key] = (bucket[spec.key] ?? 0) + 1;
          case _Agg.avg:
            // Running mean, so a day of 1 Hz heart rate does not need holding
            // in memory: mean += (x - mean) / n.
            final stamp = '$day|${spec.key}';
            final n = (avgN[stamp] ?? 0) + 1;
            avgN[stamp] = n;
            final prev = bucket[spec.key] ?? 0;
            bucket[spec.key] = prev + (value - prev) / n;
          case _Agg.last:
            final stamp = '$day|${spec.key}';
            final prev = lastSeenAt[stamp];
            if (prev == null || !p.dateFrom.isBefore(prev)) {
              bucket[spec.key] = value;
              lastSeenAt[stamp] = p.dateFrom;
            }
        }
      }

      if (byDay.isEmpty) {
        debugPrint('[health_import] no points (${points.length} read, '
            '$skippedOwn own-source skipped, $failedTypes types unavailable)');
        await LocalDb.setCursor(_cursorKey, now.toIso8601String());
        return 0;
      }

      final db = await LocalDb.instance;
      var written = 0;
      await db.transaction((txn) async {
        for (final dayEntry in byDay.entries) {
          for (final metric in dayEntry.value.entries) {
            await txn.insert(
              'metric_series',
              {
                'date': dayEntry.key,
                'key': metric.key,
                'value': metric.value,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            written++;
          }
        }
      });

      await LocalDb.setCursor(_cursorKey, now.toIso8601String());
      debugPrint('[health_import] wrote $written scalars across '
          '${byDay.length} days ($skippedOwn own-source skipped, '
          '$failedTypes of ${_specs.length} types unavailable)');
      return written;
    } catch (e, st) {
      // Contract: never throw. A denied permission, a locked store or a
      // platform quirk must degrade to "imported nothing", not crash a sync.
      debugPrint('[health_import] import failed: $e\n$st');
      return 0;
    }
  }

  /// Wipe the cursor so the next [importRecent] re-reads the full backfill
  /// window. Used by "re-import everything" in settings.
  static Future<void> resetCursor() => LocalDb.setCursor(_cursorKey, '');
}
