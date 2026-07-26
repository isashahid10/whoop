// WatchMetrics — the today snapshot the watch renders.
//
// Add this file to BOTH watch targets (the Watch App and the Watch Widget
// Extension). The watch app's WatchStore receives the payload over WCSession and
// writes it into the watch-side App Group; the complication widget reads the same
// suite. (The watch app and its widget extension are separate processes, so they
// share via a watch App Group — NOT the phone's App Group.)

import Foundation

enum WatchConfig {
  /// Watch-side App Group, shared between the Watch App and Watch Widget targets.
  /// Create this group and enable it on BOTH watch targets in Xcode.
  static let appGroup = "group.wtf.openstrap.watch"
}

struct WatchMetrics {
  var hasData: Bool
  var readiness: Int      // 0–100, -1 = none
  var strain: Double      // 0–21, -1 = none
  var sleepMin: Int       // minutes asleep, -1 = none
  var needMin: Int        // sleep need (min); -1 = none — never fabricate 8h
  var hrv: Int            // RMSSD ms, -1 = none
  var hrvBaseline: Int    // baseline RMSSD ms, -1 = none
  var rhr: Int            // bpm, -1 = none
  var coachLine: String
  var battPct: Int        // strap battery %, -1 = unknown
  var updatedAt: Int      // epoch sec
  var themeDark: Bool     // mirror the app's Ember-on-Paper (false) / Char (true)

  static let empty = WatchMetrics(
    hasData: false, readiness: -1, strain: -1, sleepMin: -1, needMin: -1,
    hrv: -1, hrvBaseline: -1, rhr: -1, coachLine: "", battPct: -1, updatedAt: 0,
    themeDark: true)

  static func load() -> WatchMetrics {
    let d = UserDefaults(suiteName: WatchConfig.appGroup)
    return WatchMetrics(
      hasData: d?.bool(forKey: "has_data") ?? false,
      readiness: d?.object(forKey: "readiness") as? Int ?? -1,
      strain: d?.object(forKey: "strain") as? Double ?? -1,
      sleepMin: d?.object(forKey: "sleep_min") as? Int ?? -1,
      needMin: d?.object(forKey: "sleep_need_min") as? Int ?? -1,
      hrv: d?.object(forKey: "hrv") as? Int ?? -1,
      hrvBaseline: d?.object(forKey: "hrv_baseline") as? Int ?? -1,
      rhr: d?.object(forKey: "rhr") as? Int ?? -1,
      coachLine: d?.string(forKey: "coach_line") ?? "",
      battPct: d?.object(forKey: "batt_pct") as? Int ?? -1,
      updatedAt: d?.object(forKey: "updated_at") as? Int ?? 0,
      themeDark: d?.object(forKey: "theme_dark") as? Bool ?? true)
  }

  // MARK: Display helpers

  var readinessText: String { readiness >= 0 ? "\(readiness)%" : "—" }
  var strainText: String { strain >= 0 ? String(format: "%.1f", strain) : "—" }
  var hrvText: String { hrv >= 0 ? "\(hrv)" : "—" }
  var rhrText: String { rhr >= 0 ? "\(rhr)" : "—" }
  var sleepText: String {
    guard sleepMin >= 0 else { return "—" }
    return "\(sleepMin / 60)h \(sleepMin % 60)m"
  }
  /// Recovery ring fraction 0–1.
  var readinessFraction: Double { readiness >= 0 ? Double(readiness) / 100.0 : 0 }
  /// Strain ring fraction 0–1 (0–21 scale).
  var strainFraction: Double { strain >= 0 ? min(strain / 21.0, 1) : 0 }
  /// Sleep-vs-need fraction 0–1.
  var sleepFraction: Double {
    guard sleepMin >= 0, needMin > 0 else { return 0 }
    return min(Double(sleepMin) / Double(needMin), 1)
  }

  /// WHOOP-style recovery color: red < 34, yellow 34–66, green ≥ 67.
  var recoveryTier: Int { readiness < 0 ? -1 : (readiness < 34 ? 0 : (readiness < 67 ? 1 : 2)) }
}
