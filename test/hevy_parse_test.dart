// Hevy JSON parsing must tolerate loose field types.
//
// This is an UNDOCUMENTED API and its field types are not stable. Hard
// `as String?` casts threw on real data - "type 'int' is not a subtype of type
// 'String?'" - killing an entire sync mid-import. `superset_id` in particular
// comes back numeric, but any of these fields could.
//
// These tests pin the tolerant behaviour so a later "tidy up" back to hard
// casts fails here rather than on device, halfway through someone's history.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/integrations/hevy_client.dart';

void main() {
  test('numeric superset_id does not blow up the parse', () {
    final ex = HevyExercise.fromJson({
      'title': 'Bench Press (Barbell)',
      'superset_id': 3, // int, NOT a string - the real-world crash
      'exercise_template_id': 12345, // also seen numeric
      'sets': [
        {'index': 0, 'weight_kg': 100, 'reps': 5, 'indicator': 'normal'},
      ],
    });
    expect(ex.title, 'Bench Press (Barbell)');
    expect(ex.supersetId, '3');
    expect(ex.templateId, '12345');
    expect(ex.sets.single.weightKg, 100.0);
  });

  test('missing and null fields fall back instead of throwing', () {
    final ex = HevyExercise.fromJson({'sets': []});
    expect(ex.title, 'Unknown');
    expect(ex.supersetId, isNull);
    expect(ex.notes, '');
    expect(ex.sets, isEmpty);
  });

  test('a workout with odd scalar types still parses', () {
    final w = HevyWorkout.fromJson({
      'id': 987, // numeric id
      'index': 100,
      'name': 42, // numeric name
      'description': null,
      'start_time': 1785200000,
      'end_time': 1785203600,
      'exercises': [
        {
          'title': 'Squat (Barbell)',
          'sets': [
            {'index': 0, 'weight_kg': 100, 'reps': 5},
            {'index': 1, 'weight_kg': 100, 'reps': 5},
          ],
        },
      ],
    });
    expect(w.id, '987');
    expect(w.name, '42');
    expect(w.description, '');
    expect(w.setCount, 2);
    expect(w.totalVolumeKg, 1000.0);
    expect(w.duration.inMinutes, 60);
  });

  test('a bodyweight set contributes NULL volume, never 0', () {
    // 0 would silently drag a volume average down; null abstains.
    final s = HevySet.fromJson({'index': 0, 'reps': 12, 'indicator': 'normal'});
    expect(s.reps, 12);
    expect(s.weightKg, isNull);
    expect(s.volumeKg, isNull);
  });

  test('string numbers do not become garbage volume', () {
    // If the API ever sends "100" instead of 100, better to abstain than to
    // fabricate a number from a type we did not expect.
    final s = HevySet.fromJson({'index': 0, 'weight_kg': '100', 'reps': 5});
    expect(s.weightKg, isNull);
    expect(s.volumeKg, isNull);
  });
}
