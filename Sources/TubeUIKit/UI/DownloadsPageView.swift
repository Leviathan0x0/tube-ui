import AppKit
import SwiftUI

/// The Downloads section page: local .mp4 items, in-progress bars, and errors.
struct DownloadsPageView: View {
    @State private var store = DownloadStore.shared

    var body: some View {
        Group {
            if store.items.isEmpty && store.progress.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    LibraryPageHeader(title: "Downloads")
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    errorRow
                        .padding(.horizontal, 24)
                    TubeEmptyState(
                        section: .downloads,
                        title: "No downloads yet",
                        message: "Open a video and tap Download. Saved files show up here."
                    ) {
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        LibraryPageHeader(title: "Downloads")
                        errorRow
                        rows
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task { store.refresh() }
        .refreshable { store.refresh() }
    }

    @ViewBuilder private var errorRow: some View {
        if let error = store.error {
            HStack(alignment: .center, spacing: 12) {
                TubeNotice(message: error)
                Spacer(minLength: 8)
                Button("Retry") { store.refresh() }
                    .buttonStyle(.bordered)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: TubeMetrics.banner, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(store.progress.sorted(by: { $0.key < $1.key })), id: \.key) { id, value in
                progressRow(id: id, value: value)
            }
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                downloadRow(item)
                    .springIn(delay: tubeStagger(index))
            }
        }
    }

    private func progressRow(id: String, value: Double) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(id)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                ProgressView(value: value)
                    .progressViewStyle(.linear)
            }
            Spacer(minLength: 8)
            Text("\(Int(value * 100))%")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func downloadRow(_ item: DownloadStore.DownloadedVideo) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(metaLine(item))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open") { NSWorkspace.shared.open(item.fileURL) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Remove", role: .destructive) { store.remove(item) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func metaLine(_ item: DownloadStore.DownloadedVideo) -> String {
        var parts: [String] = []
        if !item.channel.isEmpty { parts.append(item.channel) }
        if let length = item.length, !length.isEmpty { parts.append(length) }
        parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}
