import AppKit
import AVFoundation
import SwiftUI

/// One AVPlayer for the whole window. Fullscreen reparents this view
/// instead of opening a second stream.
@MainActor
final class TubePlayerHost: NSObject {
    private static var existing: TubePlayerHost?
    private static let playbackError = "This video can't play inside TubeUI."
    private static let commands: Set<String> = ["play", "pause", "seek", "volume", "mute", "unmute"]

    static var shared: TubePlayerHost {
        if let existing { return existing }
        let host = TubePlayerHost()
        existing = host
        return host
    }

    static func stopIfNeeded() {
        existing?.stop()
    }

    let videoView: PlayerVideoView
    let player: AVPlayer
    private let parking = NSView(frame: .zero)
    private var loadedID: String?
    private var sources: [Innertube.PlayableMedia] = []
    private var sourceIndex = 0
    private var pendingAction: (String, Double)?
    private var lastCommand = 0
    private var ownerGeneration = 0
    private var generation = 0
    private var loadGeneration = 0
    private var failedSource: Int?
    private var ended = false
    private var resumeTime: CMTime?
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    private override init() {
        let view = PlayerVideoView(frame: .zero)
        let player = AVPlayer()
        player.preventsDisplaySleepDuringVideoPlayback = true
        self.videoView = view
        self.player = player
        super.init()
        view.player = player
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            Task { @MainActor in
                TubePlayerHost.shared.publish()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                TubePlayerHost.shared.noteEnded()
            }
        }
    }

    func claim(_ view: PlayerContainer) {
        generation &+= 1
        view.generation = generation
        ownerGeneration = generation
        if videoView.superview !== view {
            videoView.removeFromSuperview()
            view.addSubview(videoView)
        }
        videoView.frame = view.bounds
    }

    func parkIfOwner(_ view: PlayerContainer) {
        guard view.generation == ownerGeneration, videoView.superview === view else { return }
        videoView.removeFromSuperview()
        parking.addSubview(videoView)
    }

    func needsClaim(into view: PlayerContainer) -> Bool {
        guard view.window != nil, videoView.superview !== view else { return false }
        let owner = videoView.superview
        return owner == nil || owner === parking || owner?.window == nil
    }

    func sync(videoID: String, command: Int, action: String, value: Double) {
        guard YTVideo.isVideoID(videoID), TubeModel.shared.watching?.id == videoID else { return }
        if loadedID != videoID {
            loadedID = videoID
            lastCommand = command
            pendingAction = nil
            resumeTime = nil
            beginLoad(videoID)
            return
        }
        guard command != lastCommand else { return }
        lastCommand = command
        guard Self.commands.contains(action) else { return }
        if player.currentItem == nil {
            pendingAction = (action, value)
            return
        }
        apply(action, value)
    }

    func stop() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        loadedID = nil
        sources = []
        sourceIndex = 0
        pendingAction = nil
        ended = false
        failedSource = nil
        resumeTime = nil
        lastCommand = 0
        statusObservation?.invalidate()
        statusObservation = nil
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func beginLoad(_ videoID: String) {
        loadGeneration &+= 1
        let generation = loadGeneration
        ended = false
        failedSource = nil
        // Drop the previous video's rendition height so the quality label can't
        // read a stale value while the new one loads.
        TubeModel.shared.playingHeight = 0
        sources = []
        sourceIndex = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        TubeModel.shared.playerError = nil
        let token = TubeModel.shared.tokens?.accessToken
        loadTask?.cancel()
        loadTask = Task {
            let found = await Innertube.playables(videoID: videoID, accessToken: token)
            guard !Task.isCancelled, generation == loadGeneration, TubeModel.shared.watching?.id == videoID else { return }
            guard !found.isEmpty else {
                TubeModel.shared.playerError = Self.playbackError
                TubeModel.shared.playerPlaying = false
                return
            }
            sources = playbackOrder(found)
            guard let first = sources.first else { return }
            start(first, index: 0, generation: generation)
        }
    }

    /// Preferred rendition first, then the rest, so a failed manifest falls
    /// through to the direct files instead of stopping at the end of the list.
    private func playbackOrder(_ list: [Innertube.PlayableMedia]) -> [Innertube.PlayableMedia] {
        guard !list.isEmpty else { return list }
        let index = preferredIndex(in: list)
        guard index > 0, list.indices.contains(index) else { return list }
        return Array(list[index...]) + Array(list[..<index])
    }

    /// Tallest rendition at or under the cap, across every client response.
    /// Auto (`0`) still caps at 1080. The first file is not assumed to be the best.
    private func preferredIndex(in list: [Innertube.PlayableMedia]) -> Int {
        Innertube.preferredPlayableIndex(list.map(\.height), cap: TubeModel.shared.playerQuality)
    }

    /// Re-collect sources for a new quality cap and resume near the old position.
    func reloadForQualityChange() {
        guard let videoID = loadedID, TubeModel.shared.watching?.id == videoID else { return }
        let paused = player.timeControlStatus == .paused
        resumeTime = player.currentItem.map { $0.currentTime() }
        pendingAction = paused ? ("pause", 0) : nil
        beginLoad(videoID)
    }

    private func start(_ media: Innertube.PlayableMedia, index: Int, generation: Int) {
        guard generation == loadGeneration else { return }
        sourceIndex = index
        ended = false
        // Seed from the data layer; presentationSize refines once ready.
        TubeModel.shared.playingHeight = media.height ?? 0
        if let audioURL = media.audioURL {
            Task { await startPaired(media, audioURL: audioURL, index: index, generation: generation) }
            armFallback(index: index, generation: generation)
            return
        }
        let asset = AVURLAsset(url: media.url, options: [AVURLAssetHTTPUserAgentKey: media.userAgent])
        beginItem(AVPlayerItem(asset: asset), index: index, generation: generation)
        if media.height == nil {
            armFallback(index: index, generation: generation)
        }
    }

    /// Picture and audio are separate files. Clamp both to the real video length:
    /// the container clock is about twice as long as the picture.
    private func startPaired(
        _ media: Innertube.PlayableMedia,
        audioURL: URL,
        index: Int,
        generation: Int
    ) async {
        guard generation == loadGeneration else { return }
        let options = [AVURLAssetHTTPUserAgentKey: media.userAgent]
        let videoAsset = AVURLAsset(url: media.url, options: options)
        let audioAsset = AVURLAsset(url: audioURL, options: options)
        do {
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            async let videoDuration = videoAsset.load(.duration)
            async let audioDuration = audioAsset.load(.duration)
            let pictures = try await videoTracks
            let sounds = try await audioTracks
            guard let picture = pictures.first, let sound = sounds.first else {
                fail(generation: generation, sourceIndex: index)
                return
            }
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                fail(generation: generation, sourceIndex: index)
                return
            }
            let limits = [try await videoDuration, try await audioDuration].map(\.seconds).filter { $0.isFinite && $0 > 0 }
            var seconds = limits.min() ?? 0
            if let authored = media.duration, authored > 0 {
                seconds = seconds > 0 ? min(seconds, authored) : authored
            }
            guard seconds > 0, generation == loadGeneration else {
                if generation == loadGeneration {
                    fail(generation: generation, sourceIndex: index)
                }
                return
            }
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
            try videoTrack.insertTimeRange(range, of: picture, at: .zero)
            try audioTrack.insertTimeRange(range, of: sound, at: .zero)
            guard generation == loadGeneration else { return }
            beginItem(AVPlayerItem(asset: composition), index: index, generation: generation)
        } catch {
            fail(generation: generation, sourceIndex: index)
        }
    }

    /// HLS and split files that never become ready drop to the next source.
    private func armFallback(index: Int, generation: Int) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard generation == self.loadGeneration, self.sourceIndex == index else { return }
            let status = self.player.currentItem?.status
            guard self.player.currentItem == nil || status == .unknown else { return }
            self.fail(generation: generation, sourceIndex: index)
        }
    }

    private func beginItem(_ item: AVPlayerItem, index: Int, generation: Int) {
        guard generation == loadGeneration else { return }
        applyQualityCap(item)
        watch(item, sourceIndex: index, generation: generation)
        player.replaceCurrentItem(with: item)
        player.isMuted = TubeModel.shared.playerMuted
        player.volume = Float(min(max(TubeModel.shared.playerVolume, 0), 100) / 100)
        // Quality swap: seek to the captured position before resuming. The seek
        // is async, so one frame at the wrong position is possible.
        if let resume = resumeTime, resume.seconds.isFinite, resume.seconds > 0 {
            resumeTime = nil
            player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if let pending = pendingAction {
            pendingAction = nil
            apply(pending.0, pending.1)
        } else {
            player.play()
        }
    }

    /// Auto and 1080 both stop at 1080p. The box is square so a portrait Short
    /// at the same tier still fits; 1440 and 4K do not.
    private func applyQualityCap(_ item: AVPlayerItem) {
        let tier = TubeModel.shared.playerQuality
        let side = CGFloat(tier > 0 ? tier : 1080)
        let long = side * 16 / 9
        item.preferredMaximumResolution = CGSize(width: long, height: long)
    }

    private func watch(_ item: AVPlayerItem, sourceIndex: Int, generation: Int) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { _, _ in
            Task { @MainActor in
                TubePlayerHost.shared.noteStatus(generation: generation, sourceIndex: sourceIndex)
            }
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                TubePlayerHost.shared.fail(generation: generation, sourceIndex: sourceIndex)
            }
        }
    }

    private func noteStatus(generation: Int, sourceIndex: Int) {
        guard generation == loadGeneration else { return }
        guard player.currentItem?.status == .failed else {
            if player.currentItem?.status == .readyToPlay {
                TubeModel.shared.playerError = nil
                publishPlayingHeight()
            }
            return
        }
        fail(generation: generation, sourceIndex: sourceIndex)
    }

    private func fail(generation: Int, sourceIndex: Int) {
        guard generation == loadGeneration, failedSource != sourceIndex else { return }
        failedSource = sourceIndex
        let next = sourceIndex + 1
        guard sources.indices.contains(next) else {
            TubeModel.shared.playerError = Self.playbackError
            TubeModel.shared.playerPlaying = false
            return
        }
        start(sources[next], index: next, generation: generation)
    }

    private func noteEnded() {
        guard player.currentItem != nil, loadedID != nil else { return }
        ended = true
        publish()
    }

    /// presentationSize can lag `readyToPlay` slightly; the periodic publish
    /// pass fills it in whenever it lands later.
    private func publishPlayingHeight() {
        let size = player.currentItem?.presentationSize ?? .zero
        guard size.width > 0, size.height > 0 else { return }
        let short = min(size.width, size.height)
        let tiers = [144, 240, 360, 480, 720, 1080, 1440, 2160]
        // Containers report sizes a pixel or two off the label; snap to tier.
        TubeModel.shared.playingHeight =
            tiers.min(by: { abs(CGFloat($0) - short) < abs(CGFloat($1) - short) }) ?? Int(short.rounded())
    }

    private func publish() {
        guard let item = player.currentItem, loadedID != nil else { return }
        if TubeModel.shared.playingHeight == 0 {
            publishPlayingHeight()
        }
        let duration = item.duration.seconds
        let current = item.currentTime().seconds
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let safeCurrent = current.isFinite && current > 0 ? current : 0
        let state: Int
        if ended {
            state = 0
        } else if player.timeControlStatus == .paused {
            state = 2
        } else {
            state = 1
        }
        TubeModel.shared.applyPlayer(current: safeCurrent, duration: safeDuration, state: state)
    }

    private func apply(_ action: String, _ value: Double) {
        switch action {
        case "play":
            let restart = ended
            ended = false
            if restart {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in
                        TubePlayerHost.shared.player.play()
                    }
                }
            } else {
                player.play()
            }
        case "pause":
            player.pause()
        case "seek":
            let seconds = value.isFinite ? max(value, 0) : 0
            ended = false
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        case "volume":
            let level = value.isFinite ? min(max(value, 0), 100) : 0
            player.isMuted = level == 0
            player.volume = Float(level / 100)
        case "mute":
            player.isMuted = true
        case "unmute":
            player.isMuted = false
            player.volume = Float(min(max(TubeModel.shared.playerVolume, 0), 100) / 100)
        default:
            break
        }
    }

}

