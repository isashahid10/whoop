// naps_card.dart — the day's daytime sleep, in the night's visual language.
//
// This renders as a TAB alongside the night rather than as a card buried below
// it. The reasoning is that a nap is a peer of the night, not a footnote to it:
// burying it meant scrolling past the entire nightly breakdown to reach the one
// thing you opened the screen to see.
//
// PRESENTATION RULES:
//
//   * Stages ARE shown, using the same StageBars the night uses. They come
//     from the same cardio stager — the pipeline computed them all along and
//     the nap path simply discarded them.
//   * The caveat is LENGTH, not method. Under an hour the stager estimates its
//     within-sleep references from too few epochs for the split to mean much,
//     so short naps show duration and a stated reason instead of a breakdown.
//   * Nap minutes are never added to nocturnal sleep. Short naps are mostly
//     light sleep, and a nap discharges some of the pressure driving the
//     coming night, so summing them would overstate both.

import 'package:flutter/material.dart';

import '../../compute/nap_service.dart';
import '../design/design.dart';

/// The nap tab's full content: one section per nap.
class NapContent extends StatelessWidget {
  final List<Nap> naps;

  /// Nocturnal sleep for the same day, minutes — for scale only, never summed.
  final double? nightMinutes;

  const NapContent({super.key, required this.naps, this.nightMinutes});

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')}'
        '${t.hour < 12 ? 'am' : 'pm'}';
  }

  static String _dur(int min) {
    if (min < 60) return '${min}m';
    final h = min ~/ 60;
    final m = min % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  /// What a nap of this length tends to do. A statement about DURATION, not a
  /// measurement of this nap's physiology.
  static String _note(Nap n) {
    if (n.isShort) {
      return 'Short enough to be restorative without much grogginess on '
          'waking.';
    }
    if (n.isLong) {
      return 'Long enough to reduce tonight\'s sleep pressure - you may find '
          'it harder to fall asleep at your usual time.';
    }
    return 'Long enough that you may have woken mid-cycle, which can leave '
        'you groggy for a while.';
  }

  @override
  Widget build(BuildContext context) {
    if (naps.isEmpty) {
      return const StateCard(
        icon: OsIcon.bedtime,
        title: 'No nap today',
        message: 'Naps are found from sustained stillness plus a drop in '
            'heart rate, between 20 minutes and 3 hours.',
      );
    }

    final total = naps.fold<int>(0, (a, n) => a + n.minutes);

    // The hero is a TOTAL, so it only earns its place when there is more than
    // one nap to total. With a single nap it repeated the duration a third
    // time — the tab label already says "Nap 1h 34m" and the bout says it
    // again — so it is dropped and its one unique piece of information (the
    // night, for scale) moves into the bout.
    final single = naps.length == 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!single) _hero(total),
        for (var i = 0; i < naps.length; i++) ...[
          if (!single || i > 0) const SizedBox(height: Sp.x3),
          _bout(naps[i], showNight: single),
        ],
        const SizedBox(height: Sp.x4),
        Text(
          'Nap minutes are kept separate from your night and are never added '
          'to it. Short naps are mostly light sleep, and a nap also spends '
          'some of the sleep pressure that drives the following night.',
          style: AppText.captionMuted,
        ),
      ],
    );
  }

  Widget _hero(int total) => SurfaceCard(
        padding: const EdgeInsets.all(Sp.x5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${naps.length} naps', style: AppText.title),
                const Spacer(),
                _info(),
              ],
            ),
            const SizedBox(height: Sp.x3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_dur(total), style: AppText.metric),
                const SizedBox(width: Sp.x2),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('across the day', style: AppText.captionMuted),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _hrStat(String v, String unit, String label) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(v, style: AppText.metricSm.copyWith(fontSize: 22)),
                const SizedBox(width: 3),
                Text(unit, style: AppText.captionMuted),
              ],
            ),
            Text(label, style: AppText.captionMuted),
          ],
        ),
      );

  Widget _info() => const InfoDot(
        title: 'How naps are measured',
        body: 'A nap is found from sustained wrist immobility together with a '
            'drop in heart rate, bounded to between 20 minutes and 3 hours. '
            'Your main sleep is excluded, so the night can never be counted '
            'twice.\n\n'
            'Stages come from the same cardio stager your night uses - the '
            'same pipeline, not a second method.\n\n'
            'The limit is LENGTH. The stager compares each epoch against '
            'references drawn partly from the session itself, so a short nap '
            'estimates those references from very few epochs and its stage '
            'split becomes unreliable. Under an hour the breakdown is withheld '
            'for that reason rather than shown with false precision.\n\n'
            'Nap minutes are never added to your nightly total.',
        methodNote:
            'van Hees immobility + HR autonomic dip. A wrist estimate, not PSG.',
      );

  Widget _bout(Nap n, {bool showNight = false}) => SurfaceCard(
        padding: const EdgeInsets.all(Sp.x5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Single-nap layout carries the header the hero would have shown,
            // so the (i) explaining the method stays reachable either way.
            if (showNight) ...[
              Row(
                children: [
                  Text('Nap', style: AppText.title),
                  const Spacer(),
                  _info(),
                ],
              ),
              const SizedBox(height: Sp.x3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_dur(n.minutes), style: AppText.metric),
                  const SizedBox(width: Sp.x2),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${_clock(n.start)} – ${_clock(n.end)}',
                      style: AppText.captionMuted,
                    ),
                  ),
                ],
              ),
              // The night sits on its OWN line rather than trailing the time
              // range: together they wrapped mid-phrase against the metric,
              // which read as one broken sentence instead of two facts.
              if (nightMinutes != null && nightMinutes! > 0) ...[
                const SizedBox(height: 2),
                Text(
                  'plus ${_dur(nightMinutes!.round())} of sleep last night',
                  style: AppText.captionMuted,
                ),
              ],
            ] else
              Row(
                children: [
                  AppIcon(OsIcon.bedtime, size: 18, color: DomainAccent.sleep),
                  const SizedBox(width: Sp.x2),
                  Text(
                    '${_clock(n.start)} – ${_clock(n.end)}',
                    style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(
                    _dur(n.minutes),
                    style: AppText.body.copyWith(
                      fontWeight: FontWeight.w800,
                      color: DomainAccent.sleep,
                    ),
                  ),
                ],
              ),

            // Stages, in the same component the night uses, when the nap is
            // long enough for them to mean anything.
            if (n.hasStages && n.stagingReliable) ...[
              const SizedBox(height: Sp.x4),
              StageBars(
                remMin: n.remMin.round(),
                lightMin: n.lightMin.round(),
                deepMin: n.deepMin.round(),
              ),
            ] else if (n.hasStages) ...[
              // Stages exist but the session is too short to trust them. Say
              // exactly that — silence would read as "the band failed".
              const SizedBox(height: Sp.x3),
              Text(
                'Too short for a reliable stage breakdown. Sleep staging '
                'compares each minute against references drawn from the '
                'session itself, and under an hour there are too few minutes '
                'to set them.',
                style: AppText.captionMuted,
              ),
            ],

            // Heart rate through the nap. Shown only where it exists: a nap
            // with no clean beats gets no row rather than a dash.
            if (n.restingHr != null || n.avgHrv != null) ...[
              const SizedBox(height: Sp.x4),
              Row(
                children: [
                  if (n.restingHr != null)
                    _hrStat('${n.restingHr}', 'bpm', 'lowest heart rate'),
                  if (n.avgHrv != null)
                    _hrStat(n.avgHrv!.round().toString(), 'ms', 'average HRV'),
                ],
              ),
            ],
            const SizedBox(height: Sp.x3),
            Text(_note(n), style: AppText.captionMuted),

            if (n.isLowConfidence) ...[
              const SizedBox(height: Sp.x2),
              Row(
                children: [
                  Icon(Icons.help_outline_rounded,
                      size: 13, color: AppColors.inkMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Low confidence - you may just have been very still.',
                      style: AppText.captionMuted.copyWith(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
}
