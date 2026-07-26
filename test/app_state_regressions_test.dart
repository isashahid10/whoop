// Regression tests for a batch of AppState state-machine bugs.
//
// AppState.forTesting() builds the object graph WITHOUT running _init() and
// without touching a single platform plugin, so the logic below can be driven
// directly. Each group names the bug it guards.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart';

/// A BleEngine whose live-stream arming always fails — the "link dropped
/// mid-write" case that used to latch _stepCalActive true forever.
class _ThrowingEngine extends BleEngine {
  _ThrowingEngine()
      : super(
          onRecord: _noRecord,
          onState: _noState,
        );
  static Future<void> _noRecord(Object? sample, Object? raw) async {}
  static void _noState(Object state) {}

  @override
  Future<void> retryFullLiveStreams() async =>
      throw StateError('link dropped mid-write');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_app_state_regressions_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── 1. the serial heal must never RE-PAIR a band the user just unpaired ─────
  group('healedPairing (stale engine-state callback after unpair)', () {
    test('an unpaired app is NEVER re-paired from a stale engine state', () {
      // BleEngine._teardownSession leaves state.serial/state.address set, so a
      // late onState (e.g. the reconnect loop's finally → clearReconnecting →
      // _setPhase(idle) → onState) arrives with a perfectly clean serial long
      // after unpair() ran. The old guard (`cleanSn != paired?.serial`) was
      // TRUE for paired == null and rebuilt a PairedDevice from state.address,
      // silently re-pairing the removed band and bouncing the app back to the
      // Shell.
      expect(healedPairing(null, '4C2248092'), isNull);
      expect(healedPairing(null, "Abdul's WHOOP"), isNull);
    });

    test('an EXISTING pairing still gets its junk serial healed', () {
      final healed = healedPairing(PairedDevice('r-1', '?*?*'), '4C2248092');
      expect(healed, isNotNull);
      expect(healed!.remoteId, 'r-1');
      expect(healed.serial, '4C2248092');
    });

    test('a pairing with no serial yet gets one', () {
      expect(healedPairing(PairedDevice('r-1', null), '4C2248092')?.serial,
          '4C2248092');
    });

    test('no change when the serial already matches, or the report is junk',
        () {
      expect(healedPairing(PairedDevice('r-1', '4C2248092'), '4C2248092'),
          isNull);
      expect(healedPairing(PairedDevice('r-1', '4C2248092'), '?*?*'), isNull);
      expect(healedPairing(PairedDevice('r-1', '4C2248092'), null), isNull);
      expect(healedPairing(PairedDevice('r-1', '4C2248092'), '   '), isNull);
    });

    test('the remoteId is never invented — it always comes from the pairing',
        () {
      // Even with a clean serial, an empty remoteId means there is nothing
      // legitimate to write back.
      expect(healedPairing(PairedDevice('', null), '4C2248092'), isNull);
    });
  });

  // ── 5. _stepCalActive must not latch true when the arming throws ────────────
  group('startStepCalibration (live-consumer latch)', () {
    test('a throwing stream arm leaves no phantom live consumer', () async {
      final engine = _ThrowingEngine();
      engine.state.connection = 'connected';
      final app = AppState.forTesting(engine: engine);
      addTearDown(app.dispose);

      expect(app.debugHasLiveConsumer, isFalse);
      await expectLater(
          app.startStepCalibration(), throwsA(isA<StateError>()));
      // Pre-fix this stayed true for the rest of the process, pinning
      // _hasLiveConsumer and permanently disabling
      // _maybeDowngradeLiveForBackground — the 100 Hz raw flood then kept
      // streaming while backgrounded and starved the R24 offload.
      expect(app.debugHasLiveConsumer, isFalse);
    });
  });

