// Disclosure — progressive-disclosure wrapper for the acronym-heavy raw
// numbers (LF/HF, SD1/SD2, pNN, breathing variance…) that used to sit
// permanently visible on the Heart detail screens with only a caps-lock 3-4
// letter label to explain them. Collapsed by default, showing only a
// plain-language [summary] line; the raw detail expands on tap. This SHRINKS
// a screen's resting scroll height (detail is opt-in) instead of growing it.
//
//   Disclosure(
//     summary: 'Rhythm looks typical for you.',
//     child: Column(children: [ /* SDNN, LF/HF, HRV stability rows */ ]),
//   )
//
// [summaryWidget] overrides the plain-text summary line with a richer widget
// (e.g. the Sleep Coach card's "need" line + its percentage ring together) —
// [summary] still doubles as its semantic label in that case, so callers
// don't lose the honest one-liner as an a11y string.

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon;
import '../kit/os_icons.dart';
import 'pressable.dart';

class Disclosure extends StatefulWidget {
  /// The plain-language line shown when collapsed (default state) — this is
  /// what most readers see; the raw numbers are opt-in. Also used as the
  /// Semantics label when [summaryWidget] is given instead of plain text.
  final String summary;

  /// Optional richer collapsed-state content (e.g. a ring beside the text) —
  /// replaces the plain [summary] Text when given, sitting in the exact same
  /// row next to the expand/collapse affordance.
  final Widget? summaryWidget;

  /// The detail content, revealed on tap.
  final Widget child;
  final String expandLabel;
  final String collapseLabel;

  /// Start expanded (rare — most callers want collapsed-by-default).
  final bool initiallyExpanded;

  const Disclosure({
    super.key,
    required this.summary,
    this.summaryWidget,
    required this.child,
    this.expandLabel = 'Show detail',
    this.collapseLabel = 'Hide detail',
    this.initiallyExpanded = false,
  });

  @override
  State<Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<Disclosure> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Pressable(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: widget.summaryWidget != null
                    ? Semantics(
                        label: widget.summary,
                        container: true,
                        excludeSemantics: true,
                        child: widget.summaryWidget,
                      )
                    : Text(widget.summary, style: AppText.bodySoft),
              ),
              const SizedBox(width: Sp.x2),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _expanded ? widget.collapseLabel : widget.expandLabel,
                      style: AppText.captionMuted.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 2),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: reduceMotion ? Duration.zero : Motion.fast,
                      child: AppIcon(
                        OsIcon.down,
                        size: 14,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // A zero-duration AnimatedSize trips a Flutter layout assertion
        // (RenderAnimatedSize mutated during its own performLayout) — so
        // reduced motion doesn't "animate instantly", it skips the animated
        // wrapper entirely and just shows/hides the target size directly.
        if (reduceMotion)
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(top: Sp.x2),
              child: widget.child,
            )
          else
            const SizedBox(width: double.infinity)
        else
          AnimatedSize(
            duration: Motion.med,
            curve: Motion.curve,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: Sp.x2),
                    child: widget.child,
                  )
                : const SizedBox(width: double.infinity),
          ),
      ],
    );
  }
}
