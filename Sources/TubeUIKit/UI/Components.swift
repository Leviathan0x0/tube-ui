import AVFAudio
import Speech
import SwiftUI

struct Avatar: View {
    var url: URL?
    var name: String
    var size: CGFloat

    var body: some View {
        // The photo's ideal size must not escape. A loaded avatar was stretching the sidebar.
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                ZStack {
                    Circle().fill(.quaternary)
                    Text(initial)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TubePicture(url: url)
                }
                .frame(width: size, height: size)
                .clipped()
            }
            .compositingGroup()
            .clipShape(Circle())
            .contentShape(Circle())
            .accessibilityHidden(true)
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "Y").uppercased()
    }
}

struct DurationBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.black.opacity(0.75))
            }
            .padding(6)
            .accessibilityHidden(true)
    }
}

struct VideoThumb: View {
    var url: URL?
    var length: String?

    var body: some View {
        Color.primary.opacity(0.06)
            .overlay {
                TubePicture(url: url)
            }
            .overlay(alignment: .bottomTrailing) {
                if let length, !length.isEmpty {
                    DurationBadge(text: length)
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: TubeMetrics.media, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct VideoRow: View {
    var title: String
    var subtitle: String
    var thumbnail: URL?
    var length: String?

    var body: some View {
        HStack(spacing: 12) {
            VideoThumb(url: thumbnail, length: length)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ChannelRow: View {
    var title: String
    var avatar: URL?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: avatar, name: title, size: 36)
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TubeSearchField: View {
    @Binding var text: String
    @State private var focused = false
    @State private var suggestions: [SearchSuggestion] = []
    @State private var highlighted = -1
    @State private var showSuggestions = false
    @State private var suggestionGeneration = 0
    @State private var suggestTask: Task<Void, Never>?
    @State private var dictation = SearchDictation()

    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.001))
                .glassEffect(.regular, in: Capsule())
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                ReiconSymbol(icon: .search)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                TubeSearchNSField(text: $text, onFocus: { focused = $0 }, onCommand: handleCommand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
                micButton
            }
            .padding(.horizontal, 14)
            SearchSuggestionPanelHost(
                rows: showSuggestions ? suggestions : [],
                highlighted: highlighted,
                onPick: { submit($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .frame(width: 480, height: 36)
        .overlay {
            Capsule()
                .strokeBorder(focused ? TubeColor.red : Color.primary.opacity(0.14), lineWidth: focused ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .onChange(of: text) { _, _ in queueSuggestions() }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                queueSuggestions()
            } else {
                let generation = suggestionGeneration
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !focused, generation == suggestionGeneration else { return }
                    dismissSuggestions()
                    if dictation.isListening { dictation.stop() }
                }
            }
        }
        .transaction { $0.animation = nil }
        .accessibilityLabel("Search")
    }

    private var micButton: some View {
        Button {
            dictation.toggle(text: text) { text = $0 }
        } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(dictation.isListening ? TubeColor.red : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dictation.helpText)
        .accessibilityLabel(dictation.helpText)
    }

    private func handleCommand(_ command: TubeSearchCommand) -> Bool {
        switch command {
        case .down:
            guard showSuggestions, !suggestions.isEmpty else { return false }
            highlighted = min(highlighted + 1, suggestions.count - 1)
            return true
        case .up:
            guard showSuggestions, !suggestions.isEmpty, highlighted >= 0 else { return false }
            highlighted = max(highlighted - 1, -1)
            return true
        case .submit:
            if highlighted >= 0, highlighted < suggestions.count {
                submit(suggestions[highlighted].text)
            } else {
                submit(text)
            }
            return true
        case .cancel:
            guard showSuggestions || highlighted >= 0 else { return false }
            dismissSuggestions()
            return true
        }
    }

    private func submit(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        text = query
        dismissSuggestions()
        Task { await model.submitSearch(query) }
    }

    private func queueSuggestions() {
        suggestTask?.cancel()
        guard focused, !text.isEmpty, !dictation.isListening else {
            dismissSuggestions()
            return
        }
        let prefix = text
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let results = await model.suggest(for: prefix)
            guard !Task.isCancelled, prefix == text else { return }
            suggestions = results
            highlighted = -1
            showSuggestions = focused && !results.isEmpty && !dictation.isListening
        }
    }

    private func dismissSuggestions() {
        suggestTask?.cancel()
        suggestions = []
        highlighted = -1
        showSuggestions = false
        suggestionGeneration &+= 1
    }
}

/// Voice dictation for the search field. Streams finalized text (plus live partials)
/// into the field through the `update` closure handed to `toggle`.
@MainActor
@Observable
final class SearchDictation {
    private(set) var isListening = false
    private(set) var failure: String?

    var helpText: String {
        if let failure { return failure }
        return isListening ? "Stop dictation" : "Dictate search"
    }

    private let audioQueue = DispatchQueue(label: "app.tubeui.dictation")
    private var session: DictationSession?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var starting = false
    private var baseText = ""
    private var onText: ((String) -> Void)?

    func toggle(text: String, update: @escaping (String) -> Void) {
        if isListening || starting {
            stop()
        } else {
            starting = true
            let token = generation
            Task {
                await start(text: text, update: update, token: token)
                if token == generation { starting = false }
            }
        }
    }

    func stop() {
        generation += 1
        starting = false
        finish(cancelTask: true)
    }

    /// `cancelTask` is false when this runs from the recognition callback.
    /// Cancelling the task from inside that callback deadlocks Speech and hangs the app.
    /// Engine stop and tap removal stay on `audioQueue`. Doing either on the main
    /// thread deadlocks the audio device and freezes the window before any words arrive.
    private func finish(cancelTask: Bool) {
        let running = task
        task = nil
        isListening = false
        onText = nil
        let session = self.session
        self.session = nil
        if let session {
            let work: @Sendable () -> Void = { session.shutdown() }
            audioQueue.async(execute: work)
        }
        if cancelTask {
            running?.cancel()
        }
    }

    private func start(text: String, update: @escaping (String) -> Void, token: Int) async {
        failure = nil
        if isListening { finish(cancelTask: true) }
        guard token == generation else { return }
        guard await authorize() else { return }
        guard token == generation else { return }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            failure = "Speech recognition is unavailable"
            return
        }
        let session = DictationSession()
        let prepared = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let work: @Sendable () -> Void = {
                continuation.resume(returning: session.prepare())
            }
            audioQueue.async(execute: work)
        }
        guard token == generation else {
            let work: @Sendable () -> Void = { session.shutdown() }
            audioQueue.async(execute: work)
            return
        }
        guard prepared else {
            failure = "Microphone is unavailable"
            return
        }
        baseText = text
        onText = update
        self.session = session
        isListening = true
        // The recognition task has to exist before the tap appends. Appending
        // first deadlocks Speech, and the window stops accepting input.
        // Speech calls this off the main thread. A closure formed here would
        // stay on the main actor and trap the same way the audio tap did.
        let forward: @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void = { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && result == nil
            Task { @MainActor in
                self?.handle(transcript: transcript, isFinal: isFinal, failed: failed)
            }
        }
        task = recognizer.recognitionTask(with: session.request, resultHandler: forward)
        session.gate.open()
        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let work: @Sendable () -> Void = {
                continuation.resume(returning: session.start())
            }
            audioQueue.async(execute: work)
        }
        guard token == generation else { return }
        guard started else {
            failure = "Microphone could not start"
            finish(cancelTask: true)
            return
        }
    }

    private func authorize() async -> Bool {
        // macOS kills the process when a permission is requested without a usage
        // description in the main bundle. Bare `swift build` executables have no
        // Info.plist — only the bundled app (Support/build-app.sh) can dictate.
        let bundle = Bundle.main
        guard bundle.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
              bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        else {
            failure = "Dictation needs the installed app build"
            return false
        }
        let speechOK = await speechAuthorized()
        guard speechOK else {
            failure = "Speech recognition is not enabled"
            return false
        }
        let micOK = await microphoneAuthorized()
        guard micOK else {
            failure = "Microphone access is not enabled"
            return false
        }
        return true
    }

    private func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            break
        @unknown default:
            return false
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func microphoneAuthorized() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        if AVAudioApplication.shared.recordPermission == .denied { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func handle(transcript: String, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if !transcript.isEmpty {
            onText?(baseText.isEmpty ? transcript : baseText + " " + transcript)
        }
        if isFinal {
            finish(cancelTask: false)
        } else if failed {
            failure = "Dictation failed"
            finish(cancelTask: false)
        }
    }
}

/// One microphone session. Every `AVAudioEngine` call happens on the dictation
/// queue. `SFSpeechAudioBufferRecognitionRequest.append` is safe from the audio tap.
private final class DictationSession: @unchecked Sendable {
    let request = SFSpeechAudioBufferRecognitionRequest()
    let gate = DictationGate()
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    func prepare() -> Bool {
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return false }
        let sink = SpeechBufferSink(request)
        let gate = self.gate
        // The old installTap closure inherits the main actor and traps on the
        // audio thread (SIGTRAP, dispatch_assert_queue). The macOS 27 tap is
        // @Sendable, so it stays on the audio thread. The read-only buffer is
        // only valid inside the callback, so copy it before speech takes it.
        do {
            if #available(macOS 27.0, *) {
                try input.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                    guard gate.isOpen else { return }
                    sink.append(AVAudioPCMBuffer(copying: buffer))
                }
            } else {
                input.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
                    guard gate.isOpen else { return }
                    sink.append(buffer)
                }
            }
        } catch {
            return false
        }
        tapInstalled = true
        engine.prepare()
        return true
    }

    func start() -> Bool {
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    func shutdown() {
        gate.close()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        request.endAudio()
    }
}

