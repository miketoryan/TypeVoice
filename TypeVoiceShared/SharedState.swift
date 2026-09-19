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
    static let status = "typevoice.status"
    static let serviceReady = "typevoice.serviceReady"
    static let serviceHeartbeat = "typevoice.serviceHeartbeat"
    static let serviceExpiresAt = "typevoice.serviceExpiresAt"

    static let startRequestID = "typevoice.startRequestID"
    static let startRequestAt = "typevoice.startRequestAt"
    static let stopRequestID = "typevoice.stopRequestID"
    static let cancelRequestID = "typevoice.cancelRequestID"

    static let resultID = "typevoice.resultID"
    static let resultText = "typevoice.resultText"
    static let resultCreatedAt = "typevoice.resultCreatedAt"
    static let resultAttemptedID = "typevoice.resultAttemptedID"
    static let resultInsertedID = "typevoice.resultInsertedID"

    static let lastError = "typevoice.lastError"

    static let interfaceLanguage = "typevoice.interfaceLanguage"
    static let quickMinutes = "typevoice.quickMinutes"
    static let apiBaseURL = "typevoice.apiBaseURL"
    static let transcriptionModel = "typevoice.transcriptionModel"
    static let cleanupModel = "typevoice.cleanupModel"
}

enum SharedStore {
    static let appGroupIdentifier = "group.com.miketoryan.typevoice"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static var status: TypeVoiceStatus {
        get {
            TypeVoiceStatus(rawValue: defaults.string(forKey: SharedKeys.status) ?? "") ?? .idle
        }
        set {
            defaults.set(newValue.rawValue, forKey: SharedKeys.status)
            defaults.synchronize()
        }
    }

