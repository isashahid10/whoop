// OpenStrap App Intents — Siri / Shortcuts / Spotlight / Ultra Action Button.
//
// Add to the Runner (iOS app) target. These read the phone's App Group snapshot
// (the same keys WidgetService writes) and answer spoken/dialog queries. Because
// they're AppShortcuts, they work with zero user setup: "Hey Siri, OpenStrap
// recovery". The Apple Watch Ultra's Action Button can be bound to any of these
// via Settings ▸ Action Button ▸ Shortcut.

import AppIntents
import Foundation

// MARK: - Shared reader

enum OpenStrapShared {
  static var appGroup: String {
    Bundle.main.object(forInfoDictionaryKey: "OpenStrapAppGroupIdentifier") as? String
      ?? "group.wtf.openstrap"
  }

  static func defaults() -> UserDefaults? { UserDefaults(suiteName: appGroup) }

  static var hasData: Bool { defaults()?.bool(forKey: "has_data") ?? false }
  static var readiness: Int { defaults()?.object(forKey: "readiness") as? Int ?? -1 }
  static var strain: Double { defaults()?.object(forKey: "strain") as? Double ?? -1 }
  static var hrv: Int { defaults()?.object(forKey: "hrv") as? Int ?? -1 }
  static var rhr: Int { defaults()?.object(forKey: "rhr") as? Int ?? -1 }
  static var sleepMin: Int { defaults()?.object(forKey: "sleep_min") as? Int ?? -1 }

  static var sleepText: String {
    guard sleepMin >= 0 else { return "no sleep data yet" }
    return "\(sleepMin / 60) hours \(sleepMin % 60) minutes"
  }
  static var noData: String { "I don't have today's numbers yet. Open Whoop and sync your strap." }
}

// MARK: - Intents

@available(iOS 16.0, *)
struct RecoveryIntent: AppIntent {
  static var title: LocalizedStringResource = "Check Recovery"
  static var description = IntentDescription("Ask Whoop for today's recovery.")
  static var openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard OpenStrapShared.hasData, OpenStrapShared.readiness >= 0 else {
      return .result(dialog: IntentDialog(stringLiteral: OpenStrapShared.noData))
    }
    let r = OpenStrapShared.readiness
    let tier = r < 34 ? "Take it easy today." : (r < 67 ? "A moderate day looks good." : "You're primed to push.")
    return .result(dialog: "Your recovery is \(r) percent. \(tier)")
  }
}

@available(iOS 16.0, *)
struct StrainIntent: AppIntent {
  static var title: LocalizedStringResource = "Check Strain"
  static var description = IntentDescription("Ask Whoop for today's strain.")
  static var openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard OpenStrapShared.hasData, OpenStrapShared.strain >= 0 else {
      return .result(dialog: IntentDialog(stringLiteral: OpenStrapShared.noData))
    }
    let s = String(format: "%.1f", OpenStrapShared.strain)
    return .result(dialog: "Today's strain so far is \(s) out of twenty-one.")
  }
}

@available(iOS 16.0, *)
struct SleepIntent: AppIntent {
  static var title: LocalizedStringResource = "Check Sleep"
  static var description = IntentDescription("Ask Whoop how you slept.")
  static var openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard OpenStrapShared.hasData, OpenStrapShared.sleepMin >= 0 else {
      return .result(dialog: IntentDialog(stringLiteral: OpenStrapShared.noData))
    }
    return .result(dialog: "You slept \(OpenStrapShared.sleepText) last night.")
  }
}

// MARK: - Action intents (these actually DO something, not just answer)

/// "Start breathing" — unlike the query intents above, this needs the live
/// Flutter engine + BLE stack (a guided session reads live RR from the band),
/// so it must open the app rather than answer standalone. Writes the target
/// route into the App Group; the Dart side picks it up via
/// WidgetService.consumePendingRoute() on launch AND on every foreground
/// resume (see AppState.checkPendingSiriRoute — openAppWhenRun doesn't
/// guarantee a fresh launch, it may just foreground an already-running
/// process, so both call sites matter).
@available(iOS 16.0, *)
struct StartBreathingIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Breathing Session"
  static var description = IntentDescription(
    "Start a guided resonance-breathing session in Whoop.")
  static var openAppWhenRun = true

  func perform() async throws -> some IntentResult & ProvidesDialog {
    OpenStrapShared.defaults()?.set("/breathing", forKey: "pending_route")
    return .result(dialog: "Starting your breathing session.")
  }
}

