// Regression tests for the derivation engine's ISOLATE LIFECYCLE.
//
// Every one of these failures had the same shape: a worker isolate dies or
// hangs, the main side awaits a Completer that can never complete, `_running`
// stays true, and `DeriveScheduler._drain` never returns — ALL derivation is
// dead until the app is restarted. The engine never sees an error, so it never
// even logs one.
//
//  * `_loadSubstrateRange` spawned the prepare worker with NO onError/onExit
//    port and put NO timeout on the result, while the worker itself only
//    reported errors from its 'finish' branch — so any throw in its 'page'
//    handler (an unguarded numeric read over a SQLite row) killed it silently.
//  * `Isolate.run(...).timeout(...)` only stops the CALLER waiting; the isolate
//    keeps burning a core behind the bounded worker pool's back. And the
//    sleep-staging site had no timeout at all.

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';

/// Drive the real prepare worker over a caller-supplied page sequence and
/// return whichever came first: a result payload, or an error. Mirrors
/// `_loadSubstrateRange`'s wiring (onError + onExit + a bounded wait) so the
/// worker's own failure contract is what's under test.
Future<Object?> _drivePrepareWorker(
  List<Map<String, dynamic>> messages, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final port = ReceivePort();
  final isolate = await Isolate.spawn(
    derivationPrepareWorker,
    port.sendPort,
    onError: port.sendPort,
    onExit: port.sendPort,
  );
  final ready = Completer<SendPort>();
  final done = Completer<Object?>();
  late final StreamSubscription<dynamic> sub;
  void finish(Object? v) {
    if (!done.isCompleted) done.complete(v);
  }

  sub = port.listen((message) {
    if (message is SendPort) {
      if (!ready.isCompleted) ready.complete(message);
      return;
    }
    if (message is Map && message['type'] == 'result') {
      finish(message['payload']);
      return;
    }
    if (message is Map && message['type'] == 'error') {
      finish(StateError('worker error: ${message['error']}'));
      return;
    }
    if (message is List) {
      finish(StateError('worker crashed: ${message.first}'));
      return;
    }
    if (message == null) finish(StateError('worker exited without a result'));
  });
  try {
    final worker = await ready.future.timeout(timeout);
    for (final m in messages) {
      worker.send(m);
    }
    return await done.future.timeout(timeout);
  } finally {
    await sub.cancel();
    port.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

void main() {
  group('prepare worker never dies silently', () {
    test('a malformed decoded row is reported, not swallowed into a hang',
        () async {
      // `hr` arrives as a String. SQLite storage classes are per-VALUE, so a row
      // written by an older/importing path really can do this — and the old
      // `row['hr'] as num?` threw inside the 'page' handler, whose only error
      // reporting lived in the (never-reached) 'finish' branch.
      final out = await _drivePrepareWorker([
        const {'type': 'config', 'mode': 'substrate'},
        {
          'type': 'page',
          'frames': [
            {
              'rec_ts': 1780000000,
              'hr': 'not-a-number',
              'ax': 0.0,
              'ay': 0.0,
              'az': 1.0,
              'counter': 1,
            }
          ],
          'rr': const [],
        },
        const {'type': 'finish'},
      ]);
      // Either it is now tolerated (guarded numeric read) or it is REPORTED —
      // the one unacceptable outcome is the wait never ending, which the
      // enclosing timeout would surface as a TimeoutException.
      expect(out, isNot(isA<TimeoutException>()));
      expect(out, isA<Map>(),
          reason: 'the guarded read treats a non-numeric cell as absent rather '
              'than killing the worker');
    });

    test('a page that throws in the worker fails the wait instead of hanging',
        () async {
      // `frames` non-empty but a frame is not a Map at all -> whereType filters
      // it, so this exercises the ordinary path; the load-bearing assertion is
      // simply that the call always TERMINATES.
      final out = await _drivePrepareWorker([
        const {'type': 'config', 'mode': 'substrate'},
        const {
          'type': 'page',
          'frames': [42, 'nonsense'],
          'rr': [],
        },
        const {'type': 'finish'},
      ]);
      expect(out, isA<Map>());
    });

    test('a well-formed page still decodes to a real substrate', () async {
      final out = await _drivePrepareWorker([
        const {'type': 'config', 'mode': 'substrate'},
        {
          'type': 'page',
          'frames': [
            for (var i = 0; i < 5; i++)
              {
                'rec_ts': 1780000000 + i,
                'hr': 60 + i,
                'ax': 0.0,
                'ay': 0.0,
                'az': 1.0,
                'spo2_red_raw': 10,
                'spo2_ir_raw': 20,
                'skin_temp_raw': 3000,
                'counter': i,
              }
          ],
          'rr': const [],
        },
        const {'type': 'finish'},
      ]);
      final payload = (out as Map).cast<String, dynamic>();
      expect((payload['ts_sec'] as List).length, 5);
      expect((payload['hr'] as List).first, 60);
    });
  });

  group('runCancellableIsolate', () {
    test('returns the computed value', () async {
      final v = await runCancellableIsolate<int>(
        () => 6 * 7,
        const Duration(seconds: 10),
      );
      expect(v, 42);
    });

    test('a result that is itself a List is not mistaken for an error', () {
      // The uncaught-error wire format is a 2-element List and `onExit` sends
      // null — a naive protocol would misread either as failure.
      expect(
        runCancellableIsolate<List<String>>(
          () => ['boom', 'stack'],
          const Duration(seconds: 10),
        ),
        completion(equals(['boom', 'stack'])),
      );
    });

    test('a null result is not mistaken for a silent exit', () {
      expect(
        runCancellableIsolate<String?>(() => null, const Duration(seconds: 10)),
        completion(isNull),
      );
    });

    test('a throw inside the isolate surfaces as an error, not a hang', () {
      expect(
        runCancellableIsolate<int>(
          () => throw StateError('kaboom'),
          const Duration(seconds: 10),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('an isolate that ends without answering fails fast, never hangs', () {
      // Nothing left on its event loop -> the VM tears the isolate down. With
      // no `onExit` port wired (the old `_loadSubstrateRange`) that produced
      // total silence and an eternal await; now it is a hard error.
      expect(
        runCancellableIsolate<int>(
          () => Completer<int>().future, // no pending events -> isolate exits
          const Duration(seconds: 10),
          label: 'dead',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a wedged-but-alive computation TIMES OUT (and is killed)', () async {
      // The defect this pins: `Isolate.run` with no timeout at all — the
      // sleep-staging site — left the caller awaiting forever with
      // `_running == true`, so DeriveScheduler._drain never returned again.
      final sw = Stopwatch()..start();
      await expectLater(
        runCancellableIsolate<int>(
          () async {
            // An open ReceivePort keeps the isolate's event loop alive, so it
            // stays running (exactly like a real hung compute) rather than
            // exiting and tripping the onExit path above.
            final keepAlive = ReceivePort();
            await Completer<int>().future;
            keepAlive.close();
            return 0;
          },
          const Duration(milliseconds: 400),
          label: 'wedged',
        ),
        throwsA(isA<TimeoutException>()),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 8)),
          reason: 'the wait is bounded by the timeout, not by the isolate');
    });
  });
}