    static var interfaceLanguage: TypeVoiceLanguage {
        get {
            TypeVoiceLanguage(rawValue: defaults.string(forKey: SharedKeys.interfaceLanguage) ?? "") ?? .chinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: SharedKeys.interfaceLanguage)
        }
    }

    static var quickMinutes: Int {
        get {
            let value = defaults.integer(forKey: SharedKeys.quickMinutes)
            return value == 0 ? 10 : value
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.quickMinutes)
        }
    }

    static var apiBaseURL: String {
        get {
            defaults.string(forKey: SharedKeys.apiBaseURL) ?? "https://api.openai.com/v1"
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.apiBaseURL)
        }
    }

    static var transcriptionModel: String {
        get {
            defaults.string(forKey: SharedKeys.transcriptionModel) ?? "gpt-transcribe"
        }
        set {
            defaults.set(newValue, forKey: SharedKeys.transcriptionModel)
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

    static func markServiceReady(expiresAt: Date) {
        defaults.set(true, forKey: SharedKeys.serviceReady)
        defaults.set(Date().timeIntervalSince1970, forKey: SharedKeys.serviceHeartbeat)
        defaults.set(expiresAt.timeIntervalSince1970, forKey: SharedKeys.serviceExpiresAt)
        status = .ready
        defaults.synchronize()
    }

    static func touchServiceHeartbeat(_ date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: SharedKeys.serviceHeartbeat)
    }

    static func clearServiceReady() {
        defaults.set(false, forKey: SharedKeys.serviceReady)
        defaults.removeObject(forKey: SharedKeys.serviceHeartbeat)
        defaults.removeObject(forKey: SharedKeys.serviceExpiresAt)
        if status == .ready || status == .starting {
            status = .idle
        }
        defaults.synchronize()
    }

    static func isServiceReady(at date: Date = Date()) -> Bool {
        guard defaults.bool(forKey: SharedKeys.serviceReady) else { return false }
        let heartbeat = defaults.double(forKey: SharedKeys.serviceHeartbeat)
        let expires = defaults.double(forKey: SharedKeys.serviceExpiresAt)
        guard heartbeat > 0, expires > 0 else { return false }
        let age = date.timeIntervalSince1970 - heartbeat
        return age >= -1 && age <= 6 && date.timeIntervalSince1970 < expires
    }

    @discardableResult
    static func createStartRequest() -> UUID {
        let id = UUID()
        defaults.set(id.uuidString, forKey: SharedKeys.startRequestID)
        defaults.set(Date().timeIntervalSince1970, forKey: SharedKeys.startRequestAt)
        defaults.synchronize()
        return id
    }

    static var pendingStartRequestID: UUID? {
        guard let raw = defaults.string(forKey: SharedKeys.startRequestID) else { return nil }
        return UUID(uuidString: raw)
    }

    static func clearStartRequest(_ id: UUID? = nil) {
        if let id,
           defaults.string(forKey: SharedKeys.startRequestID) != id.uuidString {
            return
        }
        defaults.removeObject(forKey: SharedKeys.startRequestID)
        defaults.removeObject(forKey: SharedKeys.startRequestAt)
        defaults.synchronize()
    }

    @discardableResult
    static func createStopRequest() -> UUID {
        let id = UUID()
        defaults.set(id.uuidString, forKey: SharedKeys.stopRequestID)
        defaults.synchronize()
        return id
    }

    static var pendingStopRequestID: UUID? {
        guard let raw = defaults.string(forKey: SharedKeys.stopRequestID) else { return nil }
        return UUID(uuidString: raw)
    }

    static func clearStopRequest(_ id: UUID? = nil) {
        if let id,
           defaults.string(forKey: SharedKeys.stopRequestID) != id.uuidString {
            return
        }
        defaults.removeObject(forKey: SharedKeys.stopRequestID)
        defaults.synchronize()
    }

    @discardableResult
    static func createCancelRequest() -> UUID {
        let id = UUID()
        defaults.set(id.uuidString, forKey: SharedKeys.cancelRequestID)
        defaults.synchronize()
        return id
    }

    static var pendingCancelRequestID: UUID? {
        guard let raw = defaults.string(forKey: SharedKeys.cancelRequestID) else { return nil }
        return UUID(uuidString: raw)
    }

    static func clearCancelRequest(_ id: UUID? = nil) {
        if let id,
           defaults.string(forKey: SharedKeys.cancelRequestID) != id.uuidString {
            return
        }
        defaults.removeObject(forKey: SharedKeys.cancelRequestID)
        defaults.synchronize()
    }

    static func clearControlRequests() {
        clearStartRequest()
        clearStopRequest()
        clearCancelRequest()
    }

    static func setError(_ message: String?) {
        if let message {
            defaults.set(message, forKey: SharedKeys.lastError)
        } else {
            defaults.removeObject(forKey: SharedKeys.lastError)
        }
        defaults.synchronize()
    }

    static var lastError: String? {
        defaults.string(forKey: SharedKeys.lastError)
    }

    @discardableResult
    static func publishResult(_ text: String) -> UUID {
        let id = UUID()
        defaults.set(id.uuidString, forKey: SharedKeys.resultID)
        defaults.set(text, forKey: SharedKeys.resultText)
        defaults.set(Date().timeIntervalSince1970, forKey: SharedKeys.resultCreatedAt)
        defaults.removeObject(forKey: SharedKeys.resultAttemptedID)
        defaults.synchronize()
        return id
    }

    static func pendingResult() -> (id: UUID, text: String)? {
        guard
            let rawID = defaults.string(forKey: SharedKeys.resultID),
            let id = UUID(uuidString: rawID),
            let text = defaults.string(forKey: SharedKeys.resultText),
            !text.isEmpty
        else { return nil }

        let inserted = defaults.string(forKey: SharedKeys.resultInsertedID)
        guard inserted != rawID else { return nil }
        return (id, text)
    }

    static func wasResultAttempted(_ id: UUID) -> Bool {
        defaults.string(forKey: SharedKeys.resultAttemptedID) == id.uuidString
    }

    static func markResultAttempted(_ id: UUID) {
        defaults.set(id.uuidString, forKey: SharedKeys.resultAttemptedID)
        defaults.synchronize()
    }

    static var recoverableResultText: String? {
        guard
            let rawID = defaults.string(forKey: SharedKeys.resultID),
            defaults.string(forKey: SharedKeys.resultInsertedID) != rawID
        else { return nil }
        return defaults.string(forKey: SharedKeys.resultText)
    }

    static func markResultInserted(_ id: UUID) {
        defaults.set(id.uuidString, forKey: SharedKeys.resultAttemptedID)
        defaults.set(id.uuidString, forKey: SharedKeys.resultInsertedID)
        defaults.removeObject(forKey: SharedKeys.resultText)
        defaults.removeObject(forKey: SharedKeys.resultCreatedAt)
        defaults.synchronize()
    }
}
