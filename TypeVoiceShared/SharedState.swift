import Foundation

enum TypeVoiceStatus: String {
    case idle
    case ready
    case starting
    case recording
    case transcribing
    case polishing
    case failed
}

enum TypeVoiceLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh"
    case english = "en"

    var id: String { rawValue }
}

enum SharedKeys {
    static let interfaceLanguage = "typevoice.interfaceLanguage"
    static let quickDictationEnabled = "typevoice.quickDictationEnabled"
    static let quickStandbySeconds = "typevoice.quickStandbySeconds"
    static let serviceStandbySeconds = "typevoice.serviceStandbySeconds.v2"
    static let cleanupModel = "typevoice.cleanupModel"
    static let cleanupEnabled = "typevoice.cleanupEnabled"
}

enum SharedStore {
    // AltServer/free signing cannot be relied on for App Group sharing.
    // Core app↔keyboard communication uses LocalBridge on 127.0.0.1.
    // These defaults are intentionally local to the containing app.
    static var defaults: UserDefaults { .standard }

    static var interfaceLanguage: TypeVoiceLanguage {
        get {
            TypeVoiceLanguage(
                rawValue: defaults.string(forKey: SharedKeys.interfaceLanguage) ?? ""
            ) ?? .chinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: SharedKeys.interfaceLanguage)
        }
    }

    static var quickDictationEnabled: Bool {
        get {
            defaults.bool(forKey: SharedKeys.quickDictationEnabled)
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.quickDictationEnabled)
        }
    }

    static var quickStandbySeconds: Int {
        get {
            let value = defaults.integer(forKey: SharedKeys.quickStandbySeconds)
            return value == 0 ? 60 : value
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.quickStandbySeconds)
        }
    }

    static var serviceStandbySeconds: Int {
        get {
            guard defaults.object(forKey: SharedKeys.serviceStandbySeconds) != nil else {
                return 10
            }
            let value = defaults.integer(forKey: SharedKeys.serviceStandbySeconds)
            return [0, 10, 30, 60, 300].contains(value) ? value : 10
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.serviceStandbySeconds)
        }
    }

    static var cleanupEnabled: Bool {
        get {
            guard defaults.object(forKey: SharedKeys.cleanupEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: SharedKeys.cleanupEnabled)
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.cleanupEnabled)
        }
    }

    static var cleanupModel: String {
        get {
            defaults.string(forKey: SharedKeys.cleanupModel) ?? "gpt-5.6-luna"
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.cleanupModel)
        }
    }
}
