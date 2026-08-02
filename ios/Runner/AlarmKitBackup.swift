// AlarmKitBackup.swift — the phone-side alarm that breaks through silent mode.
//
// This exists ONLY as a safety net. The band alarm is the real one: it runs off
// the strap's own RTC and does not consult the phone, so Do Not Disturb, Focus,
// the ringer switch and even a flat phone battery are all irrelevant to it.
//
// What the band CANNOT cover is being off your wrist, out of charge, or never
// connected when the alarm was armed. AlarmKit (iOS 26+) is the only
// third-party API allowed to break through silent mode and Focus, which is why
// a plain UNNotification is not an acceptable substitute here — it would be
// silenced by exactly the conditions this is meant to survive.

import Foundation

#if canImport(AlarmKit)
  import AlarmKit
  import AppIntents

  /// AlarmKit requires a metadata type on the alarm's attributes even when
  /// there is nothing app-specific to carry.
  @available(iOS 26.0, *)
  struct WhoopAlarmMetadata: AlarmMetadata {
    init() {}
  }

  @available(iOS 26.0, *)
  enum AlarmKitBackup {
    typealias Manager = AlarmManager

    /// Ask once. AlarmKit refuses to schedule without this, and the prompt is
    /// the user's only chance to decline a full-screen breakthrough alarm.
    static func authorize() async -> Bool {
      do {
        let state = try await Manager.shared.requestAuthorization()
        return state == .authorized
      } catch {
        return false
      }
    }

    /// Schedule a one-shot backup alarm at [date].
    ///
    /// Any previously scheduled backup is cancelled first: there is only ever
    /// one wake alarm, and leaving a stale one behind would wake the user at a
    /// time they had already changed.
    static func schedule(at date: Date, label: String) async -> Bool {
      cancelAll()

      guard await authorize() else { return false }

      let alertButton = AlarmButton(
        text: "Stop",
        textColor: .white,
        systemImageName: "stop.fill"
      )
      let alert = AlarmPresentation.Alert(
        title: LocalizedStringResource(stringLiteral: label),
        stopButton: alertButton
      )
      let attributes = AlarmAttributes<WhoopAlarmMetadata>(
        presentation: AlarmPresentation(alert: alert),
        metadata: WhoopAlarmMetadata(),
        tintColor: .orange
      )

      let schedule = Alarm.Schedule.fixed(date)
      let config = AlarmManager.AlarmConfiguration<WhoopAlarmMetadata>(
        schedule: schedule,
        attributes: attributes
      )

      do {
        _ = try await Manager.shared.schedule(id: UUID(), configuration: config)
        return true
      } catch {
        return false
      }
    }

    /// Fire times of every alarm AlarmKit still holds, as epoch seconds.
    ///
    /// Read back from the framework rather than mirrored in app state: an
    /// alarm that has already fired, or that the user stopped from the Lock
    /// Screen, is gone from AlarmKit but would still be sitting in any local
    /// copy — and an "upcoming alarms" list showing one that cannot ring is
    /// worse than showing none.
    static func pendingEpochs() -> [Int] {
      guard let alarms = try? Manager.shared.alarms else { return [] }
      var out: [Int] = []
      for alarm in alarms {
        if case let .fixed(date) = alarm.schedule {
          out.append(Int(date.timeIntervalSince1970))
        }
      }
      return out.sorted()
    }

    /// Remove every alarm this app scheduled.
    static func cancelAll() {
      guard let alarms = try? Manager.shared.alarms else { return }
      for alarm in alarms {
        try? Manager.shared.cancel(id: alarm.id)
      }
    }
  }
#endif
