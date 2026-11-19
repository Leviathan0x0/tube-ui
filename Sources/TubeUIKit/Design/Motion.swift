import SwiftUI

// Shared micro-interaction helpers. Keep effects subtle: small scale, quick springs.

/// Scales down slightly while pressed. Apply to `Button` styles or wrappers.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    /// No-op. Hover zoom/lift effects were removed per user feedback; kept so
    /// the many call sites don't need touching. Delete once all calls are gone.
    @ViewBuilder func hoverLift(scale: CGFloat = 1.02, shadow: CGFloat = 6) -> some View {
        self
    }

    /// Springy entrance when the view first appears.
    @ViewBuilder func springIn(delay: Double = 0) -> some View {
        modifier(SpringIn(delay: delay))
    }
}

private struct SpringIn: ViewModifier {
    @State private var shown = false
    var delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(delay)) {
                    shown = true
                }
            }
    }
}
