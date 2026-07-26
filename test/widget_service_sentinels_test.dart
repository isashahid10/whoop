// The home-widget / watch snapshot is a WRITE-ONLY surface: whatever Dart puts
// in the App Group is what the user sees on their lock screen, with no chance
// to notice it was invented. Every int key uses -1 for "no data" and the native
// readers gate on it — so a nullable metric must never be written as a plausible
// default instead.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/widget/widget_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, Object?> written;

  setUp(() {
    written = {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('home_widget'),
        (call) async {
      if (call.method == 'saveWidgetData') {
        final args = (call.arguments as Map).cast<String, Object?>();
        written[args['id'] as String] = args['data'];
      }
      return true;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('openstrap/ios_config'),
        (call) async => call.method == 'appGroupIdentifier' ? 'group.test' : null);
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('home_widget'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('openstrap/ios_config'), null);
  });

  test('an underived sleep need is written as the -1 sentinel, not a fabricated '
      '8h00m', () async {
    await WidgetService.push(TodayData.fromJson({
      'daily': {
        'readiness': {'value': 74},
      },
      // duration_min is known; need_min is NOT derived yet.
      'sleep': {'duration_min': 437},
    }));

    expect(written['sleep_min'], 437);
    // 480 here put a hard 8h00m need on the home widget AND the watch, and the
    // sleep ring was drawn as a fraction of that invented denominator.
    expect(written['sleep_need_min'], -1);
    // The convention it now matches.
    expect(written['rhr'], -1);
    expect(written['hrv'], -1);
  });

  test('a real sleep need is still written through', () async {
    await WidgetService.push(TodayData.fromJson({
      'daily': const {},
      'sleep': {'duration_min': 437, 'need_min': 462},
    }));
    expect(written['sleep_need_min'], 462);
  });
}