private final class SpeechBufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }
}

private final class DictationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var openFlag = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openFlag
    }

    func open() {
        lock.lock()
        openFlag = true
        lock.unlock()
    }

    func close() {
        lock.lock()
        openFlag = false
        lock.unlock()
    }
}

struct TubeIconButton: View {
    var icon: Reicon
    var help: String
    var showsProgress: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    ReiconSymbol(icon: icon)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

struct HomeCard: View {
    var video: YTVideo
    private var model: TubeModel { TubeModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.open(video)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    thumbnail
                    Text(video.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            channelLine
        }
    }

    @ViewBuilder private var channelLine: some View {
        let line = HStack(alignment: .top, spacing: 10) {
            Avatar(
                url: video.channelAvatar,
                name: video.channel.isEmpty ? video.title : video.channel,
                size: 32
            )
            VStack(alignment: .leading, spacing: 2) {
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
        if let channelID = video.channelID, channelID.hasPrefix("UC"), !video.channel.isEmpty {
            Button {
                model.openChannel(id: channelID, name: video.channel)
            } label: {
                line
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(video.channel)
        } else {
            line
        }
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ShortCard: View {
    var title: String
    var subtitle: String
    var thumbnail: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.primary.opacity(0.06)
                .overlay {
                    TubePicture(url: thumbnail)
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct TubeNotice: View {
    var message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ReiconSymbol(icon: .alertCircle, weight: .filled)
                .frame(width: 16, height: 16)
                .foregroundStyle(TubeColor.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TubeActionButton: View {
    var title: String
    var prominent: Bool
    var glass: Bool
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(TubeGlassButtonStyle(prominent: prominent, glass: glass))
            .controlSize(prominent ? .large : .regular)
    }
}
