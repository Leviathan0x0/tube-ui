import SwiftUI

struct SignInView: View {
    private var model: TubeModel { TubeModel.shared }
    private var reduceTransparency: Bool {
        TubeChrome.reduceTransparency(tick: model.accessibilityTick)
    }
    @State private var showOAuthSettings = false

    var body: some View {
        ZStack {
            TubeGlassBackground()
            card
                .frame(width: 420)
                .zIndex(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showOAuthSettings) {
            OAuthSettingsView()
        }
    }

    @ViewBuilder private var card: some View {
        if model.accounts.isEmpty {
            welcomeCard
        } else {
            AccountSwitcherView()
        }
    }

    /// First-install screen: nothing signed in yet, so there is nothing to choose.
    private var welcomeCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ReiconSymbol(icon: .play)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(TubeColor.red)
                Text("TubeUI")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("A quiet YouTube client for this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            Button {
                model.signIn()
            } label: {
                Text("Sign in with YouTube")
            }
            .buttonStyle(TubeGlassButtonStyle(prominent: true, glass: !reduceTransparency))
            .disabled(model.isAuthorizing)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 24)

            if !model.hasClient {
                Button("Add a Google client manually") { showOAuthSettings = true }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .padding(.top, 12)
                    .disabled(model.isAuthorizing)
            }

            AuthProgressRow()
            AuthErrorRow()
        }
        .padding(.bottom, 16)
        .modifier(TubeGlassCard(glass: !reduceTransparency))
        .springIn()
    }
}
