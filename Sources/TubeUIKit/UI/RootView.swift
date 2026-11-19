import SwiftUI

public struct RootView: View {
    private var model: TubeModel { TubeModel.shared }

    public init() {}

    public var body: some View {
        Group {
            if !model.isSignedIn {
                SignInView()
            } else {
                LibraryShell()
            }
        }
        .task { await model.restoreIfNeeded() }
    }
}
