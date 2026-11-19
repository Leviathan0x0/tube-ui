import AppKit
import SwiftUI

/// YouTube's stacked-cover playlist card — deliberately different from a video card.
struct PlaylistCard: View {
    var playlist: YTPlaylist
    @State private var hovered = false
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
                .overlay(alignment: .topTrailing) {
                    if hovered {
                        RowKebab {
                            Button("Open in YouTube") { openInYouTube() }
                        }
                        .padding(4)
                    }
                }
            Text(playlist.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(playlist.countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if hovered {
                Text("View full playlist")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(TubeColor.red)
            }
        }
        .onHover { hovered = $0 }
    }

    /// Two-layer stack: a darker cover peeking out above the front thumbnail.
    private var cover: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                TubePicture(url: playlist.thumbnail)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(playlist.countLabel)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.18))
                    .padding(.horizontal, 12)
                    .offset(y: -10)
            }
            .padding(.top, 10)
    }

    private func openInYouTube() {
        guard let url = URL(string: "https://www.youtube.com/playlist?list=\(playlist.id)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The Playlists section page: a grid of stacked-cover cards.
struct PlaylistsPageView: View {
    private var model: TubeModel { TubeModel.shared }

    private var playlists: [YTPlaylist] {
        let query = model.query
        return model.library.playlists.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    private var searchedEmpty: Bool {
        !model.query.isEmpty && playlists.isEmpty
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                LibraryPageHeader(title: "Playlists", subtitle: sectionSubtitle)
                if searchedEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if playlists.isEmpty {
                    libraryStateView(.playlists) { Task { await model.reload() } }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 18)],
                        spacing: 24
                    ) {
                        ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                            Button {
                                model.openPlaylist(playlist)
                            } label: {
                                PlaylistCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .hoverLift()
                            .springIn(delay: tubeStagger(index))
                        }
                    }
                    .springIn()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.reload() }
    }

    private var sectionSubtitle: String? {
        playlists.isEmpty ? nil : "\(playlists.count) \(playlists.count == 1 ? "playlist" : "playlists")"
    }
}
