import Foundation

/// The Desktop OAuth client that ships inside TubeUI.
///
/// Fill these once, then rebuild. Every copy of that build signs in with
/// Google's account chooser. People who install the app never create a client.
/// Leave both empty to keep the per-Mac Settings screen.
public enum BundledOAuthClient {
    public static let clientID = ""
    public static let clientSecret = ""

    public static var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
