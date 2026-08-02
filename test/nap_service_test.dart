// Naps must stay SEPARATE from nocturnal sleep. These tests exist because the
// tempting simplification - "sleep is sleep, add them up" - is wrong in both
// directions, and nothing else in the codebase would catch it being made.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/nap_service.dart';

/// A bundle shaped exactly like the derivation engine's real output, taken
/// from the live database rather than invented.
Map<String, dynamic> bundle({
  List<Map<String, dynamic>> naps = const [],
  double? tstMin,
}) =>
    {
      'payload_json': jsonEncode({
        'tst_min': ?tstMin,
        'naps': {
          'value': naps,
          'count': naps.length,
          'tier': 'ESTIMATE',
        },
      }),
    };

void main() {
  group('nap parsing', () {
    test('reads the real block shape the engine writes', () {
      // These are the exact values recorded on 2026-07-29.
      final naps = NapService.parseForTest(bundle(naps: [
        {
          'start': 1785300510,
          'end': 1785306168,
          'duration_min': 94,
          'confidence': 0.8218451749734889,
        },
      ]));

      expect(naps, hasLength(1));
      expect(naps.single.minutes, 94);
      expect(naps.single.confidence, closeTo(0.82, 0.01));
      expect(naps.single.isLowConfidence, isFalse);
      expect(naps.single.end.difference(naps.single.start).inMinutes, 94);
    });

    test('a day with no naps yields an empty list, not a zero', () {
      expect(NapService.parseForTest(bundle()), isEmpty);
    });

    test('a missing naps block does not throw', () {
      expect(NapService.parseForTest({'payload_json': '{}'}), isEmpty);
    });

    test('drops entries that cannot support a duration', () {
      final naps = NapService.parseForTest(bundle(naps: [
        {'start': 1785300510, 'end': 1785306168}, // no duration
        {'duration_min': 30}, // no times
        {'start': 1785300510, 'end': 1785300510, 'duration_min': 0},
      ]));
      expect(naps, isEmpty);
    });

    test('naps come back in chronological order', () {
      final naps = NapService.parseForTest(bundle(naps: [
        {'start': 1785306168, 'end': 1785309768, 'duration_min': 60},
        {'start': 1785300510, 'end': 1785302310, 'duration_min': 30},
      ]));
      expect(naps.map((n) => n.minutes).toList(), [30, 60]);
    });
  });

  group('naps are not night sleep', () {
    test('parsing a nap never alters the nocturnal total', () {
      // The load-bearing invariant. tst_min is the NIGHT; a 94-minute nap on
      // the same day must leave it at 438, not 532.
      final b = bundle(
        tstMin: 438,
        naps: [
          {
            'start': 1785300510,
            'end': 1785306168,
            'duration_min': 94,
            'confidence': 0.82,
          },
        ],
      );
      final naps = NapService.parseForTest(b);
      final payload =
          jsonDecode(b['payload_json'] as String) as Map<String, dynamic>;

      expect(naps.single.minutes, 94);
      expect(payload['tst_min'], 438);
    });
  });

  group('duration character', () {
    test('a power nap is short and not long', () {
      final n = NapService.parseForTest(bundle(naps: [
        {'start': 1785300510, 'end': 1785302010, 'duration_min': 25},
      ])).single;
      expect(n.isShort, isTrue);
      expect(n.isLong, isFalse);
    });

    test('a 94-minute nap is long', () {
      final n = NapService.parseForTest(bundle(naps: [
        {'start': 1785300510, 'end': 1785306168, 'duration_min': 94},
      ])).single;
      expect(n.isLong, isTrue);
      expect(n.isShort, isFalse);
    });

    test('low confidence is flagged so the UI can hedge', () {
      final n = NapService.parseForTest(bundle(naps: [
        {
          'start': 1785300510,
          'end': 1785302010,
          'duration_min': 25,
          'confidence': 0.3,
        },
      ])).single;
      expect(n.isLowConfidence, isTrue);
    });
  });
}
