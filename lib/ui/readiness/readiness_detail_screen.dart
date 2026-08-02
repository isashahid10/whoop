// Readiness breakdown - the same treatment sleep gets.
//
// Tapping the readiness ring used to open the coach, or an info sheet with one
// paragraph of prose. Meanwhile the score's full decomposition was already
// being computed and persisted and simply never shown.
//
// THE CENTRAL DESIGN DECISION is the diverging bar. Each input's contribution
// is signed: it either pushed readiness up or dragged it down. A conventional
// left-anchored bar can only show magnitude, so it would render "resting heart
// rate is three SD above your baseline" identically to "resting heart rate is
// three SD below it" - the exact distinction the whole screen exists to make.
// Bars therefore grow out from a centre line, right for good and left for bad.
//
// WHAT IS DELIBERATELY NOT CLAIMED. Contributions sum to the composite z by
// construction, so they are a decomposition, not a causal account. The screen
// says "contributed most" and never "caused".

import 'package:flutter/material.dart';

import '../../compute/readiness_service.dart';
import '../design/design.dart';

class ReadinessDetailScreen extends StatefulWidget {
  final String date;
  const ReadinessDetailScreen({super.key, required this.date});

  @override
  State<ReadinessDetailScreen> createState() => _ReadinessDetailScreenState();
}

class _ReadinessDetailScreenState extends State<ReadinessDetailScreen> {
  ReadinessBreakdown? _b;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await ReadinessService.forDay(widget.date);
    if (mounted) {
      setState(() {
        _b = b;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    return AppScaffold(
      title: 'Readiness',
      subtitle: 'What went into today\'s score',
      body: _loading
          ? Skeleton.tileRow(rows: 4)
          : b == null
              ? const StateCard(
                  icon: OsIcon.recovery,
                  title: 'No readiness score yet',
                  message:
                      'Readiness compares last night against your own rolling '
                      'baselines, so it needs a couple of weeks of nights '
                      'before it can say anything. Until then it abstains '
                      'rather than guessing.',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppColors.accent,
                  child: ListView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(
                        Sp.screen, Sp.x2, Sp.screen, Sp.x10),
                    children: [ReadinessBreakdownContent(breakdown: b)],
                  ),
                ),
    );
  }

}

/// The breakdown itself, with no scaffold and no async load.
///
/// Split out for the same reason SleepNightContent is: the render harness
/// photographs it directly against fixed data, so a design change can be
/// LOOKED AT rather than argued about.
class ReadinessBreakdownContent extends StatelessWidget {
  final ReadinessBreakdown breakdown;
  const ReadinessBreakdownContent({super.key, required this.breakdown});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _sections(breakdown),
      );

  List<Widget> _sections(ReadinessBreakdown b) => [
        _hero(b),
        const SizedBox(height: Sp.x4),
        const SectionHeader('What moved it'),
        _drivers(b),
        if (_missing(b).isNotEmpty) ...[
          const SizedBox(height: Sp.x4),
          _missingCard(b),
        ],
        const SizedBox(height: Sp.x4),
        _method(),
      ];

  List<String> _missing(ReadinessBreakdown b) => [
        for (final i in ReadinessService.allInputs)
          if (!b.inputsUsed.contains(i)) i,
      ];

