import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class ChatGPTAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    private enum Config {
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let authorizeURL = "https://auth.openai.com/oauth/authorize"
        static let tokenURL = "https://auth.openai.com/oauth/token"
        static let redirectURI = "http://localhost:1455/auth/callback"
        static let scopes = "openid profile email offline_access"
    }

    private var authSession: ASWebAuthenticationSession?

    var storedTokens: ChatGPTTokens? {
        KeychainStore.loadChatGPTTokens()
    }

    var isLoggedIn: Bool {
        guard let tokens = storedTokens else { return false }
        return !tokens.accessToken.isEmpty && !tokens.refreshToken.isEmpty
    }

    func signIn() async throws -> ChatGPTTokens {
        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 24)

        guard var components = URLComponents(string: Config.authorizeURL) else {
            throw ChatGPTAuthError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "scope", value: Config.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "id_token_add_organizations", value: "true")
        ]

        guard let authorizationURL = components.url else {
            throw ChatGPTAuthError.invalidURL
        }

        let callbackServer = OAuthCallbackServer()
        let listener = try await callbackServer.start()
        defer { listener.cancel() }

        let callbackURL = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in

            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "typevoice"
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ChatGPTAuthError.missingCallback)
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session

            guard session.start() else {
                self.authSession = nil
                continuation.resume(throwing: ChatGPTAuthError.unableToStartBrowser)
                return
            }
        }

        authSession = nil

        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw ChatGPTAuthError.invalidCallback
        }

        let params = Dictionary(uniqueKeysWithValues: (callbackComponents.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard params["state"] == state else {
            throw ChatGPTAuthError.stateMismatch
        }

        guard let code = params["code"] else {
            throw ChatGPTAuthError.authorizationDenied(
                params["error_description"] ?? params["error"] ?? "Unknown error"
            )
        }

        let tokens = try await tokenRequest(
            fields: [
                "grant_type": "authorization_code",
                "client_id": Config.clientID,
                "redirect_uri": Config.redirectURI,
                "code": code,
                "code_verifier": verifier
            ],
            previous: nil
        )

        try KeychainStore.saveChatGPTTokens(tokens)
        return tokens
    }

    func validTokens(forceRefresh: Bool = false) async throws -> ChatGPTTokens {
        guard var current = storedTokens else {
            throw ChatGPTAuthError.notLoggedIn
        }

        if forceRefresh || current.expiresAt.timeIntervalSinceNow < 300 {
            guard !current.refreshToken.isEmpty else {
                throw ChatGPTAuthError.refreshUnavailable
            }

            current = try await tokenRequest(
                fields: [
                    "grant_type": "refresh_token",
                    "client_id": Config.clientID,
                    "refresh_token": current.refreshToken
                ],
                previous: current
            )

            try KeychainStore.saveChatGPTTokens(current)
        }

        return current
    }

    func logout() {
        authSession?.cancel()
        authSession = nil
        KeychainStore.deleteChatGPTTokens()
    }

    func cancelLogin() {
        authSession?.cancel()
        authSession = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return window
        }
        return ASPresentationAnchor()
    }

    private func tokenRequest(
        fields: [String: String],
        previous: ChatGPTTokens?
    ) async throws -> ChatGPTTokens {
        guard let url = URL(string: Config.tokenURL) else {
            throw ChatGPTAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown response"
            throw ChatGPTAuthError.tokenExchangeFailed(detail)
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String
        else {
            throw ChatGPTAuthError.invalidTokenResponse
        }

        let refreshToken =
            (object["refresh_token"] as? String)
            ?? previous?.refreshToken
            ?? ""

        let idToken =
            (object["id_token"] as? String)
            ?? previous?.idToken

        let expiresIn: TimeInterval = {
            if let value = object["expires_in"] as? TimeInterval { return value }
            if let value = object["expires_in"] as? Int { return TimeInterval(value) }
            return 3600
        }()

        let claims = Self.decodeJWTPayload(accessToken)
        let authClaims = claims?["https://api.openai.com/auth"] as? [String: Any]
        let profileClaims = claims?["https://api.openai.com/profile"] as? [String: Any]

        let accountID =
            (claims?["chatgpt_account_id"] as? String)
            ?? (authClaims?["chatgpt_account_id"] as? String)
            ?? previous?.accountID

        let email =
            (claims?["email"] as? String)
            ?? (profileClaims?["email"] as? String)
            ?? previous?.email

        let plan =
            (claims?["chatgpt_plan_type"] as? String)
            ?? (authClaims?["chatgpt_plan_type"] as? String)
            ?? previous?.plan

        return ChatGPTTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            accountID: accountID,
            email: email,
            plan: plan
        )
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard
            let data = Data(base64Encoded: base64),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return json
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ values: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        return values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    }
}

enum ChatGPTAuthError: LocalizedError {
    case invalidURL
    case missingCallback
    case invalidCallback
    case stateMismatch
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case invalidTokenResponse
    case notLoggedIn
    case refreshUnavailable
    case unableToStartBrowser

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OAuth URL."
        case .missingCallback:
            return "No OAuth callback was received."
        case .invalidCallback:
            return "The OAuth callback was invalid."
        case .stateMismatch:
            return "OAuth state validation failed."
        case .authorizationDenied(let message):
            return "Sign in failed: \(message)"
        case .tokenExchangeFailed(let message):
            return "Token exchange failed: \(message)"
        case .invalidTokenResponse:
            return "OpenAI returned an invalid token response."
        case .notLoggedIn:
            return "Sign in with ChatGPT first."
        case .refreshUnavailable:
            return "The ChatGPT session cannot be refreshed. Sign in again."
        case .unableToStartBrowser:
            return "Could not open the ChatGPT sign-in page."
        }
    }
}
