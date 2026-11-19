import SwiftUI

struct WatchView: View {
    var video: YTVideo
    var hostsPlayer: Bool
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 860 && !related.isEmpty
            HStack(alignment: .top, spacing: 16) {
                ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        backButton
                        player
                        Text(video.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let playerError = model.playerError {
                            TubeNotice(message: playerError)
                        }
                        if let actionError = model.actionError {
                            TubeNotice(message: actionError)
                        }
                        engagementRow {
                            withAnimation { proxy.scrollTo("comments", anchor: .top) }
                        }
                        if showsDescriptionCard {
                            descriptionCard
                        }
                        Button("Open in YouTube") {
                            model.openInBrowser(video, short: false)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        Divider()
                        CommentsPanel(scrolling: false, showsClose: false)
                            .id("comments")
                        if !wide {
                            relatedList
                                .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                }
                if wide {
                    ScrollView(showsIndicators: false) {
                        relatedList
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: min(340, geo.size.width * 0.34))
                }
            }
            .padding(20)
        }
    }

    private var backButton: some View {
        Button {
            model.dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                Text("Back")
                    .font(.body.weight(.medium))
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Back")
    }

    private var player: some View {
        VStack(spacing: 8) {
            Group {
                if hostsPlayer {
                    PlayerHole()
                } else {
                    Color.black
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            PlayerChrome(onDark: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(video.title)
    }

    private func engagementRow(scrollToComments: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                channelButton
                Spacer(minLength: 8)
                actions(scrollToComments: scrollToComments)
            }
            VStack(alignment: .leading, spacing: 10) {
                channelButton
                actions(scrollToComments: scrollToComments)
            }
        }
    }

    private var channelButton: some View {
        HStack(spacing: 12) {
            Button {
                openChannel()
            } label: {
                HStack(spacing: 12) {
                    Avatar(url: video.channelAvatar, name: channelName, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channelName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if !detailLine.isEmpty {
                            Text(detailLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(resolvedChannelID == nil)
            if let channelID = resolvedChannelID {
                SubscribeButton(channelID: channelID, compact: false)
            }
        }
    }

    private func actions(scrollToComments: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            chipButton(
                system: model.myRating == "like" ? "hand.thumbsup.fill" : "hand.thumbsup",
                title: model.likeCount ?? "Like",
                active: model.myRating == "like",
                help: "Like"
            ) {
                Task { await model.rate("like") }
            }
            chipButton(
                system: model.myRating == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                title: "Dislike",
                active: model.myRating == "dislike",
                help: "Dislike"
            ) {
                Task { await model.rate("dislike") }
            }
            chipButton(
                system: "bubble.left",
                title: model.commentCount ?? "Comments",
                active: false,
                help: "Comments"
            ) {
                scrollToComments()
            }
            if let url = model.watchURL(for: video, short: false) {
                ShareLink(item: url) {
                    chipLabel(system: "square.and.arrow.up", title: "Share", active: false)
                }
                .buttonStyle(PressScaleStyle())
                .hoverLift(scale: 1.02, shadow: 4)
                .help("Share")
            }
            chipButton(
                system: model.isSaved(video.id) ? "bookmark.fill" : "bookmark",
                title: model.isSaved(video.id) ? "Saved" : "Save",
                active: model.isSaved(video.id),
                help: "Save to Watch Later"
            ) {
                Task { await model.saveWatching() }
            }
            downloadChip
        }
    }

    @ViewBuilder private var downloadChip: some View {
        let store = DownloadStore.shared
        if store.isDownloaded(video.id) {
            chipButton(
                system: "arrow.circle.down.fill",
                title: "Downloaded",
                active: false,
                help: "Downloaded"
            ) {}
                .disabled(true)
        } else if let fraction = store.progress[video.id] {
            HStack(spacing: 6) {
                Image(systemName: "arrow.circle.down")
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(TubeColor.red)
                    .frame(width: 40)
                Text("\(Int((fraction * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
            .accessibilityLabel("Downloading")
        } else {
            chipButton(
                system: "arrow.circle.down",
                title: "Download",
                active: false,
                help: "Download for offline playback"
            ) {
                Task { await store.download(video) }
            }
        }
    }

    private func chipButton(
        system: String,
        title: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            chipLabel(system: system, title: title, active: active)
        }
        .buttonStyle(PressScaleStyle())
        .hoverLift(scale: 1.02, shadow: 4)
        .help(help)
        .accessibilityLabel(help)
    }

    private func chipLabel(system: String, title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system)
            Text(title)
                .lineLimit(1)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(active ? TubeColor.red : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(active ? 0.12 : 0.06))
        }
    }

    private var channelName: String {
        let name = video.channel.isEmpty ? (model.watchPage?.video.channel ?? "") : video.channel
        return name.isEmpty ? "YouTube" : name
    }

    private var resolvedChannelID: String? {
        if let id = video.channelID, id.hasPrefix("UC") { return id }
        if let id = model.watchPage?.video.channelID, id.hasPrefix("UC") { return id }
        return nil
    }

    private func openChannel() {
        guard let id = resolvedChannelID else { return }
        model.openChannel(id: id, name: channelName)
    }

    private var detailLine: String {
        model.watchPage?.subscribers ?? ""
    }

    private var descriptionBody: String {
        model.watchPage?.description ?? ""
    }

    private var descriptionViews: String {
        let views = model.watchPage?.video.views ?? video.views ?? ""
        return views
    }

    private var descriptionDate: String {
        model.watchPage?.video.published ?? video.published ?? ""
    }

    private var descriptionHandle: String? {
        model.watchPage?.handle
    }

    private var showsDescriptionCard: Bool {
        !descriptionViews.isEmpty || !descriptionDate.isEmpty || !descriptionBody.isEmpty || descriptionHandle != nil
    }

    private var descriptionMetaLine: String {
        let tags = TubeFormat.hashtags(in: descriptionBody).joined(separator: " ")
        return [descriptionViews, descriptionDate, tags].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !descriptionMetaLine.isEmpty {
                Text(descriptionMetaLine)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(model.descriptionExpanded ? 4 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !descriptionBody.isEmpty {
                Text(model.descriptionExpanded ? descriptionBody : TubeFormat.descriptionPreview(descriptionBody))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(model.descriptionExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let handle = descriptionHandle {
                    Button(action: openChannel) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.rectangle.fill")
                                .foregroundStyle(TubeColor.red)
                            Text(handle)
                                .lineLimit(1)
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(resolvedChannelID == nil)
                    .help(handle)
                }
                Spacer(minLength: 8)
                if !descriptionBody.isEmpty {
                    Button(model.descriptionExpanded ? "Show less" : "...more") {
                        model.descriptionExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TubeColor.chip)
        }
    }

    private var related: [YTVideo] {
        let fetched = model.watchPage?.related ?? []
        let pool = fetched.isEmpty ? fallback : fetched
        var seen: Set<String> = [video.id]
        var rows: [YTVideo] = []
        for item in pool where YTVideo.isVideoID(item.id) && seen.insert(item.id).inserted {
            rows.append(item)
            if rows.count == 30 { break }
        }
        return rows
    }

    private var fallback: [YTVideo] {
        model.library.homeFeed + model.library.history + model.library.watchLater + model.library.liked
    }

    private var relatedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !related.isEmpty {
                Text("Up next")
                    .font(.headline)
                ForEach(related) { item in
                    Button {
                        model.open(item, short: item.isShort)
                    } label: {
                        RelatedRow(video: item, vertical: item.isShort)
                    }
                    .buttonStyle(PressScaleStyle())
                    .hoverLift()
                    .springIn()
                    .focusEffectDisabled()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RelatedRow: View {
    var video: YTVideo
    var vertical: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !video.channel.isEmpty {
                    Text(video.channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !video.meta.isEmpty {
                    Text(video.meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var thumb: some View {
        Color.clear
            .aspectRatio(vertical ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
            .frame(width: vertical ? 72 : 168)
            .overlay {
                TubePicture(url: video.thumbnail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .overlay(alignment: .bottomTrailing) {
                if let length = video.length, !length.isEmpty {
                    DurationBadge(text: length)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}
