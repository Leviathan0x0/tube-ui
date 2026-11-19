import CryptoKit
import Foundation
import Security

struct StoredAuth: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var clientID: String
}

struct SavedAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var handle: String?
    var avatarURL: String?
    var auth: StoredAuth

    var avatar: URL? {
        avatarURL.flatMap(URL.init(string:))
    }
}

enum YouTubeOAuth {
    /// Full YouTube account. One grant covers subscriptions, playlists, likes,
    /// history, and Shorts. Comments are read from the watch page itself, so
    /// opening them does not ask for a second grant.
    static let scope = "https://www.googleapis.com/auth/youtube"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    static func verifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw OAuthError.server
        }
        return Data(bytes).base64URLEncoded
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded
    }

    static func authorizationURL(clientID: String, redirectURI: String, state: String, challenge: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        return components.url!
    }

    static func exchange(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        verifier: String
    ) async throws -> StoredAuth {
        var items = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        if !clientSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        let response = try await token(items)
        guard let refresh = response.refreshToken else {
            throw OAuthError.token("Google did not return a refresh token.")
        }
        return StoredAuth(
            accessToken: response.accessToken,
            refreshToken: refresh,
            expiry: expiry(after: response.expiresIn),
            clientID: clientID
        )
    }

    static func refresh(_ auth: StoredAuth, clientSecret: String) async throws -> StoredAuth {
        var items = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: auth.refreshToken),
            URLQueryItem(name: "client_id", value: auth.clientID),
        ]
        if !clientSecret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        let response = try await token(items)
        return StoredAuth(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? auth.refreshToken,
            expiry: expiry(after: response.expiresIn),
            clientID: auth.clientID
        )
    }

    private static func expiry(after seconds: Int) -> Date {
        Date().addingTimeInterval(TimeInterval(max(seconds - 60, 30)))
    }

    private static func token(_ items: [URLQueryItem]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(items)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            if let body = try? JSONDecoder().decode(TokenErrorBody.self, from: data) {
                throw OAuthError.token(body.errorDescription ?? body.error)
            }
            throw OAuthError.token("Google returned HTTP \(status).")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.token("Google returned a token TubeUI couldn't read.")
        }
    }

    static func formBody(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

enum OAuthError: LocalizedError, Equatable {
    case browser
    case timeout
    case denied
    case stateMismatch
    case missingCode
    case token(String)
    case server

    var errorDescription: String? {
        switch self {
        case .browser:
            "TubeUI couldn't open your browser."
        case .timeout:
            "Sign-in timed out. Try again."
        case .denied:
            "Google didn't grant access."
        case .stateMismatch:
            "Sign-in was interrupted. Try again."
        case .missingCode:
            "Google didn't return a sign-in code."
        case .token(let message):
            "Google refused the sign-in. \(message)"
        case .server:
            "TubeUI couldn't listen for the sign-in redirect."
        }
    }
}

private struct TokenResponse: Decodable {
    var accessToken: String
    var expiresIn: Int
    var refreshToken: String?
    var tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
    }
}

private struct TokenErrorBody: Decodable {
    var error: String
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
