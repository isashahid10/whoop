// MedalCard — an inverted (ink) achievement card with an engraved medal disc:
// personal records, streak milestones. Restrained metal, no confetti.
//
// This file also held RecapCard (a headline period recap with a bar strip).
// The recap screen builds its own composition, so RecapCard never had a call
// site outside the gallery and was removed.

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show AppIcon, OsIcon;
import 'bento.dart';

/// An inverted achievement card with an engraved medal disc.
class MedalCard extends StatelessWidget {
  /// Engraving on the medal ('5K', '30d', 'PR').
  final String medal;

  /// 'Personal record', 'Achievement'…
  final String overline;

  /// 'Fastest 5k — 24:31'.
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  const MedalCard({
    super.key,
    required this.medal,
    required this.title,
    this.overline = 'Achievement',
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return BentoTile(
      tone: BentoTone.ink,
      padding: const EdgeInsets.all(Sp.x4),
      onTap: onTap,
      child: Row(
        children: [
          _MedalDisc(medal),
          const SizedBox(width: Sp.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  overline.toUpperCase(),
                  style: AppText.overline.copyWith(
                    color: AppColors.onNightSoft,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  title,
                  style: AppText.title.copyWith(color: AppColors.onNight),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: AppText.caption.copyWith(
                      color: AppColors.onNightSoft,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (onTap != null)
            AppIcon(OsIcon.arrowRight, size: 15, color: AppColors.onNightSoft),
        ],
      ),
    );
  }
}

class _MedalDisc extends StatelessWidget {
  final String text;
  const _MedalDisc(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFD8D4CC), Color(0xFF908B82), Color(0xFFC5C0B7)],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(3),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFB9B4AA), Color(0xFF7E7A72)],
          ),
        ),
        child: Center(
          child: Text(
            text,
            style: AppText.metricSm.copyWith(
              fontSize: 16,
              color: const Color(0xFF2E2B26),
              letterSpacing: -0.2,
            ),
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}
