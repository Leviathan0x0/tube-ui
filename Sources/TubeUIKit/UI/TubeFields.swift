import AppKit
import SwiftUI

/// AppKit line field. SwiftUI `TextField` in this window was not receiving keystrokes
/// (toolbar search, comments, history). `NSTextField` becomes the real first responder.
struct TubeLineField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var multiline: Bool = false
    var secure: Bool = false
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? EditingSecureField(string: text) : EditingTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.cell?.sendsActionOnEndEditing = false
        field.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
        field.maximumNumberOfLines = multiline ? 4 : 1
        field.cell?.wraps = multiline
        field.cell?.isScrollable = true
        field.isEditable = true
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TubeLineField

        init(_ parent: TubeLineField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = field.stringValue
            guard value != parent.text else { return }
            parent.text = value
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let onSubmit = parent.onSubmit else {
                return false
            }
            onSubmit()
            return true
        }
    }
}

enum TubeSearchCommand: Sendable {
    case up
    case down
    case submit
    case cancel
}

/// Toolbar search field. A SwiftUI `TextField` here never became first responder,
/// so typing did nothing. Arrow keys are commands, not a key-press swallow.
/// `NSSearchField` draws its own magnifying glass beside the custom one, so this
/// is a plain text field.
struct TubeSearchNSField: NSViewRepresentable {
    @Binding var text: String
    var onFocus: (Bool) -> Void
    var onCommand: (TubeSearchCommand) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = EditingTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.cell?.sendsActionOnEndEditing = false
        field.cell?.isScrollable = true
        field.isEditable = true
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.field = field
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TubeSearchNSField
        weak var field: NSTextField?

        init(_ parent: TubeSearchNSField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = field.stringValue
            guard value != parent.text else { return }
            parent.text = value
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocus(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocus(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: TubeSearchCommand?
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                command = .down
            case #selector(NSResponder.moveUp(_:)):
                command = .up
            case #selector(NSResponder.insertNewline(_:)):
                command = .submit
            case #selector(NSResponder.cancelOperation(_:)):
                command = .cancel
            default:
                command = nil
            }
            guard let command else { return false }
            return parent.onCommand(command)
        }
    }
}

/// Suggestion list in a panel that cannot become key, so the search field keeps
/// the keyboard. SwiftUI popovers were taking focus after the first character.
struct SearchSuggestionPanelHost: NSViewRepresentable {
    var rows: [SearchSuggestion]
    var highlighted: Int
    var onPick: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HitTransparentView(frame: .zero)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.anchor = view
        context.coordinator.render()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SearchSuggestionPanelHost
        weak var anchor: NSView?
        private let panel: SuggestionPanel
        private let stack = NSStackView()

        init(_ parent: SearchSuggestionPanelHost) {
            self.parent = parent
            panel = SuggestionPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            super.init()
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            panel.contentView = effect
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                stack.topAnchor.constraint(equalTo: effect.topAnchor),
                stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
        }

        func attach(_ view: NSView) {
            anchor = view
        }

        func close() {
            if let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            panel.orderOut(nil)
        }

