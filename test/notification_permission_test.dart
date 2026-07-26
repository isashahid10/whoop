// Regression tests for NotificationService's permission cache.
//
// `_granted` used to latch for the whole process the first time
// ensurePermission() ran, and NOTHING ever reset it. The prompt fires from
// AppState._persistPaired (right after pairing), so a user who tapped "Don't
// Allow" there, then went to OS Settings and enabled notifications, and came
// back, still got nothing: every presentEvent / scheduleDaily / scheduleWeekly /
// scheduleOnce early-returned on the stale `false`. Zero notifications and zero
// scheduled reminders until a full app restart.
//
// Fixed two ways, both covered below:
//   • only a GRANT is cached — a denial is re-read from the live (non-prompting)
//     OS state on the next call;
//   • invalidatePermissionCache() drops a cached grant too, so a REVOCATION is
//     noticed. app.dart calls it on every foreground resume.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/notify/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = NotificationService.instance;

  setUp(() {
    svc.invalidatePermissionCache();
    svc.debugRequestPermission = null;
    svc.debugProbePermission = null;
  });

  tearDown(() {
    svc.invalidatePermissionCache();
    svc.debugRequestPermission = null;
    svc.debugProbePermission = null;
  });

  test('a denial is NOT cached forever — enabling in OS Settings takes effect '
      'without an app restart', () async {
    var osEnabled = false;
    var prompts = 0;
    svc.debugProbePermission = () async => osEnabled;
    svc.debugRequestPermission = () async {
      prompts++;
      return osEnabled; // the user taps "Don't Allow"
    };

    expect(await svc.ensurePermission(), isFalse);
    expect(prompts, 1);

    // User goes to Settings and switches notifications ON.
    osEnabled = true;

    expect(await svc.ensurePermission(), isTrue,
        reason: 'a stale cached denial must not survive the user enabling '
            'notifications in OS Settings');
    // And we did NOT re-prompt to discover it (the OS no-ops a second request
    // after a denial anyway — Settings is the only real path back).
    expect(prompts, 1);
  });

  test('a denial that is still a denial keeps returning false (and does not '
      're-prompt)', () async {
    var prompts = 0;
    svc.debugProbePermission = () async => false;
    svc.debugRequestPermission = () async {
      prompts++;
      return false;
    };
    expect(await svc.ensurePermission(), isFalse);
    expect(await svc.ensurePermission(), isFalse);
    expect(await svc.ensurePermission(), isFalse);
    expect(prompts, 1);
  });

  test('a GRANT is cached — no repeated platform round-trips', () async {
    var probes = 0, prompts = 0;
    svc.debugProbePermission = () async {
      probes++;
      return true;
    };
    svc.debugRequestPermission = () async {
      prompts++;
      return true;
    };
    expect(await svc.ensurePermission(), isTrue);
    expect(await svc.ensurePermission(), isTrue);
    expect(prompts, 1);
    expect(probes, 0);
  });

  test('invalidatePermissionCache re-reads a REVOKED grant', () async {
    var osEnabled = true;
    svc.debugProbePermission = () async => osEnabled;
    svc.debugRequestPermission = () async => osEnabled;

    expect(await svc.ensurePermission(), isTrue);

    // Revoked in Settings while we were backgrounded.
    osEnabled = false;
    expect(await svc.ensurePermission(), isTrue,
        reason: 'still the cached grant until the resume hook runs');

    svc.invalidatePermissionCache(); // what app.dart does on resume
    expect(await svc.ensurePermission(), isFalse);
  });

  test('allowPrompt:false never prompts, and a not-yet-decided state is not '
      'cached as denied', () async {
    var prompts = 0;
    var osEnabled = false;
    svc.debugProbePermission = () async => osEnabled;
    svc.debugRequestPermission = () async {
      prompts++;
      return true;
    };

    // Headless caller (background_sync) checks, never requests.
    expect(await svc.ensurePermission(allowPrompt: false), isFalse);
    expect(prompts, 0);

    // A later foreground, contextual call still gets to ask.
    osEnabled = true;
    expect(await svc.ensurePermission(), isTrue);
    expect(prompts, 1);
  });
}
