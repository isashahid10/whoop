// State chips — the calm pill vocabulary: emoji-or-icon + word, soft accent
// fill when on, never a colour explosion.
//
//  • [StateChipView] — ONE pill. Display-only (no onTap) or interactive.
//    The Today readiness ring puts one under the score ('Push' / 'Focus' /
//    'Recover'), tinted with the score colour.
//  • [ToggleChip] — an independent on/off pill for multi-select rows
//    (journal tags, cycle symptoms, notification kinds), painted from
//    [StateChipView]'s tokens so both stay one look.
//
// There used to be a single-select `StateChips` row here too. Nothing in the
// app single-selects a chip row (journal/cycle/profile all multi-select via
// ToggleChip), so it was removed rather than kept as gallery-only scaffolding
// — a Wrap of [StateChipView]s is the same thing in six lines if it's ever
// wanted back.

import 'package:flutter/material.dart';
import '../kit/os_icons.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon;
import 'pressable.dart';

class StateChip {
  final String label;
  final String? emoji;
  final OsIcon? icon;
  const StateChip(this.label, {this.emoji, this.icon});
}

/// Soft fill for a chip in its ON state. With no [accent] this is the brand
/// accent-soft token; with one, the accent is blended into the surface so a
/// domain- or score-tinted chip reads as the same material, not as a second
/// colour system.
Color _chipFill(Color? accent) => accent == null
    ? AppColors.accentSoft
    : Color.alphaBlend(
        accent.withValues(alpha: AppColors.isDark ? 0.18 : 0.13),
        Elevation.surfaceAt(1),
      );

/// Ink for a chip in its ON state — the readable on-accent token by default,
/// the accent itself when the caller tinted the chip.
Color _chipInk(Color? accent) => accent ?? AppColors.onAccentSoft;

/// StateChipView — ONE calm pill: icon/emoji + word, soft accent fill when on.
///
/// The single shared renderer behind every chip in the system, [ToggleChip]
/// included. Pass [onTap] for an interactive chip; leave it null for a
/// display-only badge (the Today readiness ring's status word).
class StateChipView extends StatelessWidget {
  final StateChip chip;
  final bool selected;
  final Color? accent;
  final VoidCallback? onTap;

  /// Slightly tighter padding for chips that sit inside a constrained
  /// container (e.g. within the readiness ring).
  final bool dense;

  const StateChipView(
    this.chip, {
    super.key,
    this.selected = false,
    this.accent,
    this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final a = accent ?? AppColors.accent;
    final ink = selected ? _chipInk(accent) : AppColors.inkSoft;
    return Pressable(
      pressedScale: 0.94,
      borderRadius: BorderRadius.circular(R.pill),
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: EdgeInsets.symmetric(
          horizontal: dense ? Sp.x2 + 2 : Sp.x3 + 2,
          vertical: dense ? 5 : 8,
        ),
        decoration: BoxDecoration(
          color: selected ? _chipFill(accent) : Elevation.surfaceAt(1),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
            color: selected ? a.withValues(alpha: 0.55) : AppColors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (chip.emoji != null) ...[
              Text(chip.emoji!, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: Sp.x1 + 2),
            ] else if (chip.icon != null) ...[
              AppIcon(chip.icon!, size: dense ? 13 : 14, color: ink),
              const SizedBox(width: Sp.x1 + 2),
            ],
            Text(
              chip.label,
              style: AppText.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ToggleChip — the multi-select pill: one independent on/off chip (journal
/// tags, cycle symptoms). Soft accent fill + tinted hairline when on; calm
/// surface otherwise. Same tokens as [StateChipView], label-only (no glyph).
class ToggleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// Domain accent; defaults to the brand accent (soft fill + accent ink).
  final Color? accent;

  const ToggleChip(
    this.label, {
    super.key,
    required this.selected,
    this.onTap,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final a = accent ?? AppColors.accent;
    return Pressable(
      pressedScale: 0.94,
      borderRadius: BorderRadius.circular(R.pill),
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: selected ? _chipFill(accent) : Elevation.surfaceAt(1),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(
            color: selected ? a.withValues(alpha: 0.55) : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: AppText.label.copyWith(
            color: selected ? _chipInk(accent) : AppColors.inkSoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