// MARK: - Shortcuts provider (zero-setup Siri phrases)

@available(iOS 16.0, *)
struct OpenStrapShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RecoveryIntent(),
      phrases: [
        "\(.applicationName) recovery",
        "What's my recovery in \(.applicationName)",
        "How recovered am I in \(.applicationName)",
      ],
      shortTitle: "Recovery",
      systemImageName: "bolt.heart")

    AppShortcut(
      intent: StrainIntent(),
      phrases: [
        "\(.applicationName) strain",
        "What's my strain in \(.applicationName)",
      ],
      shortTitle: "Strain",
      systemImageName: "flame")

    AppShortcut(
      intent: SleepIntent(),
      phrases: [
        "\(.applicationName) sleep",
        "How did I sleep in \(.applicationName)",
      ],
      shortTitle: "Sleep",
      systemImageName: "moon.zzz")

    AppShortcut(
      intent: StartBreathingIntent(),
      phrases: [
        "Start breathing in \(.applicationName)",
        "\(.applicationName) breathe",
        "Start a breathing session in \(.applicationName)",
        "Breathe with \(.applicationName)",
      ],
      shortTitle: "Breathe",
      systemImageName: "wind")

    // ── Band alarm (AlarmIntents.swift) ──
    //
    // Note what is NOT here: a bare "set an alarm" phrase. That belongs to the
    // system Clock app, and Apple requires every phrase below to contain
    // \(.applicationName), so the app name is always part of the utterance.
    // PHRASING NOTE. Any phrase containing the word "alarm" competes with the
    // system Clock intent, and Clock usually wins — the observed result is a
    // normal iPhone alarm merely LABELLED "Whoop". Apple gives third-party
    // intents no way to outrank a system one for its own vocabulary.
    //
    // So the phrases below lead with wordings that avoid "alarm" altogether
    // ("wake me", "buzz me"), which Clock does not claim. The "alarm" variants
    // are kept last as a fallback for the times Siri does route here.
    AppShortcut(
      intent: SetWhoopAlarmIntent(),
      phrases: [
        // CLOCK OWNS "alarm", "wake me" AND "wake up". All three fall through
        // to the system intent no matter how the app name is placed, which is
        // why every earlier variant still produced an iPhone alarm merely
        // LABELLED Whoop. The phrases below use vocabulary Clock does not
        // claim at all — "buzz" and "band" — so there is nothing for it to
        // match on. The "alarm" wordings stay last, purely as a fallback for
        // the cases Siri does route here.
        "Buzz my \(.applicationName) band",
        "\(.applicationName) band buzz",
        "Set a \(.applicationName) buzz",
        "Buzz me with \(.applicationName)",
        "Set a \(.applicationName) band alarm",
        "Set a \(.applicationName) alarm",
      ],
      shortTitle: "Set band alarm",
      systemImageName: "alarm")

    AppShortcut(
      intent: CancelWhoopAlarmIntent(),
      phrases: [
        "Cancel my \(.applicationName) alarm",
        "Turn off my \(.applicationName) alarm",
      ],
      shortTitle: "Cancel band alarm",
      systemImageName: "alarm.slash")

    AppShortcut(
      intent: BuzzBandIntent(),
      phrases: [
        // Deliberately NOT "buzz my band" — that now belongs to the alarm
        // SETTER above, and two shortcuts competing for one phrase means Siri
        // picks arbitrarily.
        "Test my \(.applicationName) band",
        "Check my \(.applicationName) buzz",
      ],
      shortTitle: "Buzz band",
      systemImageName: "waveform")
  }
}
