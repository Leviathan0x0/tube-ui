import SwiftUI

struct ShortsStage: View {
    var video: YTVideo
    var hostsPlayer: Bool
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.black
                HStack(alignment: .center, spacing: 18) {
                    Spacer(minLength: 8)
                    stage
                    rail
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 12)
                backButton
                    .padding(16)
            }
            if model.commentsOpen {
                CommentsPanel(scrolling: true, showsClose: true)
                    .frame(width: 360)
                    .background(.background)
            }
        }
        .background(Color.black)
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
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Back")
    }

    private var stage: some View {
        ZStack(alignment: .bottom) {
            Group {
                if hostsPlayer {
                    PlayerHole()
                } else {
                    Color.black
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let playerError = model.playerError {
                    Text(playerError)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                channelChip
                Text(video.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                PlayerScrubber(compact: true, onDark: true)
            }
            .padding(14)
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .frame(maxWidth: 420, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(video.title)
    }

    private var channelChip: some View {
        HStack(spacing: 8) {
            Button {
                openChannel()
            } label: {
                HStack(spacing: 8) {
                    Avatar(url: video.channelAvatar, name: channelName, size: 32)
                    Text(channelName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(resolvedChannelID == nil)
            if let channelID = resolvedChannelID {
                SubscribeButton(channelID: channelID, compact: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var rail: some View {
        VStack(spacing: 16) {
            railButton(
                system: model.myRating == "like" ? "hand.thumbsup.fill" : "hand.thumbsup",
                title: model.likeCount ?? "Like",
                active: model.myRating == "like",
                help: "Like"
            ) {
                Task { await model.rate("like") }
            }
            railButton(
                system: model.myRating == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                title: "Dislike",
                active: model.myRating == "dislike",
                help: "Dislike"
            ) {
                Task { await model.rate("dislike") }
            }
            railButton(
                system: "bubble.left",
                title: model.commentCount ?? "Comments",
                active: model.commentsOpen,
                help: "Comments"
            ) {
                model.commentsOpen.toggle()
            }
            if let url = model.watchURL(for: video, short: true) {
                ShareLink(item: url) {
                    railLabel(system: "square.and.arrow.up", title: "Share", active: false)
                }
                .buttonStyle(PressScaleStyle())
                .help("Share")
            }
            railButton(
                system: model.isSaved(video.id) ? "bookmark.fill" : "bookmark",
                title: model.isSaved(video.id) ? "Saved" : "Save",
                active: model.isSaved(video.id),
                help: "Save to Watch Later"
            ) {
                Task { await model.saveWatching() }
            }
            Spacer(minLength: 12)
            railButton(system: "chevron.up", title: "Previous", active: false, help: "Previous Short", enabled: model.hasPrevious) {
                model.playPrevious()
            }
            railButton(system: "chevron.down", title: "Next", active: false, help: "Next Short", enabled: model.hasNext) {
                model.playNext()
            }
            railButton(
                system: "arrow.up.left.and.arrow.down.right",
                title: "Full",
                active: false,
                help: "Full Screen"
            ) {
                model.setFullscreen(true)
            }
        }
        .frame(width: 72)
        .padding(.vertical, 8)
    }

    private func railButton(
        system: String,
        title: String,
        active: Bool,
        help: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            railLabel(system: system, title: title, active: active)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }

    private func railLabel(system: String, title: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.14), in: Circle())
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(active ? TubeColor.red : .white)
        .frame(width: 72)
        .hoverLift(scale: 1.06, shadow: 0)
    }

    private var channelName: String {
        let name = video.channel.isEmpty ? (model.watchPage?.video.channel ?? "") : video.channel
        return name.isEmpty ? "Channel" : name
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
}
