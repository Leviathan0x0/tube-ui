import SwiftUI

public struct OAuthSettingsView: View {
    private var model: TubeModel { TubeModel.shared }

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TubeLineField(
                        text: Binding(get: { model.clientID }, set: { model.clientID = $0 }),
                        placeholder: "Client ID"
                    )
                    TubeLineField(
                        text: Binding(get: { model.clientSecret }, set: { model.clientSecret = $0 }),
                        placeholder: "Client secret",
                        secure: true
                    )
                } header: {
                    Text("Google OAuth")
                } footer: {
                    Text("A Desktop client. TubeUI listens on 127.0.0.1 for the redirect, so you do not register a redirect URI.")
                }

                Section {
                    LabeledContent("Access") {
                        Text("Read only")
                    }
                    Link(
                        "Open Google Cloud credentials",
                        destination: URL(string: "https://console.cloud.google.com/apis/credentials")!
                    )
                    .tint(TubeColor.red)
                } header: {
                    Text("Setup")
                } footer: {
                    Text("These values stay on this Mac. To ship sign-in with the app, paste the same Desktop client into BundledOAuthClient.swift and rebuild. Enable YouTube Data API v3, and add your Google account as a test user while the app is in testing.")
                }

                if let credentialError = model.credentialError {
                    Section {
                        TubeNotice(message: credentialError)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("OAuth client")
        }
        .frame(width: 560, height: 460)
        .onDisappear { model.persistCredentials() }
    }
}
