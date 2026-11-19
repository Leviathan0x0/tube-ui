import SwiftUI

enum TubeColor {
    /// YouTube's brand red, #FF0000. Used for the mark and primary actions.
    static let red = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)

    /// Quiet sidebar selection. Opaque enough to read as selected, with no accent blue in it.
    static let selection = Color.primary.opacity(0.14)

    /// YouTube's unselected home chip, #272727.
    static let chip = Color(.sRGB, red: 39 / 255, green: 39 / 255, blue: 39 / 255, opacity: 1)

    /// YouTube's selected home chip, near-white with black text.
    static let chipSelected = Color(.sRGB, red: 241 / 255, green: 241 / 255, blue: 241 / 255, opacity: 1)
}

enum TubeMetrics {
    static let media: CGFloat = 8
    static let banner: CGFloat = 16
    static let panel: CGFloat = 28
}
