// AlarmIntents.swift — Siri / Shortcuts entry points for the band alarm.
//
// WHAT SIRI CAN AND CANNOT DO HERE. "Hey Siri, set an alarm for 7" is a SYSTEM
// phrase owned by the Clock app; a third-party app cannot claim it, and Apple
// requires every AppShortcut phrase to contain the app name. So the working
// phrasing is "Hey Siri, set a Whoop alarm for 7am". That is a platform
// constraint, not a design choice, and no amount of phrase-tuning gets around
// it.
//
// WHY THE INTENT DOES NOT ARM THE BAND ITSELF. Arming means a BLE write, and
// the BLE engine lives in the Flutter isolate — which may not be running when
// Siri fires, and the band may not be connected even if it is. So the intent
// does the only thing it can do reliably: it QUEUES the request and opens the
// app. Dart drains the queue once it has a live connection.
//
// The consequence is honest and worth stating in the intent's own dialog: the
// alarm is REQUESTED here and only becomes real once the band confirms it.
// Telling the user "alarm set" at this point would be a lie whenever the strap
// is out of range.

import AppIntents
import Foundation

/// Shared queue between the intent and the Flutter side.
///
/// UserDefaults.standard rather than an App Group: these intents live in the
/// main app target, so there is no process boundary to cross, and adding a
/// group container would mean another entitlement for no benefit.
enum PendingAlarmStore {
  private static let epochKey = "openstrap.pending_alarm_epoch"
  private static let clearKey = "openstrap.pending_alarm_clear"

  /// Queue an arm request for [date].
  static func queue(_ date: Date) {
    let d = UserDefaults.standard
    d.set(Int(date.timeIntervalSince1970), forKey: epochKey)
    d.removeObject(forKey: clearKey)
  }

  /// Queue a disable request. Kept as a separate flag rather than a sentinel
  /// epoch so "cancel my alarm" can never be mistaken for "arm at time zero".
  static func queueClear() {
    let d = UserDefaults.standard
    d.removeObject(forKey: epochKey)
    d.set(true, forKey: clearKey)
  }

  /// Read and CLEAR the queue. Draining is destructive on purpose: a request
  /// that survived being read would be re-armed on every app resume.
  static func take() -> [String: Any] {
    let d = UserDefaults.standard
    var out: [String: Any] = [:]
    if let epoch = d.object(forKey: epochKey) as? Int {
      out["epoch"] = epoch
      d.removeObject(forKey: epochKey)
    }
    if d.bool(forKey: clearKey) {
      out["clear"] = true
      d.removeObject(forKey: clearKey)
    }
    return out
  }
}

// ── set ──────────────────────────────────────────────────────────────────────

@available(iOS 16.0, *)
struct SetWhoopAlarmIntent: AppIntent {
  static var title: LocalizedStringResource = "Set band alarm"
  static var description = IntentDescription(
    "Wake up to a haptic buzz on your WHOOP band instead of a phone alarm."
  )

  /// The app must come forward: arming needs the BLE engine, which only runs
  /// inside the app. Returning a "done" dialog without opening would leave the
  /// request sitting in the queue indefinitely.
  static var openAppWhenRun: Bool = true

  @Parameter(
    title: "Time",
    description: "What time to wake you.",
    kind: .time
  )
  var time: DateComponents

  static var parameterSummary: some ParameterSummary {
    Summary("Set a band alarm for \(\.$time)")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let target = Self.nextOccurrence(of: time)
    PendingAlarmStore.queue(target)

    let fmt = DateFormatter()
    fmt.timeStyle = .short
    fmt.dateStyle = .none
    // Deliberately "will buzz once your band connects", not "alarm set". The
    // write has not happened yet and may not succeed.
    // Built as one value first: IntentDialog's literal initialiser cannot take
    // a concatenated expression.
    let spoken =
      "Band alarm requested for \(fmt.string(from: target)). "
      + "It arms as soon as your band is connected."
    return .result(dialog: IntentDialog(stringLiteral: spoken))
  }

  /// Resolve a bare time to the next time it occurs.
  ///
  /// Siri gives an hour and minute with no date, so 7am at 9pm means tomorrow
  /// morning. Interpreting it as today would arm an alarm in the past, which
  /// the band silently never fires.
  static func nextOccurrence(of comps: DateComponents) -> Date {
    let cal = Calendar.current
    let now = Date()
    var wanted = DateComponents()
    wanted.hour = comps.hour ?? 7
    wanted.minute = comps.minute ?? 0
    wanted.second = 0
    guard
      let next = cal.nextDate(
        after: now,
        matching: wanted,
        matchingPolicy: .nextTime
      )
    else {
      return now.addingTimeInterval(60)
    }
    return next
  }
}

// ── cancel ───────────────────────────────────────────────────────────────────

@available(iOS 16.0, *)
struct CancelWhoopAlarmIntent: AppIntent {
  static var title: LocalizedStringResource = "Cancel band alarm"
  static var description = IntentDescription("Turn off the alarm on your band.")
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult & ProvidesDialog {
    PendingAlarmStore.queueClear()
    return .result(
      dialog: IntentDialog("Band alarm will be cleared once your band connects.")
    )
  }
}

// ── buzz test ────────────────────────────────────────────────────────────────

@available(iOS 16.0, *)
struct BuzzBandIntent: AppIntent {
  static var title: LocalizedStringResource = "Buzz my band"
  static var description = IntentDescription(
    "Fire the alarm haptics now, to check the band actually buzzes."
  )
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult & ProvidesDialog {
    UserDefaults.standard.set(true, forKey: "openstrap.pending_alarm_buzz")
    return .result(dialog: IntentDialog("Buzzing your band."))
  }
}

// The Siri phrases for these live in OpenStrapIntents.swift's
// `OpenStrapShortcuts` — iOS allows exactly ONE AppShortcutsProvider per app,
// so a second one here is a build error, not a merge conflict to resolve later.