final class PlayerVideoView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

final class PlayerContainer: NSView {
    var generation = 0
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    func attach() {
        TubePlayerHost.shared.claim(self)
    }

    override func layout() {
        super.layout()
        let host = TubePlayerHost.shared
        if host.needsClaim(into: self) {
            attach()
            return
        }
        guard host.videoView.superview === self else { return }
        host.videoView.frame = bounds
    }
}

struct TubePlayerRepresentable: NSViewRepresentable {
    var videoID: String
    var command: Int
    var action: String
    var actionValue: Double

    func makeNSView(context: Context) -> PlayerContainer {
        let view = PlayerContainer()
        view.attach()
        return view
    }

    func updateNSView(_ view: PlayerContainer, context: Context) {
        view.attach()
        TubePlayerHost.shared.sync(videoID: videoID, command: command, action: action, value: actionValue)
    }

    static func dismantleNSView(_ nsView: PlayerContainer, coordinator: Void) {
        TubePlayerHost.shared.parkIfOwner(nsView)
    }
}

struct PlayerHole: View {
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        ZStack {
            Color.black
            TubePlayerRepresentable(
                videoID: model.watching?.id ?? "",
                command: model.playerCommand,
                action: model.playerAction,
                actionValue: model.playerActionValue
            )
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.togglePlay() }
                .accessibilityLabel(model.playerPlaying ? "Pause" : "Play")
                .accessibilityAddTraits(.isButton)
            if !model.playerPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.45), in: Circle())
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Custom scrubber. The stock macOS slider is a ~4px pill with no visible
/// thumb, so this draws a thick track (8px, 14px on hover) and a thumb.
struct PlayerScrubber: View {
    var compact: Bool
    var onDark = false
    @State private var hovering = false
    @State private var dragging = false
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        let trackHeight: CGFloat = compact ? 6 : 8
        let hoverHeight: CGFloat = compact ? 10 : 14
        let thumbSize: CGFloat = compact ? 14 : 18
        GeometryReader { geo in
            let span = max(model.playerDuration, 0.01)
            let progress = span > 0.01 ? min(max(model.playerTime / span, 0), 1) : 0
            let x = progress * geo.size.width
            let shown = hovering || dragging
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(onDark ? AnyShapeStyle(.white.opacity(0.28)) : AnyShapeStyle(.quaternary))
                    .frame(height: shown ? hoverHeight : trackHeight)
                Capsule()
                    .fill(TubeColor.red)
                    .frame(width: x, height: shown ? hoverHeight : trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .scaleEffect(shown ? 1 : 0.01)
                    .opacity(shown ? 1 : 0)
                    .offset(x: max(0, min(x - thumbSize / 2, geo.size.width - thumbSize)))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard model.playerDuration > 0 else { return }
                        dragging = true
                        model.playerScrubbing = true
                        model.playerTime = min(max(gesture.location.x / geo.size.width, 0), 1) * span
                    }
                    .onEnded { _ in
                        dragging = false
                        model.finishScrub()
                    }
            )
        }
        .frame(height: compact ? 24 : 32)
        .frame(maxWidth: .infinity)
        .layoutPriority(1)
        .onHover { hovering = $0 }
        .opacity(model.playerDuration > 0 ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: hovering || dragging)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(TubeFormat.clock(model.playerTime))
    }
}

