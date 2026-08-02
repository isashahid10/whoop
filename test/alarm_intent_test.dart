// Siri band-alarm queue.
//
// The risky part is not the BLE write - it is the QUEUE. Siri fires when the
// band is out of range, so a request has to survive until it can be delivered
// without being delivered twice, and a delivery that fails must not be retried
// forever. Those are the properties tested here, at the channel boundary.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/platform/alarm_intents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('openstrap/alarm_intent');
  late List<MethodCall> calls;
  Map<String, dynamic> pending = {};

  setUp(() {
    calls = [];
    pending = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'takePending':
          // Mirrors the native contract: reading DRAINS.
          final out = Map<String, dynamic>.from(pending);
          pending = {};
          return out;
        case 'backupSupported':
        case 'authorizeBackup':
        case 'scheduleBackup':
        case 'cancelBackup':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('takePending', () {
    test('an empty queue is empty, not a zero-epoch request', () async {
      final p = await AlarmIntents.takePending();
      expect(p.isEmpty, isTrue);
      expect(p.epoch, isNull);
      expect(p.clear, isFalse);
    });

    test('an arm request carries its epoch', () async {
      pending = {'epoch': 1785196076};
      final p = await AlarmIntents.takePending();
      expect(p.epoch, 1785196076);
      expect(p.clear, isFalse);
      expect(p.isEmpty, isFalse);
    });

    test('a cancel is a FLAG, never a sentinel epoch', () async {
      // The distinction matters: an epoch of 0 would otherwise be
      // indistinguishable from "arm at the epoch", i.e. 1970.
      pending = {'clear': true};
      final p = await AlarmIntents.takePending();
      expect(p.clear, isTrue);
      expect(p.epoch, isNull);
    });

    test('reading DRAINS, so a request cannot be applied twice', () async {
      pending = {'epoch': 1785196076};
      expect((await AlarmIntents.takePending()).epoch, 1785196076);
      expect((await AlarmIntents.takePending()).isEmpty, isTrue);
    });

    test('a native failure yields an empty request, never a crash', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      expect((await AlarmIntents.takePending()).isEmpty, isTrue);
    });
  });

  group('backup', () {
    test('scheduleBackup sends whole seconds, not milliseconds', () async {
      final when = DateTime.fromMillisecondsSinceEpoch(1785196076789);
      await AlarmIntents.scheduleBackup(when, label: 'Wake up');
      final c = calls.firstWhere((c) => c.method == 'scheduleBackup');
      expect(c.arguments['epoch'], 1785196076);
      expect(c.arguments['label'], 'Wake up');
    });

    test('an unsupported OS reports false rather than throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => false);
      expect(await AlarmIntents.backupSupported(), isFalse);
      expect(await AlarmIntents.scheduleBackup(DateTime.now()), isFalse);
    });

    test('a thrown channel never propagates - a failed BACKUP must never look '
        'like a failed alarm', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'denied');
      });
      expect(await AlarmIntents.scheduleBackup(DateTime.now()), isFalse);
      expect(await AlarmIntents.cancelBackup(), isFalse);
      expect(await AlarmIntents.authorizeBackup(), isFalse);
    });
  });
}
