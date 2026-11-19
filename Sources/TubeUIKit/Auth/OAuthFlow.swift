import AppKit
import Foundation

enum OAuthFlow {
    @MainActor
    static func signIn(clientID: String, clientSecret: String) async throws -> StoredAuth {
        let server = LoopbackServer()
        let port = try server.bind()
        let redirect = "http://127.0.0.1:\(port)/callback"
        let verifier = try YouTubeOAuth.verifier()
        let state = try YouTubeOAuth.verifier()
        let url = YouTubeOAuth.authorizationURL(
            clientID: clientID,
            redirectURI: redirect,
            state: state,
            challenge: YouTubeOAuth.challenge(for: verifier)
        )
        guard NSWorkspace.shared.open(url) else {
            server.stop()
            throw OAuthError.browser
        }
        do {
            let code = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try server.waitForCode(expectedState: state)
                }.value
            } onCancel: {
                server.stop()
            }
            server.stop()
            return try await YouTubeOAuth.exchange(
                code: code,
                clientID: clientID,
                clientSecret: clientSecret,
                redirectURI: redirect,
                verifier: verifier
            )
        } catch {
            server.stop()
            throw error
        }
    }
}
