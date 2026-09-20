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
    static let quickStandbySeconds = "typevoice.quickStandbySeconds"
    static let cleanupModel = "typevoice.cleanupModel"
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

    static var quickStandbySeconds: Int {
        get {
            let value = defaults.integer(forKey: SharedKeys.quickStandbySeconds)
            return value == 0 ? 60 : value
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.quickStandbySeconds)
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