  Widget _hero(ReadinessBreakdown b) {
    final score = b.score.round();
    final colour = AppColors.scoreColor(b.score / 100);
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$score', style: AppText.metric.copyWith(color: colour)),
                    const SizedBox(height: 2),
                    Text(
                      // The SWC gate is the honest headline. A score of 48 that
                      // sat inside your normal variation is not "slightly
                      // below average", it is indistinguishable from average.
                      b.meaningful
                          ? _verdict(b.score)
                          : 'Within your normal range',
                      style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              ArcGauge(
                value: (b.score / 100).clamp(0.0, 1.0),
                color: colour,
                size: 92,
                stroke: 9,
                sweepFraction: 0.75,
              ),
            ],
          ),
          if (b.lead != null) ...[
            const SizedBox(height: Sp.x4),
            Text(
              b.meaningful
                  ? '${b.lead!.label} contributed most, '
                      '${b.lead!.direction}.'
                  : 'Nothing today stood far enough outside your usual range '
                      'to move the score much.',
              style: AppText.captionMuted,
            ),
          ],
        ],
      ),
    );
  }

  static String _verdict(double s) {
    if (s >= 67) return 'Well recovered';
    if (s >= 34) return 'Moderately recovered';
    return 'Low recovery';
  }

  Widget _drivers(ReadinessBreakdown b) {
    if (b.drivers.isEmpty) {
      return const StateCard(
        icon: OsIcon.recovery,
        title: 'No breakdown available',
        message: 'The score exists but its inputs were not recorded.',
      );
    }
    // Scale every bar against the largest contribution so the biggest driver
    // fills the half-width. Absolute scaling would render a quiet night as
    // four invisible stubs.
    final maxAbs = b.drivers
        .map((d) => d.contribution.abs())
        .reduce((a, c) => a > c ? a : c);

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < b.drivers.length; i++) ...[
            if (i > 0) const SizedBox(height: Sp.x4),
            _driverRow(b.drivers[i], maxAbs),
          ],
        ],
      ),
    );
  }

  Widget _driverRow(ReadinessDriver d, double maxAbs) {
    final colour = d.helps ? AppColors.good : AppColors.bad;
    final frac = maxAbs <= 0 ? 0.0 : (d.contribution.abs() / maxAbs).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(d.label,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
            ),
            Text(
              d.direction,
              style: AppText.captionMuted.copyWith(color: colour),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        _divergingBar(frac, d.helps, colour),
        if (d.z != null) ...[
          const SizedBox(height: 4),
          Text(
            // The z is the actual quantity. Showing it keeps the screen a
            // glass box rather than a verdict with a decorative bar.
            '${d.z!.abs().toStringAsFixed(1)} SD '
            '${d.helps ? 'better' : 'worse'} than your baseline'
            '${d.usedFallback ? ' (mean/SD)' : ''}',
            style: AppText.captionMuted.copyWith(fontSize: 11),
          ),
        ],
      ],
    );
  }

  /// A bar growing out from a centre line: right when the input helped,
  /// left when it hurt. Magnitude alone cannot carry that sign.
  Widget _divergingBar(double frac, bool helps, Color colour) =>
      LayoutBuilder(
        builder: (context, c) {
          final half = c.maxWidth / 2;
          return SizedBox(
            height: 8,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Positioned(
                  left: helps ? half : half - half * frac,
                  width: half * frac,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colour,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                // The centre line is the reference the bars are read against,
                // so it stays visible under them.
                Positioned(
                  left: half - 0.5,
                  width: 1,
                  top: 0,
                  bottom: 0,
                  child: Container(color: AppColors.inkMuted),
                ),
              ],
            ),
          );
        },
      );

  Widget _missingCard(ReadinessBreakdown b) {
    final missing = _missing(b);
    String name(String k) => switch (k) {
          'HRV' => 'heart rate variability',
          'RHR' => 'resting heart rate',
          'RR' => 'breathing rate',
          'temp' => 'skin temperature',
          _ => k,
        };
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Not included today', style: AppText.title),
          const SizedBox(height: Sp.x2),
          Text(
            // Naming the absent inputs matters: the score was renormalised over
            // whatever was present, so a three-input score is a different
            // measurement from a four-input one and should not look identical.
            '${missing.map(name).join(', ')} '
            '${missing.length == 1 ? 'was' : 'were'} missing or had too short '
            'a baseline, so the remaining inputs were reweighted to fill the '
            'gap. Fewer inputs means a less certain score.',
            style: AppText.captionMuted,
          ),
        ],
      ),
    );
  }

  Widget _method() => SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('How this is worked out', style: AppText.title),
                const Spacer(),
                const InfoDot(
                  title: 'Readiness method',
                  body:
                      'Each input is compared against its own trailing '
                      'baseline as a robust z-score (median and MAD), then '
                      'oriented so positive always means better for '
                      'readiness, weighted, and renormalised over whichever '
                      'inputs were present. The weights are fixed and '
                      'disclosed: HRV 0.40, resting heart rate 0.30, '
                      'breathing rate 0.20, skin temperature 0.10.\n\n'
                      'The contributions add up to the composite score by '
                      'construction. That makes them a decomposition of the '
                      'formula, NOT a statement of cause: "resting heart rate '
                      'contributed most" means the arithmetic breaks down that '
                      'way, not that your heart rate caused the rest.\n\n'
                      'When the composite sits inside your own normal '
                      'variation the score is reported as flat rather than '
                      'dressed up as a small change.',
                  methodNote: 'Robust z vs personal rolling baselines, '
                      'SWC-gated.',
                ),
              ],
            ),
            const SizedBox(height: Sp.x2),
            Text(
              'Everything here is measured against YOUR baselines, not a '
              'population average. That is why it needs a couple of weeks '
              'before it says anything.',
              style: AppText.captionMuted,
            ),
          ],
        ),
      );
}
