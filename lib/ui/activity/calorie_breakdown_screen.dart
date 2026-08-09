// Calorie breakdown - where the day's energy actually went.
//
// A daily total answers "how much" and nothing else. This answers "when, how
// hard, and probably doing what", which is the question people actually have
// when a number looks surprising.
//
// TWO PRESENTATION RULES, both load-bearing:
//
//   * Every block shows its RATE (kcal/min) alongside its total. A 90-minute
//     walk and a 20-minute sprint can cost the same and mean nothing alike;
//     showing only totals hides that entirely.
//   * An INFERRED label is visually distinct from a LOGGED one. "Push day" came
//     from a workout you typed in. "Afternoon effort" is the app guessing from
//     the clock, and it must not borrow the authority of the former.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../compute/calorie_breakdown_service.dart';
import '../../compute/profile.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

class CalorieBreakdownScreen extends StatefulWidget {
  final String date;
  const CalorieBreakdownScreen({super.key, required this.date});

  @override
  State<CalorieBreakdownScreen> createState() =>
      _CalorieBreakdownScreenState();
}

class _CalorieBreakdownScreenState extends State<CalorieBreakdownScreen> {
  CalorieDay? _day;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = context.read<AppState>().user;
    final d = await CalorieBreakdownService.forDay(
      widget.date,
      profile: Profile.fromMap(user),
    );
    if (mounted) {
      setState(() {
        _day = d;
        _loading = false;
      });
    }
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')}'
        '${t.hour < 12 ? 'am' : 'pm'}';
  }

  static String _dur(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    return m % 60 == 0 ? '${m ~/ 60}h' : '${m ~/ 60}h ${m % 60}m';
  }

  @override
  Widget build(BuildContext context) {
    final d = _day;
    return AppScaffold(
      title: 'Energy',
      subtitle: 'Where the day went',
      body: _loading
          ? Skeleton.tileRow(rows: 4)
          : (d == null || !d.hasData)
              ? const StateCard(
                  icon: OsIcon.calories,
                  title: 'No energy breakdown',
                  message:
                      'This needs heart rate from the band plus your age, '
                      'weight and sex, because the model is applied to YOU '
                      'rather than to an average person. Without them the app '
                      'abstains instead of showing a plausible guess.',
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
                    children: _sections(d),
                  ),
                ),
    );
  }

  List<Widget> _sections(CalorieDay d) => [
        _hero(d),
        if (d.blocks.isNotEmpty) ...[
          const SizedBox(height: Sp.x4),
          const SectionHeader('What cost what'),
          for (var i = 0; i < d.blocks.length; i++) ...[
            if (i > 0) const SizedBox(height: Sp.x2),
            _block(d.blocks[i], d),
          ],
        ] else ...[
          const SizedBox(height: Sp.x3),
          Text(
            'No sustained effort today. Everything above resting was brief or '
            'gentle enough that splitting it into blocks would invent detail '
            'the data does not have.',
            style: AppText.captionMuted,
          ),
        ],
        const SizedBox(height: Sp.x4),
        _method(d),
      ];

  Widget _hero(CalorieDay d) {
    final big = d.biggest;
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${d.activeKcal.round()}',
                  style: AppText.metric.copyWith(color: DomainAccent.strain)),
              const SizedBox(width: Sp.x2),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('kcal above resting', style: AppText.captionMuted),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Plus about ${d.basalKcal.round()} kcal your body spent just '
            'existing.',
            style: AppText.captionMuted,
          ),
          if (big != null) ...[
            const SizedBox(height: Sp.x4),
            Text(
              // The one-line answer to "what did I do today".
              '${((big.activeKcal / d.activeKcal) * 100).round()}% of it came '
              'from one block: ${_clock(big.start)} to ${_clock(big.end)}, '
              'averaging ${big.meanHr.round()} bpm.',
              style: AppText.body,
            ),
          ],
          if (d.uncoveredMin > 20) ...[
            const SizedBox(height: Sp.x3),
            Text(
              'The band had no reading for ${d.uncoveredMin} minutes of this '
              'span, so nothing is attributed to them.',
              style: AppText.captionMuted.copyWith(fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _block(CalorieBlock b, CalorieDay d) {
    final share = d.activeKcal <= 0 ? 0.0 : (b.activeKcal / d.activeKcal);
    return SurfaceCard(
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            b.attribution ?? 'Elevated heart rate',
                            style: AppText.body
                                .copyWith(fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: Sp.x2),
                        // A guess must not look like a fact.
                        if (!b.attributionIsLogged)
                          Text('guess',
                              style: AppText.captionMuted
                                  .copyWith(fontSize: 10)),
                      ],
                    ),
                    Text(
                      '${_clock(b.start)} - ${_clock(b.end)}  ·  '
                      '${_dur(b.duration)}',
                      style: AppText.captionMuted,
                    ),
                  ],
                ),
              ),
              Text('${b.activeKcal.round()}',
                  style: AppText.metricSm.copyWith(
                      fontSize: 22, color: DomainAccent.strain)),
            ],
          ),
          const SizedBox(height: Sp.x3),
          // Share of the day, as a plain proportional bar.
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: share.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: AppColors.divider,
              valueColor:
                  AlwaysStoppedAnimation<Color>(DomainAccent.strain),
            ),
          ),
          const SizedBox(height: Sp.x3),
          Row(
            children: [
              _stat(b.kcalPerMin.toStringAsFixed(1), 'kcal/min'),
              _stat('${b.meanHr.round()}', 'avg bpm'),
              _stat('${b.peakHr.round()}', 'peak bpm'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String v, String label) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(v, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: AppText.captionMuted),
          ],
        ),
      );

  Widget _method(CalorieDay d) => SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('How this is worked out', style: AppText.title),
                const Spacer(),
                const InfoDot(
                  title: 'Energy method',
                  body:
                      'Active energy comes from Keytel et al. 2005, which '
                      'estimates expenditure from HEART RATE together with '
                      'your weight, age and sex. Resting burn uses the revised '
                      'Harris-Benedict equation.\n\n'
                      'Each block runs the same calculation as the daily '
                      'total, over that block\'s own heart rate, so the blocks '
                      'add back up to the day. A block starts when heart rate '
                      'passes 40% of your reserve - the ACSM/WHO threshold for '
                      'moderate intensity - and ends after 12 minutes back '
                      'below it, so a water break does not split a match in '
                      'two.\n\n'
                      'LABELS ARE NOT MEASUREMENTS. A block matching a workout '
                      'you logged takes that name. Everything else is named '
                      'from the clock alone and marked as a guess: the app '
                      'knows your heart rate was high, not what you were '
                      'doing.\n\n'
                      'This is an estimate from a wrist sensor, not '
                      'calorimetry. Treat it as a consistent relative measure '
                      'rather than an exact figure.',
                  methodNote: 'Keytel 2005 + Harris-Benedict, per-minute HR',
                ),
              ],
            ),
            const SizedBox(height: Sp.x2),
            Text(
              'Energy is measured from your heart rate, not your movement. '
              'That is why a session played without your phone still counts '
              'here.',
              style: AppText.captionMuted,
            ),
          ],
        ),
      );
}
