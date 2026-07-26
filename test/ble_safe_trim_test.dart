// Regression tests for the SAFE-TRIM invariant and the offload-transport
// guards around it.
//
// THE INVARIANT: the durable commit (decoded_onehz + decoded_rr + cursor +
// raw_archive, one transaction) must be durable BEFORE the engine echoes the
// verbatim 8-byte HISTORY_END token, because that echo is what makes the band
// trim the chunk out of its flash. The happy path always honoured it; every
// test here covers a FAILURE path that did not.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

/// A well-formed inner-frame hex: [0]=0x2f historical, [1]=0x18 (revision 24),
/// then the u32 record counter. BurstStats re-parses this, so it must be real
/// hex, not a label.
String _hex(int counter) =>
    '2f18${counter.toRadixString(16).padLeft(8, '0')}';

RawRecord _raw(int counter) => RawRecord(
  counter: counter,
  packetType: 0x2f,
  hex: _hex(counter),
  capturedAt: 1780000000000 + counter,
  recTs: 1780000000 + counter,
);

Sample _sample(int counter) =>
    Sample(tsEpoch: 1780000000 + counter, counter: counter, hr: 60);

ArchiveRecord _archive(int counter) => ArchiveRecord(
  counter: counter,
  hex: _hex(counter),
  packetType: 0x2f,
  capturedAt: 1780000000000 + counter,
  reason: 'undecodable_rec_v99',
);

const _tokenA = <int>[1, 2, 3, 4, 5, 6, 7, 8];
const _tokenB = <int>[9, 9, 9, 9, 9, 9, 9, 9];

/// A drain controller wired to [onCommit], the atomic-commit sink the real
/// engine points at `LocalDb.commitSyncBatch`.
DrainController _drainWith(CommitSyncBatchSink onCommit, {List<String>? logs}) =>
    DrainController(
      onRecord: (sample, raw) async {},
      onRecordsBatch: null,
      onCommit: onCommit,
      onArchive: null,
      log: (line) => logs?.add(line),
    );