/// Speaker button. Click mutes. Hover reveals a vertical volume slider in a
/// popover so the control can sit outside the chrome without being clipped
/// or losing clicks.
struct PlayerVolumeControl: View {
    var onDark: Bool
    @State private var buttonHover = false
    @State private var panelHover = false
    @State private var open = false
    @State private var closeTask: Task<Void, Never>?
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        Button {
            model.toggleMute()
        } label: {
            Image(
                systemName: model.playerMuted || model.playerVolume == 0
                    ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            .font(.body.weight(.semibold))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.playerMuted ? "Unmute" : "Mute")
        .accessibilityLabel(model.playerMuted ? "Unmute" : "Mute")
        .onHover { buttonHover = $0; update() }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            panel
                .padding(10)
                .onHover { panelHover = $0; update() }
        }
        .animation(.easeOut(duration: 0.12), value: open)
    }

    private func update() {
        closeTask?.cancel()
        guard buttonHover || panelHover else {
            // Grace period covers the gap between the button and the popover.
            closeTask = Task {
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                open = buttonHover || panelHover
            }
            return
        }
        open = true
    }

    private var panel: some View {
        VStack(spacing: 6) {
            slider
            Text("\(Int(model.playerVolume.rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(onDark ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
        }
        .frame(width: 34, height: 118)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(onDark ? AnyShapeStyle(.black.opacity(0.6)) : AnyShapeStyle(.ultraThinMaterial))
        }
        .contentShape(Rectangle())
    }

    private var slider: some View {
        GeometryReader { geo in
            let level = min(max(model.playerVolume, 0), 100) / 100
            let thumb: CGFloat = 13
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(onDark ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.quaternary))
                    .frame(width: 5)
                Capsule()
                    .fill(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: 5, height: max(level * geo.size.height, 5))
                Circle()
                    .fill(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: thumb, height: thumb)
                    .offset(y: -level * (geo.size.height - thumb))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let value = min(max((geo.size.height - gesture.location.y) / geo.size.height, 0), 1) * 100
                        model.playerVolume = value
                        model.playerMuted = value == 0
                        model.playerDo(value == 0 ? "mute" : "volume", value)
                    }
                    .onEnded { _ in model.commitVolume() }
            )
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(model.playerVolume.rounded())) percent")
        }
        .frame(width: 22, height: 88)
    }
}

