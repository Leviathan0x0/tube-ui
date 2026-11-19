import AppKit
import SwiftUI

enum TubeChrome {
    /// `tick` is read so the view refreshes when Reduce Transparency changes.
    static func reduceTransparency(tick: Int) -> Bool {
        _ = tick
        return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

/// Decorative wash. Hit testing stays off so it can never sit in front of a control.
struct TubeGlassBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Circle()
                .fill(TubeColor.red.opacity(0.14))
                .frame(width: 460, height: 460)
                .offset(x: -240, y: -180)
                .blur(radius: 90)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Liquid glass drawn behind content. The effect itself does not receive clicks.
struct TubeGlassCard: ViewModifier {
    var glass: Bool
    var radius: CGFloat = TubeMetrics.panel

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if glass {
            content.background {
                shape
                    .fill(Color.white.opacity(0.001))
                    .glassEffect(.regular, in: shape)
                    .allowsHitTesting(false)
            }
        } else {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}

struct TubeGlassButtonStyle: ButtonStyle {
    var prominent: Bool
    var glass: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(prominent ? .body.weight(.semibold) : .body)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, prominent ? 10 : 6)
            .padding(.horizontal, 16)
            .background {
                chrome(shape)
                    .opacity(configuration.isPressed ? 0.82 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
    }

    @ViewBuilder private func chrome(_ shape: Capsule) -> some View {
        if glass, prominent {
            shape
                .fill(TubeColor.red)
                .glassEffect(.regular.tint(TubeColor.red).interactive(), in: shape)
        } else if glass {
            shape.glassEffect(.regular.interactive(), in: shape)
        } else if prominent {
            shape.fill(TubeColor.red)
        } else {
            shape.fill(Color.primary.opacity(0.08))
        }
    }
}
