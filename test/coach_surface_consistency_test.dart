// The coach's DATA SURFACE has to stay consistent across three places that
// drift apart silently:
//
//   1. `db.dart`            - which views actually get CREATEd
//   2. `CoachDb.allowedViews` - which views the SQL guard permits
//   3. `coach_prompt.dart`  - which views the model is TOLD about
//
// Every pairing fails differently, and none of them fails loudly:
//
//   * created but not allow-listed → the guard rejects a view that exists; the
//     model retries, burns turns, and eventually gives up.
//   * allow-listed but not created → a confusing SQL error at runtime.
//   * allow-listed but not in the prompt → THE SILENT ONE. The model never
//     learns the view exists, so it never queries it and simply answers as if
//     the data were not there. This is exactly what happened to `v_lifts` and
//     `v_lift_sessions`: the lifting data was queryable the whole time and the
//     coach could not see it, which quietly broke the single question this
//     fork exists to answer ("am I recovered enough to go heavy today?").
//
// These are cheap string assertions over the real sources, which is the only
// way to catch drift that no runtime path exercises.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_db.dart';
import 'package:openstrap_edge/coach/coach_prompt.dart';

/// View names appearing in a `CREATE VIEW` in db.dart.
Set<String> _createdViews() {
  final src = File('lib/data/db.dart').readAsStringSync();
  return RegExp(r'CREATE\s+VIEW\s+(v_[a-z_]+)', caseSensitive: false)
      .allMatches(src)
      .map((m) => m.group(1)!)
      .toSet();
}

/// View names the prompt DOCUMENTS - i.e. introduces as a queryable surface at
/// the start of a line, not merely mentions in prose.
Set<String> _documentedViews() {
  return RegExp(r'^-\s*(v_[a-z_]+)\(', multiLine: true)
      .allMatches(kCoachSystemPrompt)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  group('coach data surface', () {
    test('every allow-listed view actually exists in the schema', () {
      final created = _createdViews();
      final missing = CoachDb.allowedViews.difference(created);
      expect(missing, isEmpty,
          reason: 'allow-listed but never CREATEd - the coach will hit a raw '
              'SQL error when it tries these: $missing');
    });

    test('every created v_ view is allow-listed', () {
      final created = _createdViews();
      final unreachable = created.difference(CoachDb.allowedViews);
      expect(unreachable, isEmpty,
          reason: 'created but not allow-listed, so the guard rejects them and '
              'the data is unreachable: $unreachable');
    });

    test('every allow-listed view is DOCUMENTED in the system prompt', () {
      final documented = _documentedViews();
      final invisible = CoachDb.allowedViews.difference(documented);
      expect(invisible, isEmpty,
          reason: 'queryable but undocumented - the model never learns these '
              'exist and will answer as if the data were absent: $invisible');
    });

    test('the prompt does not advertise a view the guard would reject', () {
      final documented = _documentedViews();
      final phantom = documented.difference(CoachDb.allowedViews);
      expect(phantom, isEmpty,
          reason: 'documented but not allow-listed - the model will write '
              'queries the guard rejects: $phantom');
    });

    test('the lifting views are on the surface - this fork exists for them',
        () {
      // Pinned by name rather than left to the set comparisons above: these
      // two are the whole reason for the fork, and a future tidy-up that drops
      // them would otherwise only show up as a coach that has quietly stopped
      // knowing about training.
      for (final v in ['v_lifts', 'v_lift_sessions']) {
        expect(CoachDb.allowedViews, contains(v));
        expect(_documentedViews(), contains(v));
      }
    });

    test('the sleep score is on the surface, with its abstention explained',
        () {
      expect(kCoachSystemPrompt, contains('sleep_score'));
      // A null score means "not measurable", NOT "bad night". If the prompt
      // ever stops saying so, the model will read a missing score as a zero
      // and tell the user they slept terribly on a night it simply could not
      // measure.
      expect(kCoachSystemPrompt.toLowerCase(), contains('abstention'));
    });
  });
}