struct PlayerChrome: View {
    var onDark: Bool
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        HStack(spacing: 8) {
            chromeButton(
                model.playerPlaying ? "pause.fill" : "play.fill",
                help: model.playerPlaying ? "Pause" : "Play"
            ) {
                model.togglePlay()
            }
            chromeButton("backward.end.fill", help: "Previous", enabled: model.hasPrevious) {
                model.playPrevious()
            }
            chromeButton("forward.end.fill", help: "Next", enabled: model.hasNext) {
                model.playNext()
            }
            Text(TubeFormat.clock(model.playerTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(onDark ? .white.opacity(0.8) : .secondary)
                .frame(width: 58, alignment: .trailing)
            PlayerScrubber(compact: false, onDark: onDark)
            Text(TubeFormat.clock(model.playerDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(onDark ? .white.opacity(0.8) : .secondary)
                .frame(width: 58, alignment: .leading)
            PlayerVolumeControl(onDark: onDark)
            qualityMenu
            chromeButton(
                model.playerFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: model.playerFullscreen ? "Exit Full Screen" : "Full Screen"
            ) {
                model.setFullscreen(!model.playerFullscreen)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(onDark ? .white : .primary)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(onDark ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(.ultraThinMaterial))
        }
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Quality", selection: Binding(
                get: { model.playerQuality },
                set: { newValue in
                    guard newValue != model.playerQuality else { return }
                    model.playerQuality = newValue
                    TubePlayerHost.shared.reloadForQualityChange()
                }
            )) {
                Text("Auto").tag(0)
                Text("1080p").tag(1080)
                Text("720p").tag(720)
                Text("480p").tag(480)
                Text("360p").tag(360)
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                Text(Self.qualityLabel(model.playerQuality, playing: model.playingHeight))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .fixedSize()
            .frame(height: 28)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(Color.primary))
        .help("Quality")
        .accessibilityLabel("Quality")
    }

    static func qualityLabel(_ cap: Int, playing: Int) -> String {
        // Show the rendition that is actually playing. The menu still selects
        // the cap; a mismatch (asked for 1080, got 720) stays visible.
        if playing > 0 {
            return cap == 0 ? "Auto \(playing)p" : "\(playing)p"
        }
        return cap == 0 ? "Auto" : "\(cap)p"
    }

    private func chromeButton(
        _ system: String,
        help: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct FullscreenStage: View {
    var video: YTVideo
    var short: Bool
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        GeometryReader { geo in
            let commentsWidth: CGFloat = short && model.commentsOpen ? 360 : 0
            let railWidth: CGFloat = short ? 84 : 0
            let aspect = short ? 9.0 / 16.0 : 16.0 / 9.0
            let room = max(geo.size.width - commentsWidth - railWidth - 24, 160)
            let height = min(geo.size.height, room / aspect)
            let width = height * aspect
            HStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 16) {
                        PlayerHole()
                            .frame(width: width, height: height)
                        if short {
                            fullscreenRail
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack {
                        Spacer(minLength: 0)
                        PlayerChrome(onDark: true)
                            .padding(.bottom, 16)
                            .frame(maxWidth: min(room, 860))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if short, model.commentsOpen {
                    CommentsPanel(scrolling: true, showsClose: true)
                        .frame(width: commentsWidth)
                        .background(.background)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(video.title)
    }

    private var fullscreenRail: some View {
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
                .buttonStyle(.plain)
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
        }
        .frame(width: 72)
    }

    private func railButton(
        system: String,
        title: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            railLabel(system: system, title: title, active: active)
        }
        .buttonStyle(PressScaleStyle())
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
}
