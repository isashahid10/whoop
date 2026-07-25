// Widget tests for Disclosure (lib/ui/design/disclosure.dart) — the
// progressive-disclosure primitive reused this session for LF/HF, SD1/SD2,
// the ring-adjacent AI insight, and (this test's reason for existing) the
// Sleep Coach card's collapsible "need + ring" summary.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/design/disclosure.dart';

Widget _host(Widget child) {
  AppColors.active = kLightPalette;
  return MaterialApp(
    theme: buildOpenStrapTheme(kLightPalette),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  testWidgets(
      'collapsed by default: plain-text summary shows, child is hidden, tap '
      'reveals it and tap again hides it', (t) async {
    await t.pumpWidget(_host(Disclosure(
      summary: 'Rhythm looks typical for you.',
      child: const Text('SDNN 61 ms'),
    )));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Rhythm looks typical for you.'), findsOneWidget);
    expect(find.text('SDNN 61 ms'), findsNothing);
    expect(find.text('Show detail'), findsOneWidget);

    await t.tap(find.text('Rhythm looks typical for you.'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('SDNN 61 ms'), findsOneWidget);
    expect(find.text('Hide detail'), findsOneWidget);

    await t.tap(find.text('Rhythm looks typical for you.'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('SDNN 61 ms'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'summaryWidget overrides the plain-text summary (Sleep Coach\'s '
      'need+ring collapsed state) while still carrying summary as its a11y '
      'label', (t) async {
    // Semantics finders need an active handle — off by default in tests.
    final handle = t.ensureSemantics();
    await t.pumpWidget(_host(Disclosure(
      summary: 'Tonight you need 9h 5m · 100% of need',
      summaryWidget: const Row(
        children: [Text('9h 5m'), Text('100%')],
      ),
      expandLabel: 'Bedtime & alarm',
      child: const Text('Set band alarm for 07:55'),
    )));
    await t.pump(const Duration(milliseconds: 400));
    // The rich widget renders instead of the plain summary string…
    expect(find.text('9h 5m'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('Tonight you need 9h 5m · 100% of need'), findsNothing);
    // …but is still reachable as a Semantics label for accessibility.
    expect(
      find.bySemanticsLabel('Tonight you need 9h 5m · 100% of need'),
      findsOneWidget,
    );
    // Detail (the alarm CTA) is collapsed until tapped.
    expect(find.text('Set band alarm for 07:55'), findsNothing);
    expect(find.text('Bedtime & alarm'), findsOneWidget);

    await t.tap(find.text('9h 5m'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Set band alarm for 07:55'), findsOneWidget);
    expect(t.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('reduced motion skips the expand animation but still expands',
      (t) async {
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _host(Disclosure(
          summary: 'Collapsed line.',
          child: const Text('Detail line.'),
        )),
      ),
    );
    await t.pump();
    expect(find.text('Detail line.'), findsNothing);
    await t.tap(find.text('Collapsed line.'));
    await t.pump();
    expect(find.text('Detail line.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
