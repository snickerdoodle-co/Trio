import Foundation

struct NightscoutStatus: JSON {
    let device: String
    let openaps: OpenAPSStatus
    let pump: NSPumpStatus
    /// nil for a past loop, whose phone battery isn't known.
    let uploader: Uploader?
    /// The loop's own time; without it Nightscout stamps the status when it arrives.
    var created_at: Date? = nil
    /// The Apple Watch's battery, when it reported one within the last hour (LoopFollow shows it; Nightscout and
    /// other followers ignore the field).
    var watchBattery: WatchBattery? = nil
}

/// The Apple Watch's battery as the watch last reported it.
struct WatchBattery: JSON {
    let battery: Int
    let isCharging: Bool
    let timestamp: Date

    private static let key = "trio.watchBattery"
    /// Older than this it is no longer worth showing.
    static let maxAge: TimeInterval = 60 * 60

    static func store(_ payload: [String: Any]) {
        guard let percent = (payload["percent"] as? NSNumber)?.intValue,
              let at = payload["date"] as? TimeInterval
        else { return }
        let charging = payload["charging"] as? Bool ?? false
        UserDefaults.standard.set(["percent": percent, "charging": charging, "date": at], forKey: key)
    }

    static var latest: WatchBattery? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key),
              let percent = (saved["percent"] as? NSNumber)?.intValue,
              let at = saved["date"] as? TimeInterval
        else { return nil }
        let date = Date(timeIntervalSince1970: at)
        guard Date().timeIntervalSince(date) < maxAge else { return nil }
        return WatchBattery(battery: percent, isCharging: saved["charging"] as? Bool ?? false, timestamp: date)
    }
}

struct OpenAPSStatus: JSON {
    let iob: IOBEntry?
    let suggested: Determination?
    let enacted: Determination?
    let version: String
    let recommendedBolus: Decimal?
    /// Raw value, not the localized name: followers parse this.
    let dosingMode: String
    /// The IOB projection whose first value is `iob`.
    var iobForecast: NightscoutIOBForecast? = nil
}

/// IOB and insulin activity every five minutes from `iob.time`, for the
/// insulin already delivered and the running temp basal until it ends.
struct NightscoutIOBForecast: JSON {
    let iob: [Decimal]
    /// U/min, like `IOBEntry.activity`.
    let activity: [Decimal]

    init(_ entries: [IOBEntry]) {
        iob = entries.map { $0.iob.rounded(toPlaces: 3) }
        activity = entries.map { $0.activity.rounded(toPlaces: 5) }
    }
}

struct NSPumpStatus: JSON {
    let clock: Date
    let battery: Battery?
    let reservoir: Decimal?
    let status: PumpStatus?
    let bolusIncrement: Decimal
}

struct Uploader: JSON {
    let batteryVoltage: Decimal?
    let battery: Int
    let isCharging: Bool?
}

struct NightscoutTimevalue: JSON {
    let time: String
    let value: Decimal
    let timeAsSeconds: Int?
}

struct ScheduledNightscoutProfile: JSON {
    let dia: Decimal
    let carbs_hr: Int
    let delay: Decimal
    let timezone: String
    let target_low: [NightscoutTimevalue]
    let target_high: [NightscoutTimevalue]
    let sens: [NightscoutTimevalue]
    let basal: [NightscoutTimevalue]
    let carbratio: [NightscoutTimevalue]
    let units: String
}

struct NightscoutProfileStore: JSON {
    let defaultProfile: String
    let startDate: Date
    let mills: Int
    let units: String
    let enteredBy: String
    let store: [String: ScheduledNightscoutProfile]
    let bundleIdentifier: String
    let deviceToken: String
    let isAPNSProduction: Bool
    let overridePresets: [NightscoutPresetOverride]?
    let teamID: String
    let expirationDate: Date?
    /// Remote command types this build accepts; followers hide unsupported actions.
    let remoteCommands: [String]?
    /// The Apple Watch app's push token and bundle identifier, for a follower to send a remote bolus or meal straight
    /// to the watch while it runs the loop untethered. Left out without a watch.
    var watchDeviceToken: String? = nil
    var watchBundleIdentifier: String? = nil
}

struct NightscoutPresetOverride: JSON {
    let name: String
    let duration: Decimal?
    let percentage: Double?
    let target: Decimal?
}
