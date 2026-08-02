// correlation_card.dart — what actually moves your numbers.
//
// The presentation problem here is credibility. These are statistical findings
// over a small personal sample, and the temptation is to render them like
// facts. Three rules push the other way:
//
//   * ASSOCIATION LANGUAGE ONLY. "Days with more protein tend to show higher
//     readiness the next day" — never "protein improves your recovery". The
//     engine cannot see confounders and does not pretend to.
//   * SAMPLE SIZE IS ALWAYS ON SCREEN. n=15 and n=90 are different claims and
//     must not look alike.
//   * NOTHING FOUND IS A RESULT. An empty list gets a sentence explaining that
//     the tests ran and came back clean, not a shrug. With enough days, "no
//     effect detected" is real information about your physiology.

import 'package:flutter/material.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../../compute/correlation_service.dart';
import '../design/design.dart';

class CorrelationCard extends StatefulWidget {
  const CorrelationCard({super.key});

  @override
  State<CorrelationCard> createState() => _CorrelationCardState();
}

class _CorrelationCardState extends State<CorrelationCard> {
  ana.CorrelationReport? _report;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await CorrelationService.analyse();
    if (mounted) setState(() { _report = r; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final r = _report;
    if (r == null) return const SizedBox.shrink();

    final findings = r.findings;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('WHAT MOVES YOUR NUMBERS',
                  style: AppText.overline
                      .copyWith(color: AppColors.inkSoft, letterSpacing: 1.1)),
              const Spacer(),
              InfoDot(
                title: 'What moves your numbers',
                body: 'Every relationship here is tested against YOUR data '
                    'only - nothing is assumed from population averages.\n\n'
                    'Rank (Spearman) correlation, because these series are '
                    'small, non-normal and full of outliers: one enormous meal '
                    'or one three-hour night would drag an ordinary '
                    'correlation around.\n\n'
                    'Testing many relationships at once creates false '
                    'positives by construction - check 30 pairs at the usual '
                    'threshold and about 1.5 will look "significant" by pure '
                    'chance. A Benjamini-Hochberg correction is applied across '
                    'the whole family, so what survives has cleared a much '
                    'higher bar than a single test would.\n\n'
                    'Nothing is reported below 14 paired days, and days are '
                    'only paired when they are genuinely adjacent on the '
                    'calendar.\n\n'
                    'These are ASSOCIATIONS. Where the mechanism is overnight '
                    'the predictor is measured against the FOLLOWING day, '
                    'which rules out the arrow pointing backwards - it does '
                    'not rule out a common cause.',
                methodNote: r.basis,
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          if (findings.isEmpty)
            Text(r.basis, style: AppText.bodySoft)
          else ...[
            for (var i = 0; i < findings.length; i++) ...[
              if (i > 0) ...[
                const SizedBox(height: Sp.x2),
                Divider(height: 1, thickness: 1, color: AppColors.divider),
                const SizedBox(height: Sp.x2),
              ],
              _finding(findings[i]),
            ],
            const SizedBox(height: Sp.x3),
            Text(r.basis, style: AppText.captionMuted),
          ],
        ],
      ),
    );
  }

  Widget _finding(ana.Correlation c) {
    // Direction is the signal, so it gets the colour: a positive association
    // with a good outcome is green, a negative one is the warning colour.
    final positive = c.rho > 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          positive ? Icons.trending_up_rounded : Icons.trending_down_rounded,
          size: 18,
          color: positive ? AppColors.good : AppColors.warn,
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(c.sentence, style: AppText.body),
              const SizedBox(height: 2),
              Text(
                // Strength and sample size together — n is what separates a
                // real finding from an accident, so it is never hidden.
                '${c.strength} association · ${c.n} days',
                style: AppText.captionMuted,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
