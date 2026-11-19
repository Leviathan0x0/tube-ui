import SwiftUI
import TubeUIKit

@main
struct TubeUIApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 920, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Account") {
                Button("Reload Library") {
                    Task { await TubeModel.shared.reload() }
                }
                .keyboardShortcut("r")
                Button("Sign Out") {
                    guard TubeModel.shared.isSignedIn else { return }
                    TubeModel.shared.confirmSignOut = true
                }
            }
        }
    }
}
