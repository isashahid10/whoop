// The bottom navigation bar.
//
// REWRITTEN from a floating, illustrated pill to a flat monochrome bar.
//
// The previous version rendered each tab as a full-colour 40 px illustration
// inside a lifted, rounded, shadowed lozenge. Two things were wrong with it for
// this app:
//
//   * FIVE COMPETING HUES AT THE BOTTOM OF EVERY SCREEN. Colour in this app is
//     supposed to mean something — green is recovered, blue is exertion, red is
//     don't. A permanently-visible row of purple/red/yellow/orange art spends
//     that vocabulary on chrome, and once the chrome is colourful the data
//     stops being the loudest thing on screen.
//   * IT LOOKED LIKE A TOY. Lifted pill, drop shadow, illustrated glyphs — that
//     is a lifestyle-app idiom. A performance tool wants the navigation to
//     disappear.
//
// So: flat, edge-to-edge, sitting on the page colour with a hairline above it.
// Monochrome line icons. Labels ALWAYS visible rather than only on the selected
// tab — a label that appears and disappears makes the row reflow on every tap,
// and five short words cost nothing. Selection is white icon + white label
// against muted grey, which is the whole of the active state.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon;
import '../kit/os_icons.dart';

class NavPillItem {
  final OsIcon icon;
  final String label;
  const NavPillItem(this.icon, this.label);
}

class FloatingNavPill extends StatelessWidget {
  final List<NavPillItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  /// Optional centre action. Unused by the app shell and kept only so existing
  /// call sites keep compiling.
  final Widget? centerAction;

  const FloatingNavPill({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
    this.centerAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        // A hairline, not a shadow. The bar is part of the page, not floating
        // above it, and a shadow on a pure-black ground is invisible anyway.
        border: Border(top: BorderSide(color: AppColors.divider, width: 0.5)),
      ),
      // No SafeArea here — the app shell already wraps this in one, and
      // nesting them adds the home-indicator inset twice.
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: _Tab(
                  item: items[i],
                  selected: i == index,
                  onTap: () {
                    if (i != index) HapticFeedback.selectionClick();
                    onSelect(i);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final NavPillItem item;
  final bool selected;
  final VoidCallback onTap;

  const _Tab({required this.item, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // White when active, mid-grey otherwise. No accent hue: the nav is chrome,
    // and a coloured active tab would read as a status.
    final color = selected ? AppColors.ink : AppColors.inkMuted;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // AppIcon, not OsAppIcon: the latter draws the full-colour
          // illustration, which cannot be tinted and is what made the old bar
          // a row of five competing hues.
          AppIcon(item.icon, size: 22, color: color),
          const SizedBox(height: 3),
          Text(
            item.label,
            style: AppText.caption.copyWith(
              color: color,
              fontSize: 10,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