        func render() {
            guard let anchor, anchor.window != nil, !parent.rows.isEmpty else {
                close()
                return
            }
            stack.arrangedSubviews.forEach { view in
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for (index, row) in parent.rows.enumerated() {
                let button = SuggestionButton(title: row.text, systemName: row.isHistory ? "clock" : "arrow.trending.up")
                button.isHighlightedRow = index == parent.highlighted
                button.target = self
                button.action = #selector(pick(_:))
                button.tag = index
                button.sendAction(on: [.leftMouseDown])
                stack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
            }
            let height = min(CGFloat(parent.rows.count) * 34 + 12, 420)
            position(height: height)
        }

        private func position(height: CGFloat) {
            guard let anchor, let window = anchor.window else { return }
            let rect = anchor.convert(anchor.bounds, to: nil)
            let screen = window.convertToScreen(rect)
            let width = max(screen.width, 320)
            let frame = NSRect(x: screen.minX, y: screen.minY - height - 6, width: width, height: height)
            panel.setFrame(frame, display: true)
            if panel.parent !== window {
                if let parent = panel.parent {
                    parent.removeChildWindow(panel)
                }
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFrontRegardless()
        }

        @objc private func pick(_ sender: NSButton) {
            guard parent.rows.indices.contains(sender.tag) else { return }
            parent.onPick(parent.rows[sender.tag].text)
        }
    }
}

/// SwiftUI puts this anchor over the search capsule. It must not take clicks,
/// or the text field never becomes first responder and typing does nothing.
private final class HitTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// SwiftUI handles the click after AppKit and clears first responder. Claim it
/// again on the next turn so keystrokes reach the field editor.
private class EditingTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { isEditable }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        claimFocus()
    }

    func claimFocus() {
        let field = self
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            let editor = field.currentEditor()
            if window.firstResponder !== field, window.firstResponder !== editor {
                window.makeFirstResponder(field)
            }
        }
    }
}

private final class EditingSecureField: NSSecureTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { isEditable }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let field = self
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            if window.firstResponder !== field, window.firstResponder !== field.currentEditor() {
                window.makeFirstResponder(field)
            }
        }
    }
}

private final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SuggestionButton: NSButton {
    var isHighlightedRow = false {
        didSet { needsDisplay = true }
    }

    init(title: String, systemName: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 32))
        self.title = title
        self.bezelStyle = .inline
        self.isBordered = false
        self.alignment = .left
        self.font = .systemFont(ofSize: NSFont.systemFontSize)
        self.imagePosition = .imageLeading
        self.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        self.contentTintColor = .labelColor
        self.setButtonType(.momentaryChange)
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlightedRow {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Loads the sharpest candidate, then the original URL. Fills the parent frame.
struct TubePicture: View {
    var url: URL?

    var body: some View {
        TubePictureImage(candidates: TubeImage.displayCandidates(url))
    }
}

private struct TubePictureImage: View {
    var candidates: [URL]
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: candidates.map(\.absoluteString).joined(separator: "\n")) {
            image = await TubeImageCache.shared.first(in: candidates)
        }
    }
}

@MainActor
final class TubeImageCache {
    static let shared = TubeImageCache()

    private var memory: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private let session: URLSession

    private init() {
        let cache = URLCache(memoryCapacity: 48 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func first(in candidates: [URL]) async -> NSImage? {
        for url in candidates {
            let key = url.absoluteString
            if let cached = memory[key] { return cached }
            if misses.contains(key) { continue }
            if let image = await fetch(url) {
                memory[key] = image
                return image
            }
        }
        return nil
    }

    private func fetch(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusIsMissing(status) {
                misses.insert(url.absoluteString)
                return nil
            }
            guard (200..<300).contains(status), let image = NSImage(data: data), image.isValid else { return nil }
            let width = image.representations.first?.pixelsWide ?? Int(image.size.width)
            let name = url.lastPathComponent
            if (name.contains("maxresdefault") || name.contains("hq720")), width < 640 {
                misses.insert(url.absoluteString)
                return nil
            }
            return image
        } catch {
            return nil
        }
    }

    private func statusIsMissing(_ status: Int) -> Bool {
        status == 404 || status == 410
    }
}

/// Escape dismisses search or the player. Only Escape is consumed, and never
/// while a text view is the first responder — that was blocking typing.
struct EscapeMonitor: NSViewRepresentable {
    var onEscape: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator: @unchecked Sendable {
        var onEscape: () -> Bool
        private var monitor: Any?

        init(onEscape: @escaping () -> Bool) {
            self.onEscape = onEscape
        }

        func install(on view: NSView) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let escape = event.keyCode == 53
                let typing = event.window?.firstResponder is NSTextView
                let consume = MainActor.assumeIsolated { () -> Bool in
                    guard escape, !typing else { return false }
                    return self.onEscape()
                }
                return consume ? nil : event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
