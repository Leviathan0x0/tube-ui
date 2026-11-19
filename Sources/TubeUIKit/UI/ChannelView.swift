import SwiftUI

struct SubscribeButton: View {
    var channelID: String
    var compact: Bool
    /// Subscriptions list shows the action. Other pages keep the state word.
    var subscribedTitle: String = "Subscribed"
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        let subscribed = model.isSubscribed(channelID)
        Button(subscribed ? subscribedTitle : "Subscribe") {
            Task { await model.toggleSubscription(channelID) }
        }
        .buttonStyle(.borderedProminent)
        .tint(subscribed ? Color.primary.opacity(0.18) : TubeColor.red)
        .controlSize(compact ? .small : .regular)
        .disabled(model.subscriptionBusy || !channelID.hasPrefix("UC"))
    }
}

struct ChannelView: View {
    var browse: ChannelBrowse
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                backButton
                banner
                HStack(alignment: .center, spacing: 16) {
                    Avatar(url: browse.channel?.avatarURL, name: browse.title, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(browse.title)
                            .font(.title.weight(.bold))
                            .foregroundStyle(.primary)
                        if let handle = browse.channel?.handle {
                            Text(handle)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        if let stats = browse.channel?.statsLine, !stats.isEmpty {
                            Text(stats)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    SubscribeButton(channelID: browse.id, compact: false)
                }
                if browse.loading {
                    ProgressView("Loading videos")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let note = browse.note {
                    if note == "No public videos on this channel." {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        TubeNotice(message: note)
                    }
                }
                if !browse.videos.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 16)],
                        spacing: 22
                    ) {
                        ForEach(browse.videos) { video in
                            HomeCard(video: video)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
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

    private var banner: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 168)
            .overlay {
                ZStack {
                    bannerFill
                    TubePicture(url: browse.channel?.bannerURL)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)
    }

    private var bannerFill: some View {
        LinearGradient(
            colors: [TubeColor.red.opacity(0.55), Color.black.opacity(0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
