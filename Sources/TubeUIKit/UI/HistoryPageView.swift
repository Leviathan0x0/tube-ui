import AppKit
import SwiftUI

/// YouTube's "Watch history" page: kind chips, day groups, and the search rail.
struct HistoryPageView: View {
    private var model: TubeModel { TubeModel.shared }
    @State private var filterText = ""
    @State private var kind: TubeKindFilter = .all
    @State private var containerWidth: CGFloat = 0

    private static let historyURL = URL(string: "https://www.youtube.com/feed/history")

    var body: some View {
        let days = visibleDays
        let total = days.reduce(0) { $0 + $1.videos.count }
        ScrollView(showsIndicators: false) {
            HStack(alignment: .top, spacing: 28) {
                mainList(days: days, total: total)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if containerWidth > 980 {
                    rail
                        .frame(width: 300)
                        .springIn()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { containerWidth = $0 })
        .refreshable { await model.reload() }
    }

    private var visibleDays: [HistoryDay] {
        let source: [HistoryDay] = model.library.historyDays.isEmpty
            ? [HistoryDay(id: "flat", label: "", videos: model.library.history)]
            : model.library.historyDays
        let text = filterText.trimmingCharacters(in: .whitespaces)
        return source.compactMap { day in
            let rows = day.videos.filter {
                kind.matches($0)
                    && (text.isEmpty || $0.title.localizedStandardContains(text) || $0.channel.localizedStandardContains(text))
            }
            return rows.isEmpty ? nil : HistoryDay(id: day.id, label: day.label, videos: rows)
        }
    }

    @ViewBuilder private func mainList(days: [HistoryDay], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            LibraryPageHeader(title: "Watch history")
            TubeKindChips(selection: kind) { kind = $0 }
            if model.library.history.isEmpty && model.library.historyDays.isEmpty {
                libraryStateView(.history) { Task { await model.reload() } }
            } else if total == 0 {
                if filterText.trimmingCharacters(in: .whitespaces).isEmpty {
                    tubeKindEmptyNote(kind)
                } else {
                    ContentUnavailableView.search(text: filterText)
                }
            } else {
                ForEach(days) { day in
                    dayGroup(day, lastDayID: days.last?.id)
                }
                if model.library.capped.contains(.history) {
                    Text("Showing the first \(model.library.history.count).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .springIn()
    }

    private func dayGroup(_ day: HistoryDay, lastDayID: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !day.label.isEmpty {
                Text(day.label)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 4)
            }
            ForEach(Array(day.videos.enumerated()), id: \.element.id) { index, video in
                historyRow(
                    video,
                    sentinel: index == day.videos.count - 1 && day.id == lastDayID
                )
                .springIn(delay: tubeStagger(index))
            }
        }
    }

    private func historyRow(_ video: YTVideo, sentinel: Bool) -> some View {
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
                Button("Remove from watch history") { Self.openHistoryInBrowser() }
                Button("Open in YouTube") { model.openInBrowser(video, short: video.isShort) }
            }
        }
        .task {
            guard sentinel, model.library.continuations[.history] != nil else { return }
            await model.loadMore(.history)
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Search watch history")
                    .font(.subheadline.weight(.semibold))
                TubeLineField(text: $filterText, placeholder: "Search this watch history")
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(height: 1)
                    }
            }
            Divider()
            railButton(icon: "trash", title: "Clear all watch history")
            railButton(icon: "pause.circle", title: "Pause watch history")
        }
    }

    private func railButton(icon: String, title: String) -> some View {
        Button(action: Self.openHistoryInBrowser) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Opens youtube.com/feed/history — YouTube's data API can't do this directly.")
    }

    private static func openHistoryInBrowser() {
        guard let url = historyURL else { return }
        NSWorkspace.shared.open(url)
    }
}