void main() {
  group('P0 — a durable commit that fails must not let the caller ACK', () {
    test('commit() REPORTS failure instead of swallowing the exception', () async {
      final d = _drainWith(
        (raws, samples, token, {archives}) async =>
            throw StateError('OOM in SqlCommand.getSqlArguments'),
      );
      d.onHistoricalRecord(_raw(1), _sample(1));

      final durable = await d.commit(_tokenA);

      // OLD BEHAVIOUR: commit() was Future<void> — it logged 'offload commit
      // error' and returned normally, and the caller unconditionally built and
      // wrote buildHistoryResultOk(), so the band trimmed a chunk that had
      // rolled back. There was no success signal to check at all.
      expect(durable, isFalse);
    });

    test('a failed commit RE-BUFFERS the records instead of losing them', () async {
      final d = _drainWith(
        (raws, samples, token, {archives}) async => throw StateError('rollback'),
      );
      d.onHistoricalRecord(_raw(1), _sample(1));
      d.onHistoricalRecord(_raw(2), _sample(2));
      d.onUndecodableRecord(_archive(3));

      expect(d.bufferedRecords, 2);
      final durable = await d.commit(_tokenA);

      expect(durable, isFalse);
      // OLD BEHAVIOUR: the buffer was snapshotted and CLEARED before the
      // commit, and the exception was swallowed — so with the transaction
      // rolled back and the cursor unadvanced, those rows existed nowhere.
      expect(d.bufferedRecords, 2);

      // Proof they are really still there: a later successful commit ships
      // every record AND the archived one.
      final seenRaws = <String>[];
      final seenArchives = <String>[];
      final d2 = _drainWith((raws, samples, token, {archives}) async {
        seenRaws.addAll(raws.map((r) => r.hex));
        seenArchives.addAll((archives ?? const []).map((a) => a.hex));
      });
      // (rebuild the same state on a controller whose commit succeeds)
      d2.onHistoricalRecord(_raw(1), _sample(1));
      d2.onHistoricalRecord(_raw(2), _sample(2));
      d2.onUndecodableRecord(_archive(3));
      expect(await d2.commit(_tokenA), isTrue);
      expect(seenRaws, [_hex(1), _hex(2)]);
      expect(seenArchives, [_hex(3)]);
    });

    test(
      're-buffered records keep arrival order ahead of records that landed '
      'during the failing await',
      () async {
        final gate = Completer<void>();
        var fail = true;
        final shipped = <String>[];
        final d = DrainController(
          onRecord: (sample, raw) async {},
          onRecordsBatch: null,
          onCommit: (raws, samples, token, {archives}) async {
            if (fail) {
              await gate.future;
              throw StateError('rollback');
            }
            shipped.addAll(raws.map((r) => r.hex));
          },
          onArchive: null,
          log: (_) {},
        );

        d.onHistoricalRecord(_raw(1), _sample(1));
        final inFlight = d.commit(_tokenA);
        // A record arrives while the commit is parked mid-await.
        d.onHistoricalRecord(_raw(2), _sample(2));
        gate.complete();
        expect(await inFlight, isFalse);

        expect(d.bufferedRecords, 2);
        fail = false;
        expect(await d.commit(_tokenA), isTrue);
        expect(shipped, [_hex(1), _hex(2)]);
      },
    );

    test('a failed commit rolls back the trim-advance bookkeeping', () async {
      var fail = false;
      final d = DrainController(
        onRecord: (sample, raw) async {},
        onRecordsBatch: null,
        onCommit: (raws, samples, token, {archives}) async {
          if (fail) throw StateError('rollback');
        },
        onArchive: null,
        log: (_) {},
      );

      expect(await d.commit(_tokenA), isTrue);
      expect(d.lastTrimAdvanced, isTrue);

      fail = true;
      d.onHistoricalRecord(_raw(1), _sample(1));
      expect(await d.commit(_tokenB), isFalse);
      // The cursor did NOT move to tokenB, so nothing may claim it did.
      expect(d.lastTrimAdvanced, isTrue, reason: 'rolled back to the tokenA state');

      // And when tokenB is finally committed for real it still counts as an
      // ADVANCE. Without the rollback, _lastAckedToken was already tokenB, so
      // the real commit reported "no advance" and BackfillContinuation refused
      // to auto-continue a drain that had in fact progressed.
      fail = false;
      expect(await d.commit(_tokenB), isTrue);
      expect(d.lastTrimAdvanced, isTrue);
    });

    test('a successful commit clears the buffer and reports durable', () async {
      final d = _drainWith((raws, samples, token, {archives}) async {});
      d.onHistoricalRecord(_raw(1), _sample(1));

      expect(await d.commit(_tokenA), isTrue);
      expect(d.bufferedRecords, 0);
    });
  });

  group('P0 — TrimAckPolicy gates the one irreversible act', () {
    test('a commit that did not become durable blocks the ACK', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: false,
        ),
        TrimAckVerdict.blockedCommitFailed,
      );
    });

    test('a stale session blocks the ACK', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: false,
          burstDiscarded: false,
          commitDurable: true,
        ),
        TrimAckVerdict.blockedStaleSession,
      );
    });

    test('a discarded burst blocks the ACK even when the commit succeeded', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: true,
          commitDurable: true,
        ),
        TrimAckVerdict.blockedDiscardedBurst,
      );
    });

    test('a stale session outranks every other reason — nothing may touch the '
        'new link', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: false,
          burstDiscarded: true,
          commitDurable: false,
        ),
        TrimAckVerdict.blockedStaleSession,
      );
    });

    test('a discarded burst outranks a durable commit result', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: true,
          commitDurable: false,
        ),
        TrimAckVerdict.blockedDiscardedBurst,
      );
    });

    test('every precondition holding is the ONLY way to send', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: true,
        ),
        TrimAckVerdict.send,
      );
    });
  });

  group('P0 — a discarded burst poisons its HISTORY_END token', () {
    test('discardOpenChunk marks the open burst un-ACKable', () async {
      final d = _drainWith((raws, samples, token, {archives}) async {});
      d.onHistoricalRecord(_raw(1), _sample(1));
      expect(d.burstDiscarded, isFalse);

      d.discardOpenChunk();

      // OLD BEHAVIOUR: the records were dropped and NOTHING recorded it, so
      // the straggler HISTORY_END (already in flight when the idle watchdog
      // fired) committed an empty buffer and echoed the token verbatim — the
      // band then trimmed exactly the records that had just been thrown away.
      expect(d.burstDiscarded, isTrue);
      expect(d.bufferedRecords, 0);
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: d.burstDiscarded,
          commitDurable: true,
        ),
        TrimAckVerdict.blockedDiscardedBurst,
      );
    });

    test('poisons even when the open buffer is already empty', () {
      final d = _drainWith((raws, samples, token, {archives}) async {});
      d.discardOpenChunk();
      expect(d.burstDiscarded, isTrue);
    });

    test('a fresh burst (rearm / HISTORY_START) clears the poison', () {
      final d = _drainWith((raws, samples, token, {archives}) async {});
      d.discardOpenChunk();
      expect(d.burstDiscarded, isTrue);

      d.rearm();

      expect(d.burstDiscarded, isFalse);
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: d.burstDiscarded,
          commitDurable: true,
        ),
        TrimAckVerdict.send,
      );
    });

    test('poisonedBursts counts once per burst, not once per discard call', () {
      final d = _drainWith((raws, samples, token, {archives}) async {});
      d.discardOpenChunk();
      d.discardOpenChunk();
      expect(d.poisonedBursts, 1);
      d.rearm();
      d.discardOpenChunk();
      expect(d.poisonedBursts, 2);
    });
  });

  group('BurstTrimGuard', () {
    test('starts un-poisoned', () {
      expect(BurstTrimGuard().discarded, isFalse);
    });

    test('a discard latches until the next burst begins', () {
      final g = BurstTrimGuard();
      g.discardOpenChunk();
      expect(g.discarded, isTrue);
      g.beginBurst();
      expect(g.discarded, isFalse);
      expect(g.poisonedBursts, 1);
    });
  });

  group('P2 — a corrupt far-future RTC read is not a clock correlation', () {
    const wallNow = 1780000000;

    test('a read implausibly far in the future is refused', () {
      expect(
        ClockPolicy.acceptsClockRead(wallNow + 20 * 365 * 86400, wallNow),
        isFalse,
      );
    });

    test('a normal read is accepted', () {
      expect(ClockPolicy.acceptsClockRead(wallNow - 12, wallNow), isTrue);
    });

    test('an unset/behind RTC is still accepted — this gate is future-only', () {
      // Those go to ClockPolicy.shouldSetClock, which corrects them; refusing
      // them here would break the ordinary drift-correction path.
      expect(ClockPolicy.acceptsClockRead(1600000000, wallNow), isTrue);
    });

    test('small clock skew inside the future margin is accepted', () {
      expect(ClockPolicy.acceptsClockRead(wallNow + 60, wallNow), isTrue);
    });

    test(
      'trusting a corrupt read would arm the wake alarm years out — the exact '
      'failure the gate prevents',
      () {
        final corrupt = wallNow + 20 * 365 * 86400;
        final ref = ClockRef(device: corrupt, wall: wallNow);
        expect(ref.driftSec, lessThan(0));

        final target = DateTime.fromMillisecondsSinceEpoch(wallNow * 1000)
            .add(const Duration(hours: 8));
        final armed = AlarmPayloads.toStrapFrame(target, ref.driftSec);

        // setAlarm does when.subtract(driftSec); a negative drift pushes the
        // armed epoch decades into the future, where it silently never fires.
        expect(armed.difference(target).inDays, greaterThan(5 * 365));
        // …which is why the read never becomes a ClockRef in the first place.
        expect(ClockPolicy.acceptsClockRead(corrupt, wallNow), isFalse);
      },
    );
  });
}
