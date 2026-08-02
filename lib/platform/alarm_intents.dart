// alarm_intents.dart — Dart side of the Siri alarm queue.
//
// Siri can fire when this isolate is not running and when the band is nowhere
// near the phone, so the intent cannot arm anything itself. It queues, and this
// drains the queue whenever there is a live connection.
//
// The draining is deliberately NOT done once at startup. The band typically
// connects a few seconds after the app does, so a single startup drain would
// throw away most requests. Instead the queue is drained on connect, on resume,
// and the request is held until it can actually be delivered.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A request Siri left behind.
class PendingAlarm {
  /// Unix seconds to arm for, when the request was "set an alarm".
  final int? epoch;

  /// True when the request was "cancel my alarm".
  final bool clear;

  /// True when the request was "buzz my band".
  final bool buzz;

  const PendingAlarm({this.epoch, this.clear = false, this.buzz = false});

  bool get isEmpty => epoch == null && !clear && !buzz;

  static const PendingAlarm none = PendingAlarm();
}

class AlarmIntents {
  static const _ch = MethodChannel('openstrap/alarm_intent');

  /// Read and CLEAR whatever Siri queued.
  ///
  /// Destructive by design — a request that survived being read would re-arm on
  /// every resume, which is how you end up with an alarm you cannot delete.
  static Future<PendingAlarm> takePending() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('takePending');
      if (r == null || r.isEmpty) return PendingAlarm.none;
      return PendingAlarm(
        epoch: (r['epoch'] as num?)?.toInt(),
        clear: r['clear'] == true,
        buzz: r['buzz'] == true,
      );
    } catch (e) {
      debugPrint('[alarm_intent] takePending failed: $e');
      return PendingAlarm.none;
    }
  }

  /// Whether this OS can schedule an alarm that breaks through silent mode and
  /// Focus. AlarmKit is iOS 26+; everything older gets false and no backup.
  static Future<bool> backupSupported() async {
    try {
      return await _ch.invokeMethod<bool>('backupSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Prompt for AlarmKit authorization. Returns false if declined or absent.
  static Future<bool> authorizeBackup() async {
    try {
      return await _ch.invokeMethod<bool>('authorizeBackup') ?? false;
    } catch (e) {
      debugPrint('[alarm_intent] authorizeBackup failed: $e');
      return false;
    }
  }

  /// Schedule the phone-side backup for [when].
  ///
  /// This is a SAFETY NET, never the primary alarm. The band runs off its own
  /// RTC and does not consult the phone, so Do Not Disturb, Focus and the
  /// ringer switch are already irrelevant to it. This covers the case the band
  /// cannot: off the wrist, flat, or never connected when the alarm was armed.
  static Future<bool> scheduleBackup(
    DateTime when, {
    String label = 'Wake up',
  }) async {
    try {
      return await _ch.invokeMethod<bool>('scheduleBackup', {
            'epoch': when.millisecondsSinceEpoch ~/ 1000,
            'label': label,
          }) ??
          false;
    } catch (e) {
      debugPrint('[alarm_intent] scheduleBackup failed: $e');
      return false;
    }
  }

  /// Fire times AlarmKit still holds, as local DateTimes, soonest first.
  ///
  /// Read back from the framework rather than from anything this app stored:
  /// an alarm that already fired, or that was stopped from the Lock Screen, is
  /// gone from AlarmKit but would linger in a local mirror — and an "upcoming"
  /// list showing an alarm that cannot ring is worse than showing none.
  static Future<List<DateTime>> pendingBackups() async {
    try {
      final r = await _ch.invokeListMethod<int>('pendingBackups');
      final out = [
        for (final e in r ?? const <int>[])
          DateTime.fromMillisecondsSinceEpoch(e * 1000),
      ]..sort();
      return out;
    } catch (e) {
      debugPrint('[alarm_intent] pendingBackups failed: $e');
      return const [];
    }
  }

  static Future<bool> cancelBackup() async {
    try {
      return await _ch.invokeMethod<bool>('cancelBackup') ?? false;
    } catch (e) {
      debugPrint('[alarm_intent] cancelBackup failed: $e');
      return false;
    }
  }
}
