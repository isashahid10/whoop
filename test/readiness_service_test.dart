// The readiness breakdown parser, pinned against the REAL envelope analytics
// emits. The fixture below is copied verbatim from a live day_result row
// rather than invented, so a change to the Metric shape upstream fails here
// instead of silently rendering an empty screen.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/readiness_service.dart';

/// Verbatim from day_result for 2026-08-02.
const _real = {
  'value': {
    'score': 25.037188,
    'composite_z': -1.09663,
    'meaningful': true,
  },
  'confidence': 0.9,
  'tier': 'ESTIMATE',
  'inputs_used': ['HRV', 'RHR', 'RR', 'temp'],
  'drivers': [
    {
      'label': 'RHR',
      'contribution': -0.900333,
      'detail': 'oriented robust-z (median+MAD)=-3.001111',
    },
    {
      'label': 'HRV',
      'contribution': -0.514371,
      'detail': 'oriented robust-z (median+MAD)=-1.285928',
    },
    {
      'label': 'RR',
      'contribution': 0.312401,
      'detail': 'oriented robust-z (median+MAD)=1.562006',
    },
    {
      'label': 'temp',
      'contribution': 0.005674,
      'detail': 'oriented robust-z (median+MAD)=0.056735',
    },
  ],
};

Map<String, dynamic> row({Map<String, dynamic>? rc}) => {
      'payload_json': jsonEncode({
        'clinical': {'readiness_composite': rc ?? _real},
      }),
    };

void main() {
  group('parsing the real envelope', () {
    test('reads score, composite and drivers', () {
      final b = ReadinessService.parse(row())!;
      expect(b.score, closeTo(25.04, 0.01));
      expect(b.compositeZ, closeTo(-1.0966, 0.001));
      expect(b.meaningful, isTrue);
      expect(b.drivers, hasLength(4));
    });

    test('drivers keep analytics ordering, biggest first', () {
      final b = ReadinessService.parse(row())!;
      expect(b.lead!.key, 'RHR');
      expect(b.drivers.map((d) => d.key).toList(),
          ['RHR', 'HRV', 'RR', 'temp']);
    });

    test('the oriented z is parsed out of the detail string', () {
      final b = ReadinessService.parse(row())!;
      expect(b.drivers.first.z, closeTo(-3.0011, 0.001));
      expect(b.drivers.first.usedFallback, isFalse);
    });

    test('sign is preserved: RHR hurt, RR helped', () {
      // The whole point of the diverging bar. Losing the sign would make an
      // elevated resting HR look identical to a lowered one.
      final b = ReadinessService.parse(row())!;
      expect(b.drivers.firstWhere((d) => d.key == 'RHR').helps, isFalse);
      expect(b.drivers.firstWhere((d) => d.key == 'RR').helps, isTrue);
    });

    test('direction describes the RAW input, not the oriented z', () {
      // Resting HR three SD above baseline is "higher than usual" AND bad.
      // Reporting it as "lower" because its oriented z is negative would be
      // the easy mistake here.
      final b = ReadinessService.parse(row())!;
      expect(b.drivers.firstWhere((d) => d.key == 'RHR').direction,
          'higher than usual');
      // HRV below baseline is "lower than usual" and also bad.
      expect(b.drivers.firstWhere((d) => d.key == 'HRV').direction,
          'lower than usual');
    });

    test('a negligible driver reads as about usual', () {
      final b = ReadinessService.parse(row())!;
      expect(b.drivers.firstWhere((d) => d.key == 'temp').direction,
          'about usual');
    });

    test('contributions sum to the composite z', () {
      // Definitional in the formula; if this drifts, the decomposition being
      // displayed no longer explains the score being displayed.
      final b = ReadinessService.parse(row())!;
      final sum = b.drivers.fold<double>(0, (a, d) => a + d.contribution);
      expect(sum, closeTo(b.compositeZ, 0.001));
    });

    test('labels are human, not internal shorthand', () {
      final b = ReadinessService.parse(row())!;
      expect(b.lead!.label, 'Resting heart rate');
    });
  });

  group('abstaining', () {
    test('no clinical block yields null, never a zero score', () {
      expect(
        ReadinessService.parse({'payload_json': '{}'}),
        isNull,
        reason: 'absent must not render as a readiness of 0',
      );
    });

    test('a score with no drivers still parses', () {
      final b = ReadinessService.parse(row(rc: {
        'value': {'score': 60.0, 'composite_z': 0.1, 'meaningful': false},
        'confidence': 0.3,
        'inputs_used': ['HRV'],
      }))!;
      expect(b.score, 60);
      expect(b.drivers, isEmpty);
      expect(b.meaningful, isFalse);
    });

    test('missing inputs are detectable so the UI can name them', () {
      final b = ReadinessService.parse(row(rc: {
        'value': {'score': 60.0, 'composite_z': 0.1, 'meaningful': true},
        'inputs_used': ['HRV', 'RHR'],
        'drivers': const [],
      }))!;
      final missing = [
        for (final i in ReadinessService.allInputs)
          if (!b.inputsUsed.contains(i)) i,
      ];
      expect(missing, ['RR', 'temp']);
    });

    test('the mean/SD fallback is flagged', () {
      final b = ReadinessService.parse(row(rc: {
        'value': {'score': 40.0, 'composite_z': -0.4, 'meaningful': true},
        'inputs_used': ['RHR'],
        'drivers': [
          {
            'label': 'RHR',
            'contribution': -0.4,
            'detail':
                'oriented z (mean+SD fallback — MAD=0 on a quantized baseline)'
                    '=-1.2',
          },
        ],
      }))!;
      expect(b.drivers.first.usedFallback, isTrue);
      expect(b.drivers.first.z, closeTo(-1.2, 0.001));
    });
  });
}
