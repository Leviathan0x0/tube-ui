import SwiftUI

/// Reusable saved-account chooser card: select or remove an account, or add
/// another. It sets no width of its own, so it works as the sign-in card and
/// later inside a sidebar popover — the host supplies the frame.
struct AccountSwitcherView: View {
    private var model: TubeModel { TubeModel.shared }
    private var reduceTransparency: Bool {
        TubeChrome.reduceTransparency(tick: model.accessibilityTick)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose an account")
                    .font(.title2.weight(.semibold))
                Text("to continue to TubeUI")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)

            ForEach(model.accounts) { account in
                accountRow(account)
                    .hoverLift()
                    .springIn()
                Divider().padding(.leading, 68)
            }

            addAccount
                .springIn()

            AuthProgressRow()
            AuthErrorRow()
        }
        .padding(.bottom, 12)
        .modifier(TubeGlassCard(glass: !reduceTransparency))
        .confirmationDialog(
            "Remove this account from TubeUI?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.accounts.first { $0.id == model.pendingRemoval }
        ) { account in
            Button("Remove", role: .destructive) { model.remove(account) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("\(account.title) is taken off this Mac. The YouTube account itself is left as it is.")
        }
    }

    private func accountRow(_ account: SavedAccount) -> some View {
        HStack(spacing: 0) {
            Button {
                model.select(account)
            } label: {
                HStack(spacing: 12) {
                    Avatar(url: account.avatar, name: account.title, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let handle = account.handle, !handle.isEmpty {
                            Text(handle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isAuthorizing)
            .accessibilityLabel("\(account.title), \(account.handle ?? "YouTube")")

            Button("Remove") { model.pendingRemoval = account.id }
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.secondary)
                .disabled(model.isAuthorizing)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    private var addAccount: some View {
        Button {
            model.signIn()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.08))
                    ReiconSymbol(icon: .user)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)
                Text("Add another account")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(model.isAuthorizing)
        .keyboardShortcut(.defaultAction)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// Progress row shown while the OAuth flow waits in the browser. Shared by the
/// account chooser and the first-install welcome card.
struct AuthProgressRow: View {
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        if model.isAuthorizing {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Choose an account in your browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel") { model.cancelSignIn() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

/// Auth error notice row, shared by both sign-in card states.
struct AuthErrorRow: View {
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        if let authError = model.authError {
            TubeNotice(message: authError)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }
}
