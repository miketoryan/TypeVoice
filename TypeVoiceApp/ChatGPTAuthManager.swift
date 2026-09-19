import Foundation

struct ChatGPTTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var idToken: String?
    var expiresAt: Date
    var accountID: String?
    var email: String?
    var plan: String?
}

struct ChatGPTDevicePrompt {
    let deviceAuthID: String
    let userCode: String
    let verificationURL: URL
    let interval: TimeInterval
}

final class ChatGPTAuthManager {
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let issuer = "https://auth.openai.com"
    private let deviceRedirectURI = "https://auth.openai.com/deviceauth/callback"

    var storedTokens: ChatGPTTokens? {
        KeychainStore.loadChatGPTTokens()
    }

    var isLoggedIn: Bool {
        guard let tokens = storedTokens else { return false }
        return !tokens.accessToken.isEmpty && !tokens.refreshToken.isEmpty
    }

    func beginDeviceLogin() async throws -> ChatGPTDevicePrompt {
        guard let url = URL(string: issuer + "/api/accounts/deviceauth/usercode") else {
            throw ChatGPTAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TypeVoice/0.2", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTAuthError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw ChatGPTAuthError.deviceCodeDisabled
            }
            throw ChatGPTAuthError.http(http.statusCode, responseMessage(data))
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceAuthID = object["device_auth_id"] as? String,
            let userCode = object["user_code"] as? String,
            let verificationURL = URL(string: issuer + "/codex/device")
        else {
            throw ChatGPTAuthError.invalidResponse
        }

        let interval: TimeInterval
        if let number = object["interval"] as? NSNumber {
            interval = max(1, number.doubleValue)
        } else if let string = object["interval"] as? String, let value = Double(string) {
            interval = max(1, value)
        } else {
            interval = 5
        }

        return ChatGPTDevicePrompt(
            deviceAuthID: deviceAuthID,
            userCode: userCode,
            verificationURL: verificationURL,
            interval: interval
        )
    }

    func completeDeviceLogin(_ prompt: ChatGPTDevicePrompt) async throws -> ChatGPTTokens {
        let deadline = Date().addingTimeInterval(15 * 60)

        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }

            do {
                if let code = try await pollDeviceAuthorization(prompt) {
                    let tokens = try await exchangeAuthorizationCode(
                        code.authorizationCode,
                        codeVerifier: code.codeVerifier
                    )
                    try KeychainStore.saveChatGPTTokens(tokens)
                    return tokens
                }
            } catch ChatGPTAuthError.authorizationPending {
                // Keep polling at the server-provided interval.
            }

            try await Task.sleep(nanoseconds: UInt64(prompt.interval * 1_000_000_000))
        }

        throw ChatGPTAuthError.loginTimedOut
    }

    func validTokens(forceRefresh: Bool = false) async throws -> ChatGPTTokens {
        guard var tokens = storedTokens else {
            throw ChatGPTAuthError.notLoggedIn
        }

        if forceRefresh || tokens.expiresAt.timeIntervalSinceNow < 90 {
            tokens = try await refresh(tokens)
            try KeychainStore.saveChatGPTTokens(tokens)
        }
        return tokens
    }

    func logout() {
        KeychainStore.deleteChatGPTTokens()
    }

    private func pollDeviceAuthorization(
        _ prompt: ChatGPTDevicePrompt
    ) async throws -> (authorizationCode: String, codeVerifier: String)? {
        guard let url = URL(string: issuer + "/api/accounts/deviceauth/token") else {
            throw ChatGPTAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TypeVoice/0.2", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": prompt.deviceAuthID,
            "user_code": prompt.userCode
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTAuthError.invalidResponse
        }

        if http.statusCode == 403 || http.statusCode == 404 {
            throw ChatGPTAuthError.authorizationPending
        }
        guard (200...299).contains(http.statusCode) else {
            throw ChatGPTAuthError.http(http.statusCode, responseMessage(data))
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let authorizationCode = object["authorization_code"] as? String,
            let codeVerifier = object["code_verifier"] as? String
        else {
            throw ChatGPTAuthError.invalidResponse
        }

        return (authorizationCode, codeVerifier)
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> ChatGPTTokens {
        let fields: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": deviceRedirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier
        ]
        let response = try await tokenRequest(fields)
        return try makeStoredTokens(response, previous: nil)
    }

    private func refresh(_ current: ChatGPTTokens) async throws -> ChatGPTTokens {
        let fields: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": clientID
        ]
        let response = try await tokenRequest(fields)
        return try makeStoredTokens(response, previous: current)
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> OAuthTokenResponse {
        guard let url = URL(string: issuer + "/oauth/token") else {
            throw ChatGPTAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("TypeVoice/0.2", forHTTPHeaderField: "User-Agent")
        request.httpBody = formEncoded(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTAuthError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ChatGPTAuthError.http(http.statusCode, responseMessage(data))
        }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    private func makeStoredTokens(
        _ response: OAuthTokenResponse,
        previous: ChatGPTTokens?
    ) throws -> ChatGPTTokens {
        let refreshToken = response.refreshToken ?? previous?.refreshToken
        guard let refreshToken, !refreshToken.isEmpty else {
            throw ChatGPTAuthError.missingRefreshToken
        }

        let idToken = response.idToken ?? previous?.idToken
        let metadata = decodeMetadata(idToken ?? response.accessToken)
        let expiresIn = response.expiresIn ?? 3600

        return ChatGPTTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(60, expiresIn - 60))),
            accountID: metadata.accountID ?? previous?.accountID,
            email: metadata.email ?? previous?.email,
            plan: metadata.plan ?? previous?.plan
        )
    }

    private func decodeMetadata(_ jwt: String) -> (accountID: String?, email: String?, plan: String?) {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil, nil) }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }

        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, nil, nil)
        }

        let email = object["email"] as? String
        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        let accountID =
            (auth?["chatgpt_account_id"] as? String)
            ?? (object["chatgpt_account_id"] as? String)
        let plan =
            (auth?["chatgpt_plan_type"] as? String)
            ?? (object["chatgpt_plan_type"] as? String)

        return (accountID, email, plan)
    }

    private func formEncoded(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func responseMessage(_ data: Data) -> String {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

enum ChatGPTAuthError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notLoggedIn
    case deviceCodeDisabled
    case authorizationPending
    case loginTimedOut
    case missingRefreshToken
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ChatGPT authentication URL."
        case .invalidResponse:
            return "ChatGPT returned an invalid authentication response."
        case .notLoggedIn:
            return "Please sign in with ChatGPT first."
        case .deviceCodeDisabled:
            return "Device-code login is disabled for this ChatGPT account. Enable device-code authorization in ChatGPT Security settings, then try again."
        case .authorizationPending:
            return "Waiting for ChatGPT authorization."
        case .loginTimedOut:
            return "ChatGPT login timed out. Start the login again."
        case .missingRefreshToken:
            return "ChatGPT login did not return a refresh token."
        case .http(let status, let message):
            return "ChatGPT login failed (HTTP \(status)): \(message)"
        }
    }
}