  // ── 6. `busy` must not latch true forever ──────────────────────────────────
  group('openSession (busy latch)', () {
    test('unpairing while the session is opening does not wedge busy',
        () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.paired = PairedDevice('r-1', '4C2248092');
      // Simulate the user tapping Unpair inside openSession's own resume
      // window: the first thing openSession does after flipping busy is
      // notify, and unpair() nulls `paired`.
      app.addListener(() => app.paired = null);

      // Pre-fix this THREW (`paired!` sat outside the try) and left busy true,
      // so every later openSession()/syncNow() no-opped — "Sync now" was dead
      // until the process restarted.
      await app.openSession();

      expect(app.busy, isFalse);
      expect(app.paired, isNull);
      // And the state machine is genuinely usable again.
      await app.syncNow();
      expect(app.busy, isFalse);
    });
  });

  // ── 7. the orphan-workout reconcile must not clobber a live workout ────────
  group('_reconcileOrphanedLiveWorkout (startWorkout race)', () {
    test('a workout started inside the DB round-trip is not overwritten',
        () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await LocalDb.putSession({
        'id': 'stale-from-a-killed-run',
        'start_ts': nowSec - 600,
        'end_ts': null,
        'type': 'other',
        'status': 'live',
        'source': 'manual',
        'created_at': (nowSec - 600) * 1000,
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);

      // Kicked unawaited from _init(), one line before `initialized = true`
      // makes the shell interactive — so the user can start a workout inside
      // the round-trip.
      final reconcile = app.debugReconcileOrphanedLiveWorkout();
      app.activeWorkout = LiveWorkoutState(
        startTime: DateTime.now(),
        targetKcal: 300,
        workoutId: 'user-just-started-this',
        type: 'run',
      );
      await reconcile;

      expect(app.activeWorkout?.workoutId, 'user-just-started-this',
          reason: 'the stale row must never replace a genuinely live workout '
              '(the old timer became unreachable and double-counted at 2 Hz)');
    });

    test('with nothing live, a recent orphan is still resumed', () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await LocalDb.putSession({
        'id': 'resumable',
        'start_ts': nowSec - 300,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': (nowSec - 300) * 1000,
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.debugReconcileOrphanedLiveWorkout();
      expect(app.activeWorkout?.workoutId, 'resumable');
    });
  });

  // ── 9. a fired alarm must be cleared from state AND prefs ──────────────────
  group('alarm lifecycle (fired / strap-cleared)', () {
    final originalSink = NotificationCenter.instance.presentSink;
    tearDown(() => NotificationCenter.instance.presentSink = originalSink);

    Future<void> silenceOsPresent() async {
      NotificationCenter.instance.presentSink =
          (NotificationEvent e, {bool allowPermissionPrompt = true}) async =>
              true;
    }

    test('EXECUTED (event 57) clears the armed alarm and its persisted epoch',
        () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      await silenceOsPresent();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;
      expect(app.alarmEpoch, 1785000000);

      app.debugHandleAlarmEvent(57);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Pre-fix this only logged + notified: alarmEpoch kept returning the past
      // epoch across relaunches (_init reloads `alarm_epoch`) and Profile's
      // "Smart alarm" row advertised a spent one-shot as the CURRENT alarm.
      expect(app.alarmEpoch, isNull);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), isNull);
      expect(app.alarmFiredAt, isNotNull, reason: 'firedAt must survive');
    });

    test('the app-side EXECUTED id (58) clears it too', () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      await silenceOsPresent();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(58);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(app.alarmEpoch, isNull);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), isNull);
    });

    test('the strap-driven clear (event 59) also drops the persisted epoch',
        () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(59);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(app.alarmEpoch, isNull);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), isNull,
          reason: 'state was nulled but the epoch used to stay on disk and '
              'came back on the next launch');
    });

    test('ALARM_SET (event 56) leaves the armed alarm alone', () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(56);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(app.alarmEpoch, 1785000000);
      expect(app.alarmConfirmed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), 1785000000);
    });
  });

  // ── 10. dispose must release EVERYTHING AppState owns ──────────────────────
  group('dispose', () {
    testWidgets('cancels every owned timer', (t) async {
      final app = AppState.forTesting();
      // _spotTimer, _breathingRecomputeTimer and _workoutTimer used to survive
      // dispose; each callback ends in notifyListeners() on a disposed
      // ChangeNotifier. An outstanding Timer fails this test outright.
      app.debugArmOwnedTimers();
      app.dispose();
    });

    testWidgets('disposes every owned notifier/observer', (t) async {
      final app = AppState.forTesting();
      app.dispose();
      void addTo(void Function(VoidCallback) add) =>
          expect(() => add(() {}), throwsA(isA<FlutterError>()));
      addTo(app.navRequest.addListener);
      addTo(app.screenRequest.addListener);
      addTo(app.insightsRevision.addListener);
      addTo(app.gestureSettings.addListener);
      // NotificationRelay holds a WidgetsBindingObserver, a 120 s
      // Timer.periodic and a StreamSubscription — its observer accumulated on
      // the binding across every hot restart.
      addTo(app.notificationRelay.addListener);
    });
  });
}
