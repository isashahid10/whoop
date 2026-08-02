// AlarmBridge.swift — the Dart side of the Siri alarm queue, plus the
// phone-side AlarmKit backup.
//
// TWO ALARMS, DIFFERENT JOBS.
//
//   * The BAND alarm is the real one. It runs off the strap's own RTC, so it
//     fires whether or not the phone is nearby, silenced, in a Focus mode, or
//     dead. That already answers "what if my phone is on Do Not Disturb" —
//     the band does not consult the phone at all.
//
//   * The ALARMKIT alarm is a BACKUP for the case the band cannot cover: it is
//     off your wrist, out of battery, or was never connected when the alarm was
//     armed. AlarmKit (iOS 26+) is the only third-party API that breaks through
//     silent mode and Focus, which is exactly why a plain local notification is
//     not good enough here.
//
// The backup is opt-in per alarm and defaults ON, because an alarm that
// silently fails to wake you is worse than one that wakes you twice.

import Flutter
import Foundation

#if canImport(AlarmKit)
  import AlarmKit
#endif

enum AlarmBridge {
  private static let channelName = "openstrap/alarm_intent"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {

      // Drain anything Siri queued while the app was closed or the band was
      // out of range. Destructive read — see PendingAlarmStore.take().
      case "takePending":
        var out = PendingAlarmStore.take()
        let d = UserDefaults.standard
        if d.bool(forKey: "openstrap.pending_alarm_buzz") {
          out["buzz"] = true
          d.removeObject(forKey: "openstrap.pending_alarm_buzz")
        }
        result(out)

      case "backupSupported":
        if #available(iOS 26.0, *) {
          #if canImport(AlarmKit)
            result(true)
          #else
            result(false)
          #endif
        } else {
          result(false)
        }

      case "authorizeBackup":
        if #available(iOS 26.0, *) {
          #if canImport(AlarmKit)
            Task {
              let ok = await AlarmKitBackup.authorize()
              result(ok)
            }
          #else
            result(false)
          #endif
        } else {
          result(false)
        }

      case "scheduleBackup":
        let args = call.arguments as? [String: Any] ?? [:]
        guard let epoch = args["epoch"] as? Int else {
          result(false)
          return
        }
        if #available(iOS 26.0, *) {
          #if canImport(AlarmKit)
            Task {
              let ok = await AlarmKitBackup.schedule(
                at: Date(timeIntervalSince1970: TimeInterval(epoch)),
                label: args["label"] as? String ?? "Wake up"
              )
              result(ok)
            }
          #else
            result(false)
          #endif
        } else {
          result(false)
        }

      // Every alarm AlarmKit currently holds for us, as epoch seconds. Used by
      // the app's "upcoming alarms" list: without reading back from the
      // framework the UI could only show what it THINKS it scheduled, which
      // silently diverges the moment an alarm fires or the user stops one.
      case "pendingBackups":
        if #available(iOS 26.0, *) {
          #if canImport(AlarmKit)
            result(AlarmKitBackup.pendingEpochs())
          #else
            result([Int]())
          #endif
        } else {
          result([Int]())
        }

      case "cancelBackup":
        if #available(iOS 26.0, *) {
          #if canImport(AlarmKit)
            AlarmKitBackup.cancelAll()
            result(true)
          #else
            result(false)
          #endif
        } else {
          result(false)
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
