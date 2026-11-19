import SwiftUI

/// YouTube's playlist-detail layout: a warm gradient header panel on the left,
/// the video list on the right. Serves Watch Later, Liked videos, and any
/// playlist opened through the browse glue (`section == nil`).
struct PlaylistDetailView: View {
    /// .watchLater or .liked for the library pages; nil when browsing an opened playlist.
    var section: LibrarySection?
    private var model: TubeModel { TubeModel.shared }

    @State private var kind: TubeKindFilter = .all

    private var videos: [YTVideo] {
        guard let section else { return model.playlistBrowse?.videos ?? [] }
        switch section {
        case .watchLater: return model.library.watchLater
        case .liked: return model.library.liked
        default: return []
        }
    }

    private var meta: PlaylistMeta? {
        guard let section else { return model.playlistBrowse?.meta }
        switch section {
        case .watchLater: return model.library.watchLaterMeta
        case .liked: return model.library.likedMeta
        default: return nil
        }
    }

    private var title: String {
        if let meta, !meta.title.isEmpty { return meta.title }
        return section?.title ?? "Playlist"
    }

    private var owner: String {
        meta?.owner ?? model.library.channel?.title ?? ""
    }

    private var metaLine: String {
        let count = meta?.count ?? videos.count
        var parts = ["\(count) \(count == 1 ? "video" : "videos")"]
        if let updated = meta?.updated, !updated.isEmpty { parts.append("Updated \(updated)") }
        return parts.joined(separator: " · ")
    }

    private var coverThumbnail: URL? {
        videos.first?.thumbnail
    }

    var body: some View {
        Group {
            if videos.isEmpty {
                emptyState
            } else {
                content(videos.filter { kind.matches($0) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await model.reload() }
    }

    @ViewBuilder private var emptyState: some View {
        if let section {
            libraryStateView(section) { Task { await model.reload() } }
        } else if model.playlistBrowseLoading {
            ProgressView("Loading playlist")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if let note = model.playlistBrowse?.note {
            ContentUnavailableView {
                Text("Couldn't open this playlist")
                    .font(.title2.weight(.semibold))
            } description: {
                Text(note)
            }
        } else {
            ContentUnavailableView {
                Text(title)
                    .font(.title2.weight(.semibold))
            } description: {
                Text("No videos in this playlist yet.")
            }
        }
    }

    private func content(_ items: [YTVideo]) -> some View {
        HStack(alignment: .top, spacing: 28) {
            headerPanel
                .frame(width: 340)
            list(items)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .springIn()
    }

    // MARK: Header panel

    private var headerPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            playAllCover
            Text(title)
                .font(.title2.weight(.bold))
                .lineLimit(3)
            if !owner.isEmpty {
                Text(owner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(metaLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(action: playAll) {
                    Label("Play all", systemImage: "play.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.92)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(videos.isEmpty)
                Button(action: openRandom) {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.primary.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(videos.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { warmCover }
        .clipShape(RoundedRectangle(cornerRadius: TubeMetrics.banner, style: .continuous))
    }

    private var playAllCover: some View {
        ZStack {
            Color.primary.opacity(0.1)
            TubePicture(url: coverThumbnail)
            Color.black.opacity(0.35)
            Button(action: playAll) {
                VStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.title2)
                    Text("PLAY ALL")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(Circle().fill(.black.opacity(0.45)))
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(videos.isEmpty)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Play all")
    }

    private var warmCover: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.32, green: 0.22, blue: 0.15),
                    Color(red: 0.11, green: 0.08, blue: 0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            TubePicture(url: coverThumbnail)
                .blur(radius: 36)
                .opacity(coverThumbnail == nil ? 0 : 0.3)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Video list

    private func list(_ items: [YTVideo]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                TubeKindChips(selection: kind) { kind = $0 }
                if items.isEmpty {
                    tubeKindEmptyNote(kind)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, video in
                        row(video, sentinel: index == items.count - 1)
                            .springIn(delay: tubeStagger(index))
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ video: YTVideo, sentinel: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                model.open(video, short: video.isShort)
            } label: {
                WideVideoRow(video: video)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            RowKebab {
                Button("Open in YouTube") { model.openInBrowser(video, short: video.isShort) }
            }
        }
        .task {
            guard sentinel else { return }
            if let section {
                if model.library.continuations[section] != nil {
                    await model.loadMore(section)
                }
            } else {
                await model.loadMorePlaylistBrowse()
            }
        }
    }

    // MARK: Actions

    private func playAll() {
        guard let first = videos.first else { return }
        model.open(first, short: first.isShort)
    }

    private func openRandom() {
        guard let random = videos.randomElement() else { return }
        model.open(random, short: random.isShort)
    }
}
