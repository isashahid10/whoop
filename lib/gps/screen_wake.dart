// ScreenWake — hold the display awake for the duration of a live workout.
//
// Every serious run/ride app does this: the athlete has the phone on a bar
// mount or an armband and glances at it, they do not tap it every 30 s to stop
// the screen sleeping. Before this, the live session screen carried a "Keep the
// screen on to map your route" hint — asking the user to work around the app.
//
// Deliberately NOT a new dependency. Both platforms already have a registered
// method channel, and the native primitive is one line each:
//   • Android — FLAG_KEEP_SCREEN_ON on the activity window (window-scoped, so
//     it is released automatically when the activity goes away).
//   • iOS     — UIApplication.isIdleTimerDisabled.
// Neither is a true CPU wakelock: they keep the DISPLAY on while the app is
// frontmost and nothing more, so a leaked flag can never drain the battery in
// the background. Background *recording* is a separate mechanism entirely (the
// location background mode / FGS location type — see gps_source.dart).
//
// Failure is always silent: a screen that sleeps is a papercut, never a reason
// to interrupt a workout.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ScreenWake {
  static const _android = MethodChannel('openstrap/edge_tracking');
  static const _ios = MethodChannel('openstrap/ios_config');

  /// What the PLATFORM last confirmed, not what we last asked for.
  ///
  /// Only updated after a successful call. Android returns false when no
  /// activity is attached; latching the requested value before the result came
  /// back meant a failed enable left Dart believing the screen was held and
  /// short-circuited every later retry.
  static bool _on = false;

  /// Test seam for the platform switch below.
  ///
  /// `Platform.isAndroid` and `Platform.isIOS` are BOTH false on the host VM
  /// that widget tests run on, so without this the dispatch short-circuits and
  /// no test can reach either MethodChannel — the mocks looked wired up and
  /// asserted nothing. Set to 'android' or 'ios' in a test; null = real
  /// platform.
  @visibleForTesting
  static String? platformOverride;

  static bool get _isAndroid =>
      platformOverride == null ? Platform.isAndroid : platformOverride == 'android';
  static bool get _isIOS =>
      platformOverride == null ? Platform.isIOS : platformOverride == 'ios';

  @visibleForTesting
  static bool get isHeld => _on;

  /// Keep the display awake. Safe to call repeatedly.
  static Future<void> enable() => _set(true);

  /// Release the display. MUST be called when the session ends — including on
  /// the error/abort paths, or the screen stays awake until the app is killed.
  static Future<void> release() => _set(false);

  static Future<void> _set(bool on) async {
    if (on == _on) return;
    try {
      if (_isAndroid) {
        final ok = await _android.invokeMethod<bool>('keepAwake', {'on': on});
        // Android answers false when there is no attached activity. Leave the
        // flag alone so the next call retries rather than assuming success.
        if (ok != true) return;
      } else if (_isIOS) {
        await _ios.invokeMethod<bool>('keepAwake', {'on': on});
      }
      _on = on;
    } catch (e) {
      // Never surface: losing the wake flag degrades to "screen sleeps". The
      // flag stays unchanged, so a later attempt can still succeed.
      debugPrint('[screen-wake] ${on ? 'enable' : 'release'} failed: $e');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _on = false;
    platformOverride = null;
  }
}
