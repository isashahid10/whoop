// Strength analysis — the cross-workout view.
//
// The per-workout screen already shows what you did. This shows what it ADDS
// UP TO: whether each lift is actually moving, how much weekly volume each
// muscle gets, and how the last week's tonnage compares with the last month's.
//
// Two presentation rules, both load-bearing:
//
//   * An estimated 1RM is labelled ESTIMATED, always. It comes from a formula
//     applied to a submaximal set, not from a max attempt, and the moment it
//     stops being labelled it starts being mistaken for one.
//   * A trend that is not meaningful gets no arrow and no adjective. Two
//     sessions or a 0.05 kg/week drift is noise; drawing an arrow on it
//     invents a story the data does not tell.

import 'package:flutter/material.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../../compute/strength_service.dart';
import '../../compute/training_insights.dart';
import 'training_cards.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../design/design.dart';
import 'rest_timer.dart';

class StrengthContent extends StatefulWidget {
  const StrengthContent({super.key});

  @override
  State<StrengthContent> createState() => _StrengthContentState();
}

class _StrengthContentState extends State<StrengthContent> {
  ana.StrengthSummary? _summary;
  TrainingInsights? _insights;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final s = await StrengthService.summary();
      final i = await TrainingInsightsService.load();
      if (mounted) {
        setState(() {
          _summary = s;
          _insights = i;
        });
      }
    } catch (_) {
      // A failed read means no analysis, which the empty state handles. It
      // must never mean a screen of confident zeroes.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _kg(double v) => v >= 100
      ? v.round().toString()
      : v.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');

  @override
  Widget build(BuildContext context) {
    if (_loading) return Skeleton.tileRow(rows: 4);

    final s = _summary;
    if (s == null || s.workingSets == 0) {
      return const StateCard(
        icon: OsIcon.strength,
        title: 'No lifts yet',
        message: 'Sync Hevy from Profile and your sets will be analysed here.',
      );
    }

    final insights = _insights;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Verdicts first, evidence below. Someone opening this tab wants "is
        // it working" before they want a table of slopes.
        // Rest timer. Lives at the top of Strength because it is the one
        // thing here you reach for DURING a session, and hunting for it
        // between sets defeats the point.
        _restTimerButton(context),
        const SizedBox(height: Sp.x4),
        if (insights != null) ...[
          OverreachingCard(signal: insights.overreaching),
          const SizedBox(height: Sp.x3),
          BulkQualityCard(bulk: insights.bulk),
          const SizedBox(height: Sp.x4),
        ],
        _tonnageCard(s),
        const SizedBox(height: Sp.x4),
        const SectionHeader('Progression'),
        _progressionCard(s),
        const SizedBox(height: Sp.x4),
        const SectionHeader('Weekly sets per muscle'),
        _volumeCard(s),
      ],
    );
  }

  /// Opens the HR-recovery rest timer with this user's own reserve bounds.
  Widget _restTimerButton(BuildContext context) {
    final app = context.read<AppState>();
    final connected = app.isConnected;
    return Pressable(
      onTap: connected
          ? () => showRestTimer(
                context,
                // restingHr is left null on purpose: the timer loads the
                // user's own median resting HR from their recent nights, which
                // is a better source than anything reachable synchronously
                // here.
                maxHr: app.maxHr,
              )
          : null,
      borderRadius: BorderRadius.circular(R.card),
      child: SurfaceCard(
        child: Row(
          children: [
            AppIcon(OsIcon.heart, size: 20, color: DomainAccent.heart),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Rest timer',
                      style:
                          AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    connected
                        ? 'Rest until your heart rate comes back down'
                        : 'Connect your band to use this',
                    style: AppText.captionMuted,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20,
                color: connected ? AppColors.inkSoft : AppColors.inkMuted),
          ],
        ),
      ),
    );
  }

  // ── tonnage ────────────────────────────────────────────────────────────────

  Widget _tonnageCard(ana.StrengthSummary s) {
    final t = s.tonnage;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Training load', style: AppText.title),
              const Spacer(),
              InfoDot(
                title: 'Training load',
                body:
                    'Mean daily tonnage (weight × reps) over the last 7 '
                    'days against the last 28.\n\n'
                    'This is a DESCRIPTION of how the recent week compares '
                    'with the recent month. It is deliberately not a risk '
                    'score: the acute:chronic injury-risk framing has been '
                    'seriously challenged on statistical grounds (Lolli '
                    '2019; Impellizzeri 2020), and was built for team-sport '
                    'GPS load rather than barbell tonnage.',
                methodNote:
                    '${t.chronicSessionDays} training days in the '
                    'last 28',
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Row(
            children: [
              _stat('${_kg(t.acuteDaily)} kg', 'last 7 days, daily avg'),
              _stat('${_kg(t.chronicDaily)} kg', 'last 28 days, daily avg'),
              _stat(
                // Without a real base the ratio is arithmetic on noise, so it
                // is withheld rather than shown with a caveat nobody reads.
                t.hasBase ? t.ratio!.toStringAsFixed(2) : '—',
                t.hasBase ? 'recent vs usual' : 'needs more history',
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Text(
            '${s.workingSets} working sets in the last ${s.windowDays} days',
            style: AppText.captionMuted,
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppText.metricSm),
        const SizedBox(height: 2),
        Text(label, style: AppText.captionMuted),
      ],
    ),
  );

  // ── progression ────────────────────────────────────────────────────────────

  Widget _progressionCard(ana.StrengthSummary s) {
    // Only exercises with an estimable max appear at all. A plank has no 1RM,
    // and listing it with a dash would imply the number is merely missing.
    final rows = [
      for (final p in s.progress)
        if (p.currentKg != null) p,
    ];
    if (rows.isEmpty) {
      return SurfaceCard(
        child: Text(
          'No lift here has a load and rep count in the range a one-rep-max '
          'estimate can be made from (12 reps or fewer).',
          style: AppText.captionMuted,
        ),
      );
    }

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Estimated 1RM', style: AppText.captionMuted),
              const Spacer(),
              InfoDot(
                title: 'Estimated 1RM',
                body:
                    'Your one-rep max PROJECTED from the sets you '
                    'actually did - you never had to attempt a true max.\n\n'
                    'It averages the Epley (1985) and Brzycki (1993) '
                    'formulas, which validation work (LeSuer 1997) found '
                    'accurate within a few percent at low reps and '
                    'progressively worse as reps climb. Above 12 reps no '
                    'estimate is made at all.\n\n'
                    'Where you logged an RPE, reps-in-reserve (10 − RPE) is '
                    'added first, so a set left short of failure is '
                    'projected to its true rep max rather than treated as '
                    'maximal.\n\n'
                    'The trend is a Theil-Sen slope, which ignores the odd '
                    'bad session instead of being dragged by it.',
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: Sp.x2),
              Divider(height: 1, thickness: 1, color: AppColors.divider),
              const SizedBox(height: Sp.x2),
            ],
            _progressRow(rows[i]),
          ],
        ],
      ),
    );
  }

  Widget _progressRow(ana.ExerciseProgress p) {
    final slope = p.slopeKgPerWeek;
    final up = p.trendMeaningful && slope! > 0;
    final down = p.trendMeaningful && slope! < 0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                p.exercise,
                style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                p.trendMeaningful
                    ? '${slope!.abs().toStringAsFixed(1)} kg/week '
                          '${up ? 'up' : 'down'} · ${p.sessions} sessions'
                    // Not "flat" — the honest statement is that there is not
                    // enough here to call a direction, which is different.
                    : '${p.sessions} session${p.sessions == 1 ? '' : 's'} · '
                          'no clear trend yet',
                style: AppText.captionMuted,
              ),
            ],
          ),
        ),
        if (p.e1rmSeries.length >= 3) ...[
          SizedBox(
            width: 64,
            child: Sparkline(
              p.e1rmSeries,
              height: 24,
              color: up
                  ? AppColors.good
                  : (down ? AppColors.warn : AppColors.inkMuted),
            ),
          ),
          const SizedBox(width: Sp.x3),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${_kg(p.currentKg!)} kg', style: AppText.metricSm),
            Text('est. 1RM', style: AppText.captionMuted),
          ],
        ),
      ],
    );
  }

  // ── weekly volume ──────────────────────────────────────────────────────────

  static String _bandLabel(ana.VolumeBand b) => switch (b) {
    ana.VolumeBand.below5 => 'under 5',
    ana.VolumeBand.from5to9 => '5-9',
    ana.VolumeBand.tenPlus => '10+',
  };

  static Color _bandColor(ana.VolumeBand b) => switch (b) {
    ana.VolumeBand.below5 => AppColors.inkMuted,
    ana.VolumeBand.from5to9 => AppColors.accent,
    ana.VolumeBand.tenPlus => AppColors.good,
  };

  Widget _volumeCard(ana.StrengthSummary s) {
    if (s.muscleVolume.isEmpty) {
      return SurfaceCard(
        child: Text(
          s.unlabelledSets > 0
              ? 'None of your ${s.unlabelledSets} logged sets carry a muscle '
                    'group, so volume cannot be split by muscle.'
              : 'No working sets in the last ${s.windowDays} days.',
          style: AppText.captionMuted,
        ),
      );
    }

    final max = s.muscleVolume.first.setsPerWeek;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Last ${s.windowDays} days', style: AppText.captionMuted),
              const Spacer(),
              InfoDot(
                title: 'Weekly sets per muscle',
                body:
                    'Working sets per muscle per week, averaged over the '
                    'window. Warm-ups are excluded.\n\n'
                    'The bands are the strata from Schoenfeld, Ogborn & '
                    'Krieger 2017, a meta-analysis of weekly set volume '
                    'against muscle growth: under 5, 5-9, and 10 or more '
                    'sets per muscle per week, with the response improving '
                    'across them.\n\n'
                    'That is a group-level dose-response, not a target for '
                    'you specifically, and the top band is open-ended - the '
                    'evidence does not name an optimum.',
                methodNote: s.unlabelledSets > 0
                    ? '${s.unlabelledSets} set(s) had no muscle group and '
                          'are not counted in any bar'
                    : null,
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          for (final m in s.muscleVolume)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.x3),
              child: Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: Text(
                      m.muscle,
                      style: AppText.captionMuted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        // Scaled to the biggest bar, so this compares muscles
                        // with each other. The BAND is what compares them with
                        // the literature.
                        value: max <= 0
                            ? 0
                            : (m.setsPerWeek / max).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: AppColors.inkMuted.withValues(
                          alpha: 0.15,
                        ),
                        valueColor: AlwaysStoppedAnimation(_bandColor(m.band)),
                      ),
                    ),
                  ),
                  const SizedBox(width: Sp.x3),
                  SizedBox(
                    width: 64,
                    child: Text(
                      '${m.setsPerWeek.toStringAsFixed(1)} '
                      '(${_bandLabel(m.band)})',
                      textAlign: TextAlign.right,
                      style: AppText.captionMuted,
                    ),
                  ),
                ],
              ),
            ),
          if (s.unlabelledSets > 0)
            Text(
              '${s.unlabelledSets} set(s) had no muscle group and are not '
              'shown above.',
              style: AppText.captionMuted,
            ),
        ],
      ),
    );
  }
}
