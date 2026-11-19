import SwiftUI

/// Generic video-grid page: Trending, the five Explore topics, and Your videos.
struct ExplorePageView: View {
    var section: LibrarySection
    private var model: TubeModel { TubeModel.shared }

    private var items: [YTVideo] { model.library.feeds[section] ?? [] }
    private var isFeeding: Bool { model.feedsLoading.contains(section) }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    LibraryPageHeader(title: section.title)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    emptyState
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        LibraryPageHeader(title: section.title, subtitle: section.subtitle)
                        grid
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .refreshable { await model.reload() }
        // Re-runs when a reload clears the feed (nil ↔ loaded), so pull-to-refresh refills it.
        .task(id: model.library.feeds[section] == nil) { await model.ensureFeed(section) }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)],
            spacing: 22
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, video in
                HomeCard(video: video)
                    .hoverLift()
                    .springIn(delay: tubeStagger(index))
            }
        }
        .springIn()
    }

    @ViewBuilder private var emptyState: some View {
        if isFeeding, model.library.notes[section] == nil {
            ProgressView("Loading \(section.title)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            libraryStateView(section) {
                model.library.notes[section] = nil
                model.library.feeds[section] = nil
                Task { await model.ensureFeed(section) }
            }
        }
    }
}
