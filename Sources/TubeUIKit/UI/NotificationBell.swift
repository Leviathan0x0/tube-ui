import SwiftUI

/// Toolbar notification bell + popover. Placement in the toolbar is up to the shell.
struct NotificationBell: View {
    private var model: TubeModel { TubeModel.shared }
    @State private var isOpen = false

    private var reduceTransparency: Bool {
        TubeChrome.reduceTransparency(tick: model.accessibilityTick)
    }
    private var unreadCount: Int {
        model.notifications.filter(\.unread).count
    }

    var body: some View {
        Button {
            if isOpen {
                isOpen = false
            } else {
                isOpen = true
                Task { await model.loadNotifications() }
            }
        } label: {
            bellLabel
        }
        .buttonStyle(PressScaleStyle())
        .help(unreadCount > 0 ? "\(unreadCount) new notifications" : "Notifications")
        .accessibilityLabel("Notifications")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            panel
        }
    }

    private var bellLabel: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: unreadCount > 0 ? "bell.fill" : "bell")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
                .background {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .allowsHitTesting(false)
                }
            if unreadCount > 0 {
                Text(unreadCount > 9 ? "9+" : "\(unreadCount)")
                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 12)
                    .background {
                        Capsule().fill(TubeColor.red)
                    }
                    .offset(x: 5, y: -3)
            }
        }
        .fixedSize()
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer(minLength: 0)
                TubeIconButton(icon: .refresh, help: "Refresh", showsProgress: model.notificationsLoading) {
                    Task { await model.loadNotifications() }
                }
                .disabled(model.notificationsLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            content
        }
        .frame(width: 440, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if !model.isSignedIn {
            message(icon: "person.crop.circle", title: "Sign in to see notifications")
        } else if model.notificationsLoading && model.notifications.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.notificationsError, !error.isEmpty {
            VStack(spacing: 12) {
                message(icon: "exclamationmark.triangle", title: error)
                Button("Try Again") {
                    Task { await model.loadNotifications() }
                }
                .buttonStyle(TubeGlassButtonStyle(prominent: false, glass: !reduceTransparency))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        } else if model.notifications.isEmpty {
            message(icon: "bell", title: "No notifications yet")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.notifications) { notification in
                        NotificationRow(notification: notification) {
                            open(notification)
                        }
                        .springIn()
                    }
                }
            }
        }
    }

    private func message(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ notification: YTNotification) {
        guard let videoID = notification.videoID else { return }
        let video = YTVideo(
            id: videoID,
            title: notification.title,
            channel: notification.channel ?? "",
            thumbnail: notification.thumbnailURL,
            published: notification.time,
            views: nil,
            length: nil,
            channelAvatar: notification.avatarURL,
            channelID: nil
        )
        isOpen = false
        model.open(video, short: false)
    }
}

private struct NotificationRow: View {
    var notification: YTNotification
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Color.primary.opacity(0.06)
                    if notification.thumbnailURL != nil || notification.avatarURL != nil {
                        TubePicture(url: notification.thumbnailURL ?? notification.avatarURL)
                    } else {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 88, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: TubeMetrics.media, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.title)
                        .font(.callout.weight(notification.unread ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let channel = notification.channel, !channel.isEmpty {
                        Text(channel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let time = notification.time, !time.isEmpty {
                        Text(time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                if notification.unread {
                    Circle()
                        .fill(TubeColor.red)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}
