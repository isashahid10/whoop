// readiness_service.dart — the read path for readiness' glass-box breakdown.
//
// The breakdown was never missing from the DATA. `readinessComposite` emits a
// ranked `drivers` list on its Metric, and the pipeline already persists the
// whole envelope under `clinical.readiness_composite` in day_result. Tapping
// the readiness ring simply opened a coach screen or a one-paragraph info
// sheet, so none of it was ever shown.
//
// WHAT A DRIVER IS, precisely. Each input (HRV, resting HR, breathing rate,
// skin temperature) is turned into a robust z-score against that input's own
// trailing baseline, oriented so positive always means "good for readiness",
// then multiplied by its disclosed weight and renormalised over whichever
// inputs were actually present. The contributions therefore SUM to the
// composite z by construction.
//
// That construction is also the honest limit, and the analytics note says so:
// a driver is definitional within the formula, not an inferred cause. "Your
// resting heart rate contributed -0.90" means the arithmetic decomposes that
// way. It does not mean an elevated resting HR caused the rest of it.

import 'dart:convert';

import '../data/db.dart';

/// One input's signed contribution to the composite z.
class ReadinessDriver {
  /// Raw label from analytics: 'HRV', 'RHR', 'RR', 'temp'.
  final String key;

  /// Weighted, renormalised contribution. Positive helps, negative hurts.
  final double contribution;

  /// The oriented z-score this input sat at, parsed from the detail string.
  /// Null when the detail could not be parsed, which must not break the row.
  final double? z;

  /// True when the z came from the mean/SD fallback rather than median/MAD.
  /// Surfaced because the disclosed method has to be the method actually used.
  final bool usedFallback;

  const ReadinessDriver({
    required this.key,
    required this.contribution,
    this.z,
    this.usedFallback = false,
  });

  /// Plain-English name. The raw labels are internal shorthand.
  String get label => switch (key) {
        'HRV' => 'Heart rate variability',
        'RHR' => 'Resting heart rate',
        'RR' => 'Breathing rate',
        'temp' => 'Skin temperature',
        _ => key,
      };

  /// Which way this input moved relative to the user's own baseline.
  ///
  /// Note this is the RAW direction, not the readiness-oriented one: a resting
  /// heart rate that is higher than usual reads "higher than usual" and hurts,
  /// which is only confusing if the two are conflated.
  String get direction {
    final zz = z;
    if (zz == null || zz.abs() < 0.5) return 'about usual';
    // z is already oriented so + is good. Undo that for the raw description.
    final higherIsBetter = key == 'HRV';
    final raw = higherIsBetter ? zz : -zz;
    return raw > 0 ? 'higher than usual' : 'lower than usual';
  }

  bool get helps => contribution > 0;
}

class ReadinessBreakdown {
  final double score;
  final double compositeZ;

  /// False when the composite sat inside the smallest worthwhile change, i.e.
  /// today is not meaningfully different from your own normal.
  final bool meaningful;

  final double confidence;
  final List<ReadinessDriver> drivers;

  /// Inputs that were available. Fewer inputs means lower confidence, and the
  /// screen says which ones were missing rather than implying all four ran.
  final List<String> inputsUsed;

  const ReadinessBreakdown({
    required this.score,
    required this.compositeZ,
    required this.meaningful,
    required this.confidence,
    required this.drivers,
    required this.inputsUsed,
  });

  /// The single input most responsible for today's score.
  ReadinessDriver? get lead => drivers.isEmpty ? null : drivers.first;
}

class ReadinessService {
  ReadinessService._();

  /// Every input the composite can use, so the UI can name the absent ones.
  static const List<String> allInputs = ['HRV', 'RHR', 'RR', 'temp'];

  static Future<ReadinessBreakdown?> forDay(String day) async {
    try {
      final row = await LocalDb.dayResult(day);
      if (row == null) return null;
      return parse(row);
    } catch (_) {
      return null;
    }
  }

  /// Visible for tests: the shape here is set by analytics' Metric envelope,
  /// and a change there must fail a test rather than silently show nothing.
  static ReadinessBreakdown? parse(Map<String, dynamic> row) {
    Object? payload = row['payload_json'] ?? row['payload'] ?? row;
    if (payload is String) payload = jsonDecode(payload);
    if (payload is! Map) return null;

    final clinical = payload['clinical'];
    if (clinical is! Map) return null;
    final rc = clinical['readiness_composite'];
    if (rc is! Map) return null;

    final value = rc['value'];
    if (value is! Map) return null;
    final score = (value['score'] as num?)?.toDouble();
    if (score == null) return null;

    final drivers = <ReadinessDriver>[];
    final raw = rc['drivers'];
    if (raw is List) {
      for (final d in raw) {
        if (d is! Map) continue;
        final key = d['label'];
        final c = (d['contribution'] as num?)?.toDouble();
        if (key is! String || c == null) continue;
        final detail = d['detail'];
        drivers.add(
          ReadinessDriver(
            key: key,
            contribution: c,
            z: detail is String ? _z(detail) : null,
            usedFallback: detail is String && detail.contains('fallback'),
          ),
        );
      }
    }

    return ReadinessBreakdown(
      score: score,
      compositeZ: (value['composite_z'] as num?)?.toDouble() ?? 0,
      meaningful: value['meaningful'] == true,
      confidence: (rc['confidence'] as num?)?.toDouble() ?? 0,
      drivers: drivers,
      inputsUsed: [
        for (final i in (rc['inputs_used'] as List? ?? const []))
          if (i is String) i,
      ],
    );
  }

  /// Pull the oriented z out of 'oriented robust-z (median+MAD)=-3.001111'.
  ///
  /// Parsed rather than stored separately because the string is what analytics
  /// already emits; adding a parallel field would be a second source of truth
  /// for the same number.
  static double? _z(String detail) {
    final i = detail.lastIndexOf('=');
    if (i < 0 || i + 1 >= detail.length) return null;
    return double.tryParse(detail.substring(i + 1).trim());
  }
}
