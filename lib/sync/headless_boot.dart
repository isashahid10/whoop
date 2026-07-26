// headless_boot.dart — Android post-reboot headless auto-connect.
//
// When Android boots the device, BootReceiver starts EdgeTrackingService, which
// causes EdgeApplication.onCreate to pre-warm the FlutterEngine. That engine runs
// main() with no Activity attached. We detect the headless (no-Activity) case here
// and, if a band is paired, start the foreground service + kick a headless sync so
// the band reconnects automatically without user interaction.
//
// Idempotency: EdgeTracking.start() is already idempotent (just sends "start" to
// the existing service). runHeadlessSync() uses a connect-by-id path; if the
// foreground AppState later attaches, it re-uses the same BleEngine and doesn't
// double-connect because BleEngine.connectToRemoteId is guarded by its own state
// machine. The headless sync runs once (await) and then sits idle; the real live
// connection is managed by AppState when the UI opens.
//
// NOT called on iOS — iOS background relaunch is handled by BleRestoreManager +
// IosBleRestore (CB state restoration wake). iOS does NOT have an Activity concept,
// so this Android-only path is guarded by Platform.isAndroid.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'android_boot_signal.dart';
import 'band_ownership.dart';
import 'headless_gate.dart';
import '../sync/background_sync.dart';
import '../sync/edge_tracking.dart';
import '../sync/paired_device.dart';

/// The [HeadlessSyncGate] owner name for the Android post-boot wake.
const String kBootWakeGateOwner = 'android_boot_wake';

/// Run the boot drain THROUGH the process-wide headless gate.
///
/// The stated invariant is that EVERY headless entry point serialises through
/// [HeadlessSyncGate] (skip, don't queue). The three iOS entry points did; this
/// Android boot path called `runHeadlessSync` directly and fire-and-forget, so
/// `HeadlessSyncGate.busy` read false for the entire duration of a boot drain
/// and any iOS-style wake landing in the same process would have run
/// concurrently with it.
///
/// Returns the runner's result, or null when the gate was busy and this cycle
/// was skipped — in which case the band lease is released, since nothing will
/// use it. [runner] is injectable for tests.
Future<bool?> runBootSyncThroughGate(
  BandLease lease, {
  Future<bool> Function(BandLease lease)? runner,
}) async {
  final run = runner ?? ((l) => runHeadlessSync(lease: l));
  final result = await HeadlessSyncGate.tryRun<bool>(
    kBootWakeGateOwner,
    () => run(lease),
  );
  if (result == null) {
    // Skipped — release the lease we acquired up front, or the band stays
    // owned by a headless run that never happened.
    BandOwnership.release(lease);
  }
  return result;
}

/// Guards headless boot so we only run once per process lifetime. Prevents
/// re-entry if main() is somehow invoked twice on the same engine.
bool _booted = false;

/// Call from main() before runApp (but after WidgetsFlutterBinding.ensureInitialized).
/// On Android with no Activity, checks for a paired band and auto-connects headlessly.
///
/// Returns immediately if:
///   - not Android
///   - not a headless launch (UI is present)
///   - no paired device
///   - already ran
///
/// This is deliberately SYNCHRONOUS from the call-site perspective — the caller
/// awaits so startup init stays ordered, but the actual BLE work is fire-and-forget
/// after we start the service (connect happens asynchronously in the engine).
Future<void> maybeHeadlessBoot() async {
  if (!Platform.isAndroid) return;
  if (_booted) return;
  _booted = true;

  final pendingBoot = await AndroidBootSignal.consumePendingHeadlessBoot();
  if (!pendingBoot) {
    return;
  }

  final paired = await PairedDevice.load();
  if (paired == null) return; // nothing paired, nothing to do

  final lease = BandOwnership.tryAcquireHeadless();
  if (lease == null) {
    debugPrint(
      '[headless-boot] boot wake skipped — ${BandOwnership.debugState}',
    );
    return;
  }

  debugPrint(
    '[headless-boot] boot wake confirmed — lease=${lease.token} '
    '${BandOwnership.debugState}',
  );
  // Ensure the foreground service is running (it was started by BootReceiver, but
  // calling start() again here is safe — EdgeTracking.start() is idempotent).
  await EdgeTracking.start();

  // Run a single headless drain pass (connect → flash offload → local store →
  // disconnect). This catches up the offline backlog accumulated while the phone
  // was powered off. Errors are swallowed inside runHeadlessSync.
  debugPrint('[headless-boot] starting headless sync for ${paired.remoteId}');
  // Fire-and-forget (see the doc above) but SERIALISED through the shared
  // headless gate, so `HeadlessSyncGate.busy` is true for the whole boot drain.
  unawaited(
    runBootSyncThroughGate(lease).then((ran) {
      debugPrint(
        ran == null
            ? '[headless-boot] boot wake skipped — another headless sync '
                'holds the gate; lease released.'
            : '[headless-boot] headless sync complete',
      );
    }),
  );
}
