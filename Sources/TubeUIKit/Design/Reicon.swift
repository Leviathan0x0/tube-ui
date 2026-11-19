import SwiftUI

enum Reicon: String, CaseIterable, Hashable, Sendable {
    case home
    case play
    case videoPlayV
    case users
    case subscriptions
    case library
    case history
    case playlist
    case clock
    case thumbsUp
    case search
    case settings
    case logout
    case user
    case alertCircle
    case refresh
    case trending
    case music
    case movie
    case live
    case gaming
    case podcast
    case download
    case bell
}

enum ReiconWeight: Sendable {
    case outline
    case filled
}

struct ReiconSymbol: View {
    var icon: Reicon
    var weight: ReiconWeight = .outline

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            for layer in ReiconDrawCache.layers(icon, weight) {
                context.fill(
                    layer.path.applying(transform),
                    with: .foreground,
                    style: FillStyle(eoFill: layer.evenOdd, antialiased: true)
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

@MainActor
enum ReiconDrawCache {
    struct Drawn {
        var evenOdd: Bool
        var path: Path
    }

    private static let storage: [Reicon: (outline: [Drawn], filled: [Drawn])] = {
        var map: [Reicon: (outline: [Drawn], filled: [Drawn])] = [:]
        for icon in Reicon.allCases {
            map[icon] = (draw(icon, .outline), draw(icon, .filled))
        }
        return map
    }()

    static func layers(_ icon: Reicon, _ weight: ReiconWeight) -> [Drawn] {
        let entry = storage[icon] ?? ([], [])
        return weight == .outline ? entry.outline : entry.filled
    }

    private static func draw(_ icon: Reicon, _ weight: ReiconWeight) -> [Drawn] {
        ReiconCatalog.layers(icon, weight).compactMap { layer in
            guard let path = try? SVGPathParser.parse(layer.commands) else { return nil }
            return Drawn(evenOdd: layer.evenOdd, path: path)
        }
    }
}
