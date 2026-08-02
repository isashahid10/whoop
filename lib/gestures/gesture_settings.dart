// gesture_settings.dart — the persisted band-gesture → action mapping, plus the
// per-platform set of supported actions. Same persistence pattern as ThemeController
// (SharedPreferences) and same ChangeNotifier shape so the settings UI rebuilds and
// the dispatcher reads a live value.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/device_actions.dart';
import 'device_action.dart';

class GestureSettings extends ChangeNotifier {
  static const _kDoubleTap = 'gesture_double_tap';

  /// What a double-tap currently does.
  ///
  /// Defaults to "ring my phone" — find-my-phone from the wrist is the one
  /// action that is useful without any setup, cannot misfire into anything
  /// destructive, and is what a wrist tap is most often wanted for. Upstream
  /// defaulted to [DeviceAction.none] to avoid surprising a stranger; this is a
  /// single-user fork, and an opt-in default just means the feature sits unused.
  DeviceAction doubleTap = DeviceAction.ringPhone;

  /// Actions offerable on THIS platform: `none` always, plus whatever native says
  /// it can do. Until bootstrap() runs we only know `none`.
  Set<DeviceAction> supported = {DeviceAction.none};

  /// Load the saved mapping and query native capabilities. Call once at startup.
  Future<void> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    // No stored choice → the ring-phone default above. A STORED `none` is a
    // deliberate "do nothing" and is honoured; only an absent key falls back.
    doubleTap =
        DeviceActionX.fromId(prefs.getString(_kDoubleTap)) ??
        DeviceAction.ringPhone;

    final caps = await DeviceActions.capabilities();
    supported = {
      DeviceAction.none,
      // In-app actions act on our own app, so they're offerable everywhere.
      ...DeviceAction.values.where((a) => a.isInApp),
      // Native actions: only what this platform reported it can do.
      ...caps.map(DeviceActionX.fromId).whereType<DeviceAction>(),
    };

    // If a previously-chosen action isn't supported here (e.g. settings synced from
    // an Android backup onto an iPhone), fall back to none rather than silently
    // mapping to something unsupported.
    if (!supported.contains(doubleTap)) {
      doubleTap = DeviceAction.none;
      await prefs.setString(_kDoubleTap, doubleTap.id);
    }
    notifyListeners();
  }

  Future<void> setDoubleTap(DeviceAction action) async {
    if (action == doubleTap) return;
    doubleTap = action;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDoubleTap, action.id);
    notifyListeners();
  }

  /// True once the user has mapped a real-time action — callers can use this to
  /// decide whether the iOS background BLE keep-alive is worth enabling.
  bool get hasActiveMapping => doubleTap != DeviceAction.none;
}
