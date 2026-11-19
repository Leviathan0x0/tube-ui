import SwiftUI

/// Real search results, shown in the detail area while `model.searchResults` is set.
struct SearchResultsPageView: View {
    private var model: TubeModel { TubeModel.shared }

    private var page: SearchPage? { model.searchResults }

    private var pageEmpty: Bool {
        guard let page else { return true }
        return page.videos.isEmpty && page.channels.isEmpty && page.playlists.isEmpty
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Button {
                        model.clearSearch()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Back (Esc)")
                    Text("Results for “\(model.query)”")
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                }
                if let error = model.searchError {
                    TubeNotice(message: error)
                } else if pageEmpty, model.isSearching {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if pageEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if let page {
                    resultSections(page)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .springIn()
    }

    @ViewBuilder private func resultSections(_ page: SearchPage) -> some View {
        if !page.videos.isEmpty {
            sectionBlock("Videos") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)],
                    spacing: 22
                ) {
                    ForEach(Array(page.videos.enumerated()), id: \.element.id) { index, video in
                        HomeCard(video: video)
                            .hoverLift()
                            .springIn(delay: tubeStagger(index))
                    }
                }
            }
        }
        if !page.channels.isEmpty {
            sectionBlock("Channels") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.channels) { channel in
                        channelRow(channel)
                    }
                }
            }
        }
        if !page.playlists.isEmpty {
            sectionBlock("Playlists") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 18)],
                    spacing: 24
                ) {
                    ForEach(Array(page.playlists.enumerated()), id: \.element.id) { index, playlist in
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
            }
        }
        moreResults
    }

    private func sectionBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
        }
    }

    private func channelRow(_ channel: YTChannel) -> some View {
        HStack(spacing: 12) {
            Button {
                model.openChannel(id: channel.id, name: channel.title)
            } label: {
                ChannelRow(title: channel.title, avatar: channel.avatarURL)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!channel.id.hasPrefix("UC"))
            if !channel.statsLine.isEmpty {
                Text(channel.statsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SubscribeButton(channelID: channel.id, compact: true)
        }
    }

    @ViewBuilder private var moreResults: some View {
        if model.searchResults?.continuation != nil {
            if model.isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            } else {
                Button("More results") {
                    Task { await model.loadMoreSearchResults() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
