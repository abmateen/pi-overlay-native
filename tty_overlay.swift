import AppKit
import AVFoundation
import Darwin
import Foundation
import Speech
import WebKit

// ---------------------------------------------------------------------------
// TIOCSTI injection
// ---------------------------------------------------------------------------

let TIOCSTI: UInt = 0x80017472 // macOS: _IOW('t', 114, char)

func debugLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/tty_overlay_swift.log"
    if FileManager.default.fileExists(atPath: path) {
        if let data = line.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        }
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
// Ignore job-control signals so a background overlay doesn't get suspended
// when it writes to the terminal.
signal(SIGTTOU, SIG_IGN)
signal(SIGTTIN, SIG_IGN)
signal(SIGPIPE, SIG_IGN)

enum Mode {
    case dry
    case tty
    case apple
    case terminal
    case selfHost        // RPC backend (default)
    case selfTerminal    // Launch a pi TUI in Terminal.app
}

final class AppleScriptInjector {
    let ttyPath: String
    var windowId: String?
    var lastError: String = ""

    init(ttyPath: String, windowId: String? = nil) {
        self.ttyPath = ttyPath
        self.windowId = windowId
    }

    private func targetWindow() -> String {
        if let id = windowId, !id.isEmpty, id.allSatisfy({ $0.isNumber }) {
            return "first window whose id is \(id)"
        }
        let escaped = ttyPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "first window whose tty is \"\(escaped)\""
    }

    private func run(_ source: String) -> Bool {
        let script = NSAppleScript(source: source)
        var errorDict: NSDictionary? = nil
        _ = script?.executeAndReturnError(&errorDict)
        if let err = errorDict {
            lastError = err["NSAppleScriptErrorBriefString"] as? String
                ?? err.description
            debugLog("apple error: \(lastError)")
            return false
        }
        return true
    }

    func terminalWindowName() -> String? {
        let source = "tell application \"Terminal\" to get name of (\(targetWindow()))"
        let script = NSAppleScript(source: source)
        var errorDict: NSDictionary? = nil
        let result = script?.executeAndReturnError(&errorDict)
        if let err = errorDict {
            debugLog("terminal name error: \(err)")
            return nil
        }
        return result?.stringValue
    }

    func activateWindow() -> Bool {
        let source = """
        tell application "Terminal"
            set frontmost of (\(targetWindow())) to true
        end tell
        """
        return run(source)
    }

    func closeWindow() -> Bool {
        let source = """
        tell application "Terminal"
            close (\(targetWindow()))
        end tell
        """
        return run(source)
    }

    func sendKey(_ keyCode: Int) -> Bool {
        let source = """
        tell application "System Events"
            key code \(keyCode)
        end tell
        """
        return run(source)
    }

    func sendTerminalScript(_ text: String) -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let source = """
        tell application "Terminal"
            do script "\(escaped)" in tab 1 of (\(targetWindow()))
        end tell
        """
        return run(source)
    }

    func sendText(_ text: String) -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let source = """
        tell application "System Events"
            keystroke "\(escaped)"
        end tell
        """
        return run(source)
    }
}

final class TtyInjector {
    let path: String
    private var fd: Int32 = -1
    var lastError: String = ""

    init(path: String) {
        self.path = path
    }

    func openIfNeeded() -> Bool {
        guard fd == -1 else { return true }
        debugLog("open tty path=\(path)")
        fd = open(path, O_RDWR | O_NOCTTY)
        if fd == -1 {
            lastError = "open failed errno=\(errno)"
            return false
        }
        return true
    }

    func closeAll() {
        if fd != -1 {
            close(fd)
            fd = -1
        }
    }

    func inject(_ text: String) -> Bool {
        guard openIfNeeded() else { return false }
        for byte in text.utf8 {
            var b = byte
            let rc = ioctl(fd, TIOCSTI, &b)
            if rc == -1 {
                if errno == EPERM || errno == EACCES {
                    lastError = "TIOCSTI denied: not the controlling TTY"
                } else {
                    lastError = "ioctl failed errno=\(errno)"
                }
                closeAll()
                return false
            }
        }
        return true
    }
}

// ---------------------------------------------------------------------------
// Speech input
// ---------------------------------------------------------------------------

final class SpeechInput {
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isListening = false

    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    func start() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            onError?("Speech recognizer unavailable")
            return
        }

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    let final = result.isFinal
                    DispatchQueue.main.async {
                        self.onTranscript?(text, final)
                    }
                }
                if let error {
                    DispatchQueue.main.async {
                        self.onError?(error.localizedDescription)
                    }
                }
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}

// ---------------------------------------------------------------------------
// Key tape view
// ---------------------------------------------------------------------------

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Content view that turns the outer few points of a borderless window into
/// resize handles. AppKit only gives titled windows native edge-resize
/// behaviour, and this overlay deliberately has no title bar.
final class OverlayContainerView: NSView {
    private enum Edge {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    }

    private let grab: CGFloat = 6

    private func edge(at point: NSPoint) -> Edge? {
        let nearLeft = point.x <= grab
        let nearRight = point.x >= bounds.width - grab
        let nearTop = point.y >= bounds.height - grab
        let nearBottom = point.y <= grab

        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (true, _, _, true): return .bottomLeft
        case (_, true, true, _): return .topRight
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    /// Claim the border band before any subview (tab strip, key tape) sees it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if edge(at: convert(point, from: superview)) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let w = bounds.width
        let h = bounds.height
        guard w > 4 * grab, h > 4 * grab else { return }

        addCursorRect(NSRect(x: 0, y: grab, width: grab, height: h - 2 * grab),
                      cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - grab, y: grab, width: grab, height: h - 2 * grab),
                      cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: grab, y: 0, width: w - 2 * grab, height: grab),
                      cursor: .resizeUpDown)
        addCursorRect(NSRect(x: grab, y: h - grab, width: w - 2 * grab, height: grab),
                      cursor: .resizeUpDown)
        for corner in [
            NSRect(x: 0, y: 0, width: grab, height: grab),
            NSRect(x: w - grab, y: 0, width: grab, height: grab),
            NSRect(x: 0, y: h - grab, width: grab, height: grab),
            NSRect(x: w - grab, y: h - grab, width: grab, height: grab),
        ] {
            addCursorRect(corner, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window,
              let edge = edge(at: convert(event.locationInWindow, from: nil)) else {
            // Background drag: keep the "drag anywhere to move" behaviour.
            if let window, window.isMovableByWindowBackground {
                window.performDrag(with: event)
            } else {
                super.mouseDown(with: event)
            }
            return
        }

        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        let minWidth = max(window.minSize.width, 240)
        let minHeight = max(window.minSize.height, 150)

        let left = edge == .left || edge == .topLeft || edge == .bottomLeft
        let right = edge == .right || edge == .topRight || edge == .bottomRight
        let top = edge == .top || edge == .topLeft || edge == .topRight
        let bottom = edge == .bottom || edge == .bottomLeft || edge == .bottomRight

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }

            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y

            let width = max(startFrame.width + (right ? dx : 0) - (left ? dx : 0), minWidth)
            let height = max(startFrame.height + (top ? dy : 0) - (bottom ? dy : 0), minHeight)

            var x = startFrame.origin.x
            var y = startFrame.origin.y
            if left { x = startFrame.maxX - width }
            if bottom { y = startFrame.maxY - height }

            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }
}

/// Prompt text box. A real `NSTextView` inside a scroll view supplies the native
/// caret, selection, arrow keys, mouse placement, cut/copy/paste and undo; this
/// view only draws the black rounded background, the placeholder, and the
/// agent-status pill in the band along the bottom edge.
final class KeyTapeView: NSView, NSTextViewDelegate {
    enum AgentStatus {
        case idle
        case processing
        case done
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    /// Dark box, light text.
    static let background = NSColor.black
    static let textColor = NSColor.white
    static let borderColor = NSColor(white: 0.35, alpha: 1)
    static let placeholderColor = NSColor(white: 0.55, alpha: 1)
    static let selectionColor = NSColor(white: 0.30, alpha: 1)
    static var paragraphStyle: NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.alignment = .left
        return para
    }

    /// Height of the strip along the bottom edge reserved for the Speak button
    /// and the status pill, so wrapped text never runs underneath them.
    static let bottomBand: CGFloat = 44
    private static let textInset = NSSize(width: 10, height: 8)

    weak var controller: OverlayController? {
        didSet { textView.controller = controller }
    }

    var agentStatus: AgentStatus = .idle

    let scrollView: NSScrollView
    let textView: OverlayTextView

    /// The prompt text, as the text view holds it.
    var text: String { textView.string }

    override var isFlipped: Bool { true }
    /// The inner text view is the first responder; this view is just the frame.
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        let inner = NSRect(x: 0, y: 0, width: max(10, frameRect.width), height: 24)
        textView = OverlayTextView(frame: inner)
        scrollView = NSScrollView(frame: inner)
        super.init(frame: frameRect)
        configureTextView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureTextView() {
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.font = Self.font
        textView.textColor = Self.textColor
        textView.insertionPointColor = Self.textColor
        textView.typingAttributes = [
            .font: Self.font,
            .foregroundColor: Self.textColor,
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: Self.selectionColor,
            .foregroundColor: Self.textColor,
        ]
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.delegate = self

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Dark scrollers to match the box, so the knob is visible on black.
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    /// Area inside the border that holds the text, above the bottom band.
    var textArea: NSRect {
        let inset = Self.textInset
        return NSRect(
            x: inset.width,
            y: inset.height,
            width: max(10, bounds.width - inset.width * 2),
            height: max(10, bounds.height - inset.height - Self.bottomBand)
        )
    }

    override func layout() {
        super.layout()
        let area = textArea
        scrollView.frame = area
        // Track the visible width so wrapping is stable even while the window
        // is still settling.
        textView.textContainer?.containerSize = NSSize(
            width: max(10, area.width - 2),
            height: .greatestFiniteMagnitude
        )

        let clip = scrollView.contentSize
        guard clip.width > 1, clip.height > 1 else { return }
        if abs(textView.frame.width - clip.width) > 0.5 {
            textView.setFrameSize(
                NSSize(width: clip.width, height: max(clip.height, textView.frame.height))
            )
        }
        fitTextView(minHeight: clip.height)
    }

    /// Grows (or shrinks) the text view to the height its text needs, so the
    /// scroll view only scrolls once the visible box is actually full.
    private func fitTextView(minHeight: CGFloat) {
        guard let manager = textView.layoutManager,
              let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height + textView.textContainerInset.height * 2
        let height = max(max(1, minHeight), ceil(used))
        if abs(textView.frame.height - height) > 0.5 {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: height))
        }
    }

    /// Replaces the whole prompt (voice transcripts, tab switches, resets) and
    /// leaves the caret at the end.
    func setText(_ text: String) {
        guard textView.string != text else { return }
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        needsLayout = true
        needsDisplay = true
        fitTextView(minHeight: scrollView.contentSize.height)
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Inserts at the caret, replacing the selection (Cmd+V).
    func insert(_ addition: String) {
        textView.insertText(addition, replacementRange: textView.selectedRange())
        fitTextView(minHeight: scrollView.contentSize.height)
        textView.scrollRangeToVisible(textView.selectedRange())
        needsDisplay = true
    }

    func focusTextView() {
        window?.makeFirstResponder(textView)
    }

    override func mouseDown(with event: NSEvent) {
        focusTextView()
        super.mouseDown(with: event)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        controller?.promptTextChanged(textView.string)
        fitTextView(minHeight: scrollView.contentSize.height)
        needsDisplay = true
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    override func draw(_ dirtyRect: NSRect) {
        // dark textbox: black fill, subtle border
        Self.background.setFill()
        dirtyRect.fill()

        Self.borderColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()

        // The placeholder sits under the (transparent) text view.
        if textView.string.isEmpty {
            let area = textArea
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: Self.placeholderColor,
                .paragraphStyle: Self.paragraphStyle,
            ]
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: area).addClip()
            NSAttributedString(string: "type…", attributes: attrs)
                .draw(
                    with: NSRect(
                        x: area.minX,
                        y: area.minY + 2,
                        width: area.width,
                        height: area.height
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            NSGraphicsContext.restoreGraphicsState()
        }

        drawAgentStatus()
    }

    /// Bottom-right status pill in this view's (flipped) coordinates. When
    /// idle, the "Done" geometry is returned so the Speak button stays put.
    var statusPillRect: NSRect {
        let label = agentStatus == .processing ? "Processing" : "Done"
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let size = (label as NSString).size(withAttributes: [.font: font])
        return NSRect(
            x: bounds.width - size.width - 18,
            y: bounds.height - size.height - 10,
            width: size.width + 12,
            height: size.height + 6
        )
    }

    private func drawAgentStatus() {
        guard agentStatus != .idle else { return }

        let label = agentStatus == .processing ? "Processing" : "Done"
        let color = agentStatus == .processing ? NSColor.systemOrange : NSColor.systemGreen
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let pill = statusPillRect

        NSColor(white: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        label.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attrs)
    }
}

/// The prompt's text view: hands the overlay's window chords to the controller
/// and lets AppKit do everything else (typing, arrows, selection, undo).
final class OverlayTextView: NSTextView {
    weak var controller: OverlayController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        debugLog("keyDown code=\(event.keyCode) chars='\(event.characters ?? "")' mods=\(event.modifierFlags)")
        if controller?.handlePromptKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handlePromptKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

// ---------------------------------------------------------------------------
// Directory history and pi session launching (self mode)
// ---------------------------------------------------------------------------

final class DirectoryStore {
    private let defaults = UserDefaults.standard
    private let lastKey = "piOverlay.lastDirectory"
    private let recentsKey = "piOverlay.recentDirectories"
    private let maxRecents = 10

    func normalize(_ raw: String) -> URL? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url.resolvingSymlinksInPath()
    }

    var lastDirectory: URL? {
        guard let raw = defaults.string(forKey: lastKey) else { return nil }
        return normalize(raw)
    }

    var recents: [URL] {
        let paths = defaults.stringArray(forKey: recentsKey) ?? []
        return paths.compactMap { normalize($0) }
    }

    func addRecent(_ url: URL) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        defaults.set(key, forKey: lastKey)

        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == key }
        paths.insert(key, at: 0)
        if paths.count > maxRecents {
            paths = Array(paths.prefix(maxRecents))
        }
        defaults.set(paths, forKey: recentsKey)
    }

    func resolveInitialDirectory(cliDirectory: String?) -> URL {
        if let cliDirectory, let url = normalize(cliDirectory) { return url }
        if let env = ProcessInfo.processInfo.environment["PI_OVERLAY_DIR"],
           let url = normalize(env) { return url }
        if let url = lastDirectory { return url }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir),
           isDir.boolValue {
            return cwd.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// Legacy single-profile tab list in `~/.config/pi-overlay/tabs.conf`.
///
/// Profiles are now stored in `profiles.conf`; this file is only read once to
/// import the old tab set into a profile named `default`.
///
///     # pi-overlay: open tabs, one directory per line, '*' = active tab
///     * /Users/me/code/project-a
///       /Users/me/code/project-b
///
/// A tab may pin the conversation it is viewing by appending a tab and the
/// session file path.
final class TabStore {
    struct Entry {
        let path: String
        let active: Bool
        let session: String?
    }

    /// Override with PI_OVERLAY_TABS (handy for testing or per-project config).
    let url: URL
    private var lastWritten: String?

    init() {
        if let override = ProcessInfo.processInfo.environment["PI_OVERLAY_TABS"],
           !override.isEmpty {
            url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return
        }
        url = Self.configDirectory().appendingPathComponent("tabs.conf")
    }

    /// `~/.config/pi-overlay` (or `$XDG_CONFIG_HOME/pi-overlay`).
    static func configDirectory() -> URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return configHome.appendingPathComponent("pi-overlay")
    }

    func load() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var entries: [Entry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            var active = false
            if line.hasPrefix("*") {
                active = true
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            // Optional tab-separated session file pinned to this tab.
            var session: String?
            if let separator = line.firstIndex(of: "\t") {
                let suffix = line[line.index(after: separator)...]
                    .trimmingCharacters(in: .whitespaces)
                session = suffix.isEmpty
                    ? nil
                    : (suffix as NSString).expandingTildeInPath
                line = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            }

            guard !line.isEmpty else { continue }
            entries.append(Entry(
                path: (line as NSString).expandingTildeInPath,
                active: active,
                session: session
            ))
        }

        // Seed the change detector with what we would write ourselves, so an
        // untouched file (including its comments) is left alone.
        lastWritten = render(entries)
        return entries
    }

    @discardableResult
    func save(_ entries: [Entry]) -> Bool {
        let text = render(entries)
        guard text != lastWritten else { return true }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Write through symlinks so a dotfiles-managed tabs.conf keeps working.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink

        do {
            if isSymlink {
                try text.write(to: url, atomically: false, encoding: .utf8)
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            lastWritten = text
            return true
        } catch {
            debugLog("tabs.conf write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func render(_ entries: [Entry]) -> String {
        let body = entries
            .map { entry -> String in
                let suffix = entry.session.map { "\t\($0)" } ?? ""
                return (entry.active ? "* " : "  ") + entry.path + suffix
            }
            .joined(separator: "\n")
        return """
        # pi-overlay: open tabs, one directory per line, '*' = active tab
        # An optional tab-separated session file pins the conversation to resume.
        # Written by the overlay. Edit freely; it is read on next launch.
        \(body.isEmpty ? "" : body + "\n")
        """
    }
}

struct PiSession {
    let directory: URL
    var ttyPath: String?
    let terminalWindowId: String?
}

/// One tab inside a profile: a project directory plus the conversation pinned
/// to it, and whether it was the active tab when the profile was saved.
struct ProfileTab {
    let path: String
    let active: Bool
    let session: String?
}

/// A Chrome-style profile: a named, ordered set of tabs.
struct OverlayProfile {
    var name: String
    var tabs: [ProfileTab]
}

/// Stores named profiles in `~/.config/pi-overlay/profiles.conf`, next to the
/// legacy `tabs.conf`:
///
///     # pi-overlay: profiles. Each [name] section lists its tabs.
///     # '*' marks the active tab; 'active' names the profile opened on launch.
///     active = daily
///
///     [daily]
///     * /Users/me/code/project-a	/Users/me/.pi/.../session.jsonl
///       /Users/me/code/project-b
final class ProfileStore {
    static let defaultName = "default"

    struct Loaded {
        let active: String
        let profiles: [OverlayProfile]
    }

    let url: URL
    private var lastWritten: String?

    init() {
        if let override = ProcessInfo.processInfo.environment["PI_OVERLAY_PROFILES"],
           !override.isEmpty {
            url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return
        }
        url = TabStore.configDirectory().appendingPathComponent("profiles.conf")
    }

    func load() -> Loaded {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Loaded(active: Self.defaultName, profiles: [])
        }

        var active = Self.defaultName
        var profiles: [OverlayProfile] = []
        var current: Int?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 {
                let name = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                if let index = profiles.firstIndex(where: { $0.name == name }) {
                    current = index
                } else {
                    profiles.append(OverlayProfile(name: name, tabs: []))
                    current = profiles.count - 1
                }
                continue
            }

            if let equals = line.firstIndex(of: ":"),
               String(line[..<equals]).trimmingCharacters(in: .whitespaces).lowercased() == "active" {
                let value = String(line[line.index(after: equals)...])
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { active = value }
                continue
            }
            if let equals = line.firstIndex(of: "="),
               String(line[..<equals]).trimmingCharacters(in: .whitespaces).lowercased() == "active" {
                let value = String(line[line.index(after: equals)...])
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { active = value }
                continue
            }

            var tabLine = line
            var tabActive = false
            if tabLine.hasPrefix("*") {
                tabActive = true
                tabLine = String(tabLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            var session: String?
            if let separator = tabLine.firstIndex(of: "\t") {
                let suffix = String(tabLine[tabLine.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                session = suffix.isEmpty
                    ? nil
                    : (suffix as NSString).expandingTildeInPath
                tabLine = String(tabLine[..<separator]).trimmingCharacters(in: .whitespaces)
            }
            guard !tabLine.isEmpty else { continue }

            if current == nil {
                profiles.append(OverlayProfile(name: Self.defaultName, tabs: []))
                current = profiles.count - 1
            }
            guard let index = current else { continue }
            profiles[index].tabs.append(ProfileTab(
                path: (tabLine as NSString).expandingTildeInPath,
                active: tabActive,
                session: session
            ))
        }

        guard !profiles.isEmpty else {
            return Loaded(active: Self.defaultName, profiles: [])
        }
        if !profiles.contains(where: { $0.name == active }) {
            active = profiles[0].name
        }
        return Loaded(active: active, profiles: profiles)
    }

    @discardableResult
    func save(active: String, profiles: [OverlayProfile]) -> Bool {
        let text = render(active: active, profiles: profiles)
        guard text != lastWritten else { return true }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Write through symlinks so a dotfiles-managed file keeps working.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink

        do {
            if isSymlink {
                try text.write(to: url, atomically: false, encoding: .utf8)
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            lastWritten = text
            return true
        } catch {
            debugLog("profiles.conf write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func render(active: String, profiles: [OverlayProfile]) -> String {
        var lines = [
            "# pi-overlay: profiles. Each [name] section lists its tabs.",
            "# '*' marks the active tab; 'active' names the profile opened on launch.",
            "active = \(active)",
            "",
        ]
        for profile in profiles {
            lines.append("[\(profile.name)]")
            for tab in profile.tabs {
                let marker = tab.active ? "* " : "  "
                var line = marker + tab.path
                if let session = tab.session { line += "\t" + session }
                lines.append(line)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// One saved pi conversation on disk.
struct PiSessionInfo {
    let path: String
    /// Explicit name from `/name`, when one was set.
    let name: String?
    /// First user message, used as the list label when there is no name.
    let preview: String?
    let modified: Date
}

/// Reads pi's on-disk session list for a working directory.
///
/// pi stores sessions in `<agentDir>/sessions/--<encoded-cwd>--/*.jsonl` where
/// the encoding is the absolute cwd with a single leading slash removed and
/// every `/`, `\` and `:` replaced by `-` (see pi's session-manager).
enum PiSessionStore {
    static func directory(for cwd: URL) -> URL {
        let environment = ProcessInfo.processInfo.environment

        if let custom = environment["PI_CODING_AGENT_SESSION_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }

        let agentDirectory: URL
        if let custom = environment["PI_CODING_AGENT_DIR"], !custom.isEmpty {
            agentDirectory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            agentDirectory = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".pi")
                .appendingPathComponent("agent")
        }

        let resolved = cwd.standardizedFileURL.resolvingSymlinksInPath().path
        var stripped = resolved
        if stripped.hasPrefix("/") { stripped.removeFirst() }
        let encoded = "--"
            + stripped.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            + "--"

        return agentDirectory
            .appendingPathComponent("sessions")
            .appendingPathComponent(encoded)
    }

    /// Most recently active sessions first, capped at `limit`.
    static func list(for cwd: URL, limit: Int = 40) -> [PiSessionInfo] {
        let directory = directory(for: cwd)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let files = entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return (url, values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)

        return files.compactMap { url, modified in
            guard let summary = summarize(url.path) else { return nil }
            return PiSessionInfo(
                path: url.path,
                name: summary.name,
                preview: summary.preview,
                modified: modified
            )
        }
    }

    /// Reads the newest `session_info` name from the tail and the first user
    /// message from the head, without loading whole (possibly multi-MB) files.
    private static func summarize(_ path: String) -> (name: String?, preview: String?)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        // Name: latest session_info in the last 96 KB.
        let tailLength = min(size, 96 * 1024)
        try? handle.seek(toOffset: size - tailLength)
        var name: String?
        if let tail = try? handle.readToEnd() {
            for line in tail.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "session_info",
                      let value = object["name"] as? String else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                name = trimmed.isEmpty ? nil : trimmed
            }
        }

        // Preview: first user message in the first 64 KB.
        var preview: String?
        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: Int(min(size, UInt64(64 * 1024)))) {
            for line in head.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "message",
                      let message = object["message"] as? [String: Any],
                      message["role"] as? String == "user",
                      let text = messageText(message) else { continue }
                preview = text
                break
            }
        }

        return (name, preview.map(condense))
    }

    private static func messageText(_ message: [String: Any]) -> String? {
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let joined = blocks
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// Single line, short enough for a chip.
    private static func condense(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 48 { return oneLine }
        return String(oneLine.prefix(47)) + "…"
    }
}

enum PiLaunchError: LocalizedError {
    case piNotFound
    case appleScript(String)
    case terminalLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .piNotFound:
            return "Could not find the pi executable. Set PI_OVERLAY_PI or install pi on PATH."
        case .appleScript(let message):
            return "Terminal automation failed: \(message)"
        case .terminalLaunchFailed(let message):
            return "Could not open Terminal: \(message)"
        }
    }
}

final class PiLauncher {
    private static var cachedPi: String?

    static func resolvePiBinary() -> String? {
        if let cachedPi, FileManager.default.isExecutableFile(atPath: cachedPi) {
            return cachedPi
        }

        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["PI_OVERLAY_PI"], !env.isEmpty {
            let expanded = (env as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                let absolute = URL(fileURLWithPath: expanded).standardizedFileURL.path
                cachedPi = absolute
                return absolute
            }
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/pi"),
        ])

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            cachedPi = candidate
            return candidate
        }

        // GUI apps inherit a minimal PATH, so ask the user's login shell.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v pi"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty,
               FileManager.default.isExecutableFile(atPath: output) {
                cachedPi = output
                return output
            }
        } catch {
            debugLog("pi lookup failed: \(error)")
        }
        return nil
    }

    func launch(in directory: URL, completion: @escaping (Result<PiSession, Error>) -> Void) {
        guard let pi = Self.resolvePiBinary() else {
            completion(.failure(PiLaunchError.piNotFound))
            return
        }

        debugLog("self launch dir=\(directory.path) pi=\(pi)")
        let command = "cd \(Self.shellQuote(directory.path)) && exec \(Self.shellQuote(pi))"
        let source = """
        tell application "Terminal"
            activate
            set newTab to do script "\(Self.appleScriptQuote(command))"
            set wid to (id of front window) as string
            set tPath to tty of newTab
            return wid & "|" & tPath
        end tell
        """

        var errorDict: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorDict)
        if let errorDict {
            let message = (errorDict["NSAppleScriptErrorBriefString"] as? String)
                ?? errorDict.description
            debugLog("self launch applescript error: \(message)")
            launchViaCommandFile(in: directory, pi: pi, completion: completion)
            return
        }

        let raw = result?.stringValue ?? ""
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let windowId = parts.first.map(String.init) ?? ""
        var tty = parts.count > 1 ? String(parts[1]) : ""
        if tty.isEmpty {
            tty = Self.frontWindowTTY(attempts: 5)
        }

        completion(.success(PiSession(
            directory: directory,
            ttyPath: tty.isEmpty ? nil : tty,
            terminalWindowId: windowId.isEmpty ? nil : windowId
        )))
    }

    func close(_ session: PiSession) {
        let injector = AppleScriptInjector(
            ttyPath: session.ttyPath ?? "",
            windowId: session.terminalWindowId
        )
        if !injector.closeWindow() {
            debugLog("self close failed: \(injector.lastError)")
        }
    }

    // Fallback for when Terminal automation is denied: a temporary .command
    // file reports the TTY it was opened on, then execs pi in the directory.
    private func launchViaCommandFile(
        in directory: URL,
        pi: String,
        completion: @escaping (Result<PiSession, Error>) -> Void
    ) {
        do {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pi-overlay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            let ttyFile = base.appendingPathComponent("tty")
            let scriptFile = base.appendingPathComponent("launch.command")
            let body = """
            #!/bin/sh
            tty > \(Self.shellQuote(ttyFile.path))
            cd \(Self.shellQuote(directory.path)) || exit 1
            exec \(Self.shellQuote(pi))
            """
            try body.write(to: scriptFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptFile.path
            )

            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", "Terminal", scriptFile.path]
            try open.run()
            open.waitUntilExit()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                var tty: String?
                for _ in 0..<20 {
                    if let value = try? String(contentsOf: ttyFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !value.isEmpty {
                        tty = value
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                let session = PiSession(
                    directory: directory,
                    ttyPath: tty,
                    terminalWindowId: nil
                )
                try? FileManager.default.removeItem(at: base)
                DispatchQueue.main.async {
                    completion(.success(session))
                }
            }
        } catch {
            completion(.failure(PiLaunchError.terminalLaunchFailed(error.localizedDescription)))
        }
    }

    private static func frontWindowTTY(attempts: Int) -> String {
        let source = "tell application \"Terminal\" to get tty of selected tab of front window"
        for _ in 0..<attempts {
            var errorDict: NSDictionary?
            if let result = NSAppleScript(source: source)?.executeAndReturnError(&errorDict),
               errorDict == nil {
                let tty = result.stringValue ?? ""
                if !tty.isEmpty { return tty }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return ""
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

// ---------------------------------------------------------------------------
// Login-shell environment (GUI-launched apps get a minimal PATH)
// ---------------------------------------------------------------------------

enum PiEnvironment {
    private static var cached: [String: String]?

    static func loginShell() -> [String: String] {
        if let cached { return cached }

        var environment = ProcessInfo.processInfo.environment
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "env -0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        if (try? process.run()) != nil {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            for entry in data.split(separator: 0) {
                guard let text = String(data: Data(entry), encoding: .utf8),
                      let equals = text.firstIndex(of: "=") else { continue }
                let key = String(text[..<equals])
                let value = String(text[text.index(after: equals)...])
                if !key.isEmpty {
                    environment[key] = value
                }
            }
        }

        cached = environment
        return environment
    }
}

// ---------------------------------------------------------------------------
// RPC session (self mode)
// ---------------------------------------------------------------------------

final class RpcSession {
    let directory: URL
    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let parseQueue: DispatchQueue
    private let stderrLock = NSLock()
    private var stderrBuffer = ""
    private var readBuffer = Data()
    private var nextRequestID = 0
    private var waitingForFirstEvent = false

    private(set) var isStreaming = false
    private(set) var isRunning = false

    var processIdentifier: Int32 { process.processIdentifier }

    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?

    static func launch(in directory: URL, sessionFile: String? = nil) throws -> RpcSession {
        guard let pi = PiLauncher.resolvePiBinary() else {
            throw PiLaunchError.piNotFound
        }
        return try RpcSession(directory: directory, piPath: pi, sessionFile: sessionFile)
    }

    private init(directory: URL, piPath: String, sessionFile: String?) throws {
        self.directory = directory
        self.parseQueue = DispatchQueue(label: "pi-overlay.rpc.\(UUID().uuidString)")

        process = Process()
        process.executableURL = URL(fileURLWithPath: piPath)
        var arguments = ["--mode", "rpc"]
        if let sessionFile {
            arguments.append(contentsOf: ["--session", sessionFile])
        }
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = PiEnvironment.loginShell()

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.isStreaming = false
                self.waitingForFirstEvent = false
                self.onExit?(status)
            }
        }

        try process.run()
        isRunning = true

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.parseQueue.async { [weak self] in
                self?.consume(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            debugLog("rpc stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            self?.appendStderr(text)
        }

        debugLog("rpc launched dir=\(directory.path) pi=\(piPath)")
    }

    @discardableResult
    func prompt(_ message: String) -> Bool {
        var record: [String: Any] = [
            "id": nextID(),
            "type": "prompt",
            "message": message,
        ]
        if isStreaming || waitingForFirstEvent {
            record["streamingBehavior"] = "followUp"
        }
        waitingForFirstEvent = true
        if !send(record) {
            waitingForFirstEvent = false
            return false
        }
        return true
    }

    func abort() {
        _ = send(["id": nextID(), "type": "abort"])
    }

    func requestState() {
        _ = send(["type": "get_state"])
    }

    func requestLastAssistantText() {
        _ = send(["type": "get_last_assistant_text"])
    }

    /// Full entry history; used to build the previous prompt/answer list for
    /// the active branch (including turns before compaction).
    func requestEntries() {
        _ = send(["type": "get_entries"])
    }

    func switchToSession(path: String) {
        _ = send(["id": nextID(), "type": "switch_session", "sessionPath": path])
    }

    /// Starts a fresh conversation in the same pi process (`/new`).
    @discardableResult
    func newSession() -> Bool {
        send(["id": nextID(), "type": "new_session"])
    }

    func requestModels() {
        _ = send(["type": "get_available_models"])
    }

    func setModel(provider: String, modelId: String) {
        _ = send([
            "type": "set_model",
            "provider": provider,
            "modelId": modelId,
        ])
    }

    @discardableResult
    func send(_ record: [String: Any]) -> Bool {
        guard isRunning,
              let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { return false }
        line += "\n"
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            return true
        } catch {
            debugLog("rpc write failed: \(error)")
            return false
        }
    }

    func respondExtensionUI(id: String, value: String) {
        _ = send(["type": "extension_ui_response", "id": id, "value": value])
    }

    func respondExtensionUI(id: String, confirmed: Bool) {
        _ = send(["type": "extension_ui_response", "id": id, "confirmed": confirmed])
    }

    func cancelExtensionUI(id: String) {
        _ = send(["type": "extension_ui_response", "id": id, "cancelled": true])
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func appendStderr(_ text: String) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        stderrBuffer += text
        if stderrBuffer.count > 8000 {
            stderrBuffer = String(stderrBuffer.suffix(8000))
        }
    }

    func recentStderr(maxLength: Int = 2000) -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return String(stderrBuffer.suffix(maxLength))
    }

    private func nextID() -> String {
        nextRequestID += 1
        return "overlay-\(nextRequestID)"
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            var line = readBuffer[..<newline]
            readBuffer.removeSubrange(0...newline)
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = object as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.processRecord(record)
            }
        }
    }

    private func processRecord(_ record: [String: Any]) {
        switch record["type"] as? String {
        case "agent_start":
            isStreaming = true
            waitingForFirstEvent = false
        case "agent_settled":
            isStreaming = false
            waitingForFirstEvent = false
        case "response":
            if record["command"] as? String == "prompt" {
                let data = record["data"] as? [String: Any]
                let disposition = data?["disposition"] as? String
                if record["success"] as? Bool == false || disposition == "handled" {
                    waitingForFirstEvent = false
                }
            }
        default:
            break
        }
        onEvent?(record)
    }

    static func messageText(from message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }
}

// ---------------------------------------------------------------------------
// Controller / UI
// ---------------------------------------------------------------------------

/// One user prompt and the assistant text that followed it.
struct SessionQuery {
    let id: String
    let prompt: String
    var answer: String
}

final class ModelRef: NSObject {
    let provider: String
    let modelId: String
    let name: String

    init(provider: String, modelId: String, name: String) {
        self.provider = provider
        self.modelId = modelId
        self.name = name
    }
}

private final class StatusTabRef: NSObject {
    let profile: String
    let tabID: UUID

    init(profile: String, tabID: UUID) {
        self.profile = profile
        self.tabID = tabID
    }
}

final class RpcTab {
    let id = UUID()
    var directory: URL?
    var session: RpcSession?
    var isLaunching = false
    var status: KeyTapeView.AgentStatus = .idle
    var exitStatus: Int32?
    var currentModel: [String: Any]?
    var models: [[String: Any]]?
    var sessionFile: String?
    var sessionName: String?
    var assistantText = ""
    var streamingText = ""
    var latestAnswerText = ""
    var responseText = ""
    var responseExpanded = false
    var responseUserCollapsed = false
    var queries: [SessionQuery] = []
    var selectedQueryID: String?
    var rawText = ""
    var tape: [String] = []

    let webView: WKWebView

    init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }
}

final class OverlayController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    let window: OverlayWindow
    let keyTape: KeyTapeView
    let statusLabel: NSTextField
    let targetLabel: NSTextField
    let terminalTitleLabel: NSTextField
    let directoryPopup: NSPopUpButton
    let modelPopup: NSPopUpButton
    let pidLabel: NSTextField
    let tabBar: NSView
    let profilePopup: NSPopUpButton
    let tabScrollView: NSScrollView
    let tabContentView: NSView
    let newTabButton: NSButton
    let voiceButton: NSButton
    let closeButton: NSButton
    let minimizeButton: NSButton
    let maximizeButton: NSButton
    let sessionPopup: NSPopUpButton
    let newSessionButton: NSButton
    let sessionLabel: NSTextField
    let responseButton: NSButton
    let responseWebView: WKWebView
    let queryPopup: NSPopUpButton

    private var responseExpanded = false
    private var responseUserCollapsed = false
    private var responseText = ""
    private var sessionQueries: [SessionQuery] = []
    private var selectedQueryID: String?
    /// Latest assistant text in modes without per-tab state (tty/extension).
    private var latestResponseText = ""

    private let speech = SpeechInput()
    private var voiceBase = ""
    private var voicePartial = ""

    let mode: Mode
    let directoryStore: DirectoryStore
    private let cliDirectory: String?
    private let tabStore = TabStore()
    private let profileStore = ProfileStore()
    private var profiles: [OverlayProfile] = []
    private var activeProfileName = ProfileStore.defaultName

    /// Entries whose directory is currently missing (unmounted volume, deleted
    /// project). Kept so the next write does not lose them.
    private var missingTabPaths: [String] = []
    let launcher = PiLauncher()
    private(set) var activeDirectory: URL
    private var terminalSessions: [String: PiSession] = [:]
    private var rpcTabs: [RpcTab] = []
    private var activeRpcTabID: UUID?
    private var activeRpcTab: RpcTab? { rpcTabs.first { $0.id == activeRpcTabID } }

    /// Tabs of profiles that are not currently visible. Keeping them (and their
    /// RPC children) alive lets a running turn finish after a profile switch.
    private struct ProfileRuntime {
        let tabs: [RpcTab]
        let activeTabID: UUID?
        let missingPaths: [String]
    }
    private var profileRuntime: [String: ProfileRuntime] = [:]
    private var pendingSessions: Set<String> = []
    private var dialogQueue: [(tabID: UUID, request: [String: Any])] = []
    private var dialogVisible = false

    private var isSelfMode: Bool { mode == .selfHost || mode == .selfTerminal }

    private func hasSession(for key: String) -> Bool {
        if mode == .selfHost {
            if rpcTabs.contains(where: { $0.directory?.path == key && $0.session != nil }) {
                return true
            }
            return profileRuntime.values.contains { runtime in
                runtime.tabs.contains { $0.directory?.path == key && $0.session != nil }
            }
        }
        return terminalSessions[key] != nil
    }

    /// Finds a tab in the visible profile or in any parked (background) one.
    private func rpcTab(withID id: UUID) -> RpcTab? {
        if let tab = rpcTabs.first(where: { $0.id == id }) { return tab }
        for runtime in profileRuntime.values {
            if let tab = runtime.tabs.first(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    var ttyPath: String?
    var injector: TtyInjector?
    var appleInjector: AppleScriptInjector?
    var terminalInjector: AppleScriptInjector?

    private var isMinimized = false
    private var isMaximizedWindow = false
    private var maximizeRestoreLevel: NSWindow.Level = .floating
    private var maximizeRestoreBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary]
    private var maximizeWasMovable = true
    private var expandedHeight: CGFloat = 0
    private var sessionInfos: [PiSessionInfo] = []
    private var sessionLoadToken = 0
    private var statusItem: NSStatusItem?

    /// Height of the window when collapsed. RPC mode keeps only the tab strip;
    /// the other modes keep their single header row, which carries the button.
    private var collapsedHeight: CGFloat { mode == .selfHost ? 32 : 44 }

    private var baseMinSize: NSSize {
        NSSize(width: 720, height: mode == .selfHost ? 200 : 170)
    }

    /// Window height the overlay opens at, and returns to when leaving
    /// maximize. A saved frame always wins; this is the default for a fresh
    /// launch. Clamped to the screen's visible height.
    private static let defaultWindowHeight: CGFloat = 695

    /// Compact window used when leaving maximize: wide enough for the textbox
    /// and the answer panel, anchored to the bottom of the visible screen.
    private var defaultOverlayFrame: NSRect {
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        let width = min(900, max(baseMinSize.width, visible.width - 40))
        let height = min(
            Self.defaultWindowHeight,
            max(baseMinSize.height, visible.height - 40)
        )
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + 12,
            width: width,
            height: height
        )
    }
    var tape: [String] = []
    /// The pending prompt. Mirrors the text box: assigning it replaces the box
    /// contents (voice transcripts, tab switches, clearing after a send).
    var rawText: String = "" {
        didSet {
            if rawText != oldValue { keyTape.setText(rawText) }
        }
    }
    var sentBytes = 0
    var ttyFD: Int32 = -1

    init(mode: Mode, ttyPath: String?, directory: String?) {
        let store = DirectoryStore()
        let initialDirectory = store.resolveInitialDirectory(cliDirectory: directory)
        let selfMode = (mode == .selfHost || mode == .selfTerminal)

        self.mode = mode
        self.directoryStore = store
        self.cliDirectory = directory
        self.activeDirectory = initialDirectory
        self.ttyPath = ttyPath
        self.injector = ttyPath.map { TtyInjector(path: $0) }
        self.appleInjector = ttyPath.map { AppleScriptInjector(ttyPath: $0) }
        self.terminalInjector = ttyPath.map { AppleScriptInjector(ttyPath: $0) }

        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: min(900, max(720, visible.width - 40)),
            height: min(
                Self.defaultWindowHeight,
                max(mode == .selfHost ? 200 : 170, visible.height - 40)
            )
        )
        let initialTabExtra: CGFloat = mode == .selfHost ? 30 : 0
        let origin = NSPoint(
            x: max(20, visible.midX - size.width / 2),
            y: visible.minY + 12
        )

        window = OverlayWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: mode == .selfHost ? 200 : 170)
        window.title = selfMode
            ? "pi · \(initialDirectory.lastPathComponent)"
            : "TTY Overlay · \(ttyPath ?? "dry")"

        // Remember the size/position the user drags out.
        window.setFrameAutosaveName("PiOverlayWindow")
        debugLog("window frame=\(NSStringFromRect(window.frame)) screen=\(NSStringFromRect((window.screen ?? NSScreen.main)?.visibleFrame ?? .zero))")
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            var restored = window.frame
            restored.size.width = max(restored.width, window.minSize.width)
            restored.size.height = max(restored.height, window.minSize.height)
            window.setFrame(restored, display: false)
        }

        // If a previous run quit while the window was maximized, start from the
        // compact bottom-anchored frame instead of a screen-sized overlay.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if window.frame.width >= visible.width - 1,
               window.frame.height >= visible.height - 1 {
                let width = min(900, max(window.minSize.width, visible.width - 40))
                let height = min(
                    Self.defaultWindowHeight,
                    max(window.minSize.height, visible.height - 40)
                )
                window.setFrame(
                    NSRect(
                        x: visible.midX - width / 2,
                        y: visible.minY + 12,
                        width: width,
                        height: height
                    ),
                    display: false
                )
            }
        }

        // container
        let container = OverlayContainerView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.45).cgColor
        container.layer?.borderWidth = 1.4
        window.contentView = container

        // status label
        statusLabel = NSTextField(labelWithString: "READY")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .systemGreen
        statusLabel.frame = NSRect(x: 16, y: size.height - initialTabExtra - 26, width: 250, height: 20)
        container.addSubview(statusLabel)

        targetLabel = NSTextField(labelWithString: ttyPath.map { "TTY \($0)" }
            ?? (selfMode ? "STARTING PI…" : "DRY RUN"))
        targetLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        targetLabel.textColor = NSColor.systemGray
        targetLabel.frame = NSRect(x: 138, y: size.height - initialTabExtra - 25, width: 180, height: 18)
        container.addSubview(targetLabel)

        let termTitle = selfMode
            ? (initialDirectory.path as NSString).abbreviatingWithTildeInPath
            : (terminalInjector?.terminalWindowName() ?? "")
        terminalTitleLabel = NSTextField(labelWithString: termTitle)
        terminalTitleLabel.font = NSFont.systemFont(ofSize: 9)
        terminalTitleLabel.textColor = NSColor.systemGray
        terminalTitleLabel.lineBreakMode = .byTruncatingTail
        terminalTitleLabel.frame = NSRect(x: 326, y: size.height - initialTabExtra - 24, width: 240, height: 16)
        container.addSubview(terminalTitleLabel)

        // Directory dropdown (self mode only)
        directoryPopup = NSPopUpButton(
            frame: NSRect(x: 138, y: size.height - initialTabExtra - 28, width: 300, height: 24),
            pullsDown: true
        )
        directoryPopup.bezelStyle = .rounded
        directoryPopup.controlSize = .regular
        directoryPopup.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        directoryPopup.title = "📁 \(initialDirectory.lastPathComponent)"
        directoryPopup.toolTip = initialDirectory.path
        directoryPopup.isHidden = !selfMode
        container.addSubview(directoryPopup)

        // pi RPC child PID (self/RPC mode only)
        pidLabel = NSTextField(labelWithString: "")
        pidLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        pidLabel.textColor = NSColor.secondaryLabelColor
        pidLabel.alignment = .right
        pidLabel.lineBreakMode = .byTruncatingHead
        pidLabel.isSelectable = true
        pidLabel.isHidden = mode != .selfHost
        container.addSubview(pidLabel)

        // Model dropdown (RPC self mode only)
        modelPopup = NSPopUpButton(
            frame: NSRect(x: 446, y: size.height - initialTabExtra - 28, width: 184, height: 24),
            pullsDown: false
        )
        modelPopup.bezelStyle = .rounded
        modelPopup.controlSize = .regular
        modelPopup.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        modelPopup.addItem(withTitle: "Model…")
        modelPopup.isEnabled = false
        modelPopup.isHidden = mode != .selfHost
        modelPopup.toolTip = "Model for this pi RPC session"
        container.addSubview(modelPopup)

        // Saved sessions for this directory (RPC self mode only)
        sessionLabel = NSTextField(labelWithString: "Sessions")
        sessionLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        sessionLabel.textColor = NSColor.tertiaryLabelColor
        sessionLabel.alignment = .right
        sessionLabel.isHidden = mode != .selfHost
        container.addSubview(sessionLabel)

        sessionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sessionPopup.bezelStyle = .rounded
        sessionPopup.controlSize = .regular
        sessionPopup.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        sessionPopup.addItem(withTitle: "Sessions")
        sessionPopup.isEnabled = false
        sessionPopup.toolTip = "Saved pi sessions for this folder"
        sessionPopup.isHidden = mode != .selfHost
        container.addSubview(sessionPopup)

        // Start a fresh session (same as pi's /new) next to the sessions list.
        newSessionButton = NSButton(title: "＋", target: nil, action: nil)
        newSessionButton.isBordered = false
        newSessionButton.wantsLayer = true
        newSessionButton.layer?.cornerRadius = 5
        newSessionButton.layer?.borderWidth = 0.5
        newSessionButton.layer?.borderColor = NSColor(white: 0.68, alpha: 0.95).cgColor
        newSessionButton.layer?.backgroundColor = NSColor.white.cgColor
        newSessionButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        newSessionButton.toolTip = "New session (like /new)"
        newSessionButton.isHidden = mode != .selfHost
        newSessionButton.isEnabled = false
        container.addSubview(newSessionButton)

        // Tab strip (RPC self mode only)
        tabBar = NSView(frame: .zero)
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor(white: 0.91, alpha: 1).cgColor
        tabBar.isHidden = mode != .selfHost
        container.addSubview(tabBar)

        // Profile switcher: profiles are the parent of tabs and appear first in
        // the tab strip. The menu is rebuilt whenever the profile list changes.
        profilePopup = NSPopUpButton(
            frame: NSRect(x: 4, y: 1, width: 140, height: 24),
            pullsDown: true
        )
        profilePopup.bezelStyle = .rounded
        profilePopup.controlSize = .regular
        profilePopup.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        profilePopup.title = "👤 \(ProfileStore.defaultName)"
        profilePopup.toolTip = "Profile — its tabs are shown to the right"
        profilePopup.isHidden = mode != .selfHost
        tabBar.addSubview(profilePopup)

        tabScrollView = NSScrollView(frame: .zero)
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.hasVerticalScroller = false
        tabScrollView.drawsBackground = false
        tabScrollView.borderType = .noBorder
        tabScrollView.autohidesScrollers = true
        tabBar.addSubview(tabScrollView)

        tabContentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 24))
        tabScrollView.documentView = tabContentView

        newTabButton = NSButton(title: "＋", target: nil, action: nil)
        newTabButton.isBordered = false
        newTabButton.wantsLayer = true
        newTabButton.layer?.cornerRadius = 6
        newTabButton.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.toolTip = "New tab (Ctrl+T)"
        newTabButton.isHidden = mode != .selfHost
        tabBar.addSubview(newTabButton)

        // Speak button (voice input): lives inside the textbox, bottom right,
        // immediately before the Processing/Done pill.
        voiceButton = NSButton(title: "", target: nil, action: nil)
        voiceButton.isBordered = false
        voiceButton.wantsLayer = true
        voiceButton.layer?.cornerRadius = 5
        voiceButton.layer?.borderWidth = 0.5
        voiceButton.layer?.borderColor = NSColor(white: 0.35, alpha: 0.95).cgColor
        voiceButton.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        voiceButton.imagePosition = .imageOnly
        voiceButton.imageScaling = .scaleProportionallyDown
        voiceButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .semibold
        )
        voiceButton.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
        voiceButton.toolTip = "Speak (Option+V)"

        // close application button, to the right of the collapse button
        closeButton = NSButton(title: "×", target: nil, action: nil)
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 6
        closeButton.layer?.borderWidth = 0.5
        closeButton.layer?.borderColor = NSColor(white: 0.68, alpha: 0.95).cgColor
        closeButton.layer?.backgroundColor = NSColor.white.cgColor
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        closeButton.frame = NSRect(x: size.width - 36, y: size.height - initialTabExtra - 28, width: 28, height: 24)
        container.addSubview(closeButton)

        // minimize/restore: collapses the window down to the tab strip
        minimizeButton = NSButton(title: "", target: nil, action: nil)
        minimizeButton.isBordered = false
        minimizeButton.wantsLayer = true
        minimizeButton.layer?.cornerRadius = 6
        minimizeButton.layer?.borderWidth = 0.5
        minimizeButton.layer?.borderColor = NSColor(white: 0.68, alpha: 0.95).cgColor
        minimizeButton.layer?.backgroundColor = NSColor.white.cgColor
        minimizeButton.imagePosition = .imageOnly
        minimizeButton.imageScaling = .scaleProportionallyDown
        minimizeButton.contentTintColor = .labelColor
        minimizeButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .bold
        )
        minimizeButton.toolTip = "Minimize to the tab strip (Cmd+M)"
        container.addSubview(minimizeButton)

        // fullscreen: leaves overlay mode and fills the screen like a normal app
        maximizeButton = NSButton(title: "", target: nil, action: nil)
        maximizeButton.isBordered = false
        maximizeButton.wantsLayer = true
        maximizeButton.layer?.cornerRadius = 6
        maximizeButton.layer?.borderWidth = 0.5
        maximizeButton.layer?.borderColor = NSColor(white: 0.68, alpha: 0.95).cgColor
        maximizeButton.layer?.backgroundColor = NSColor.white.cgColor
        maximizeButton.imagePosition = .imageOnly
        maximizeButton.imageScaling = .scaleProportionallyDown
        maximizeButton.contentTintColor = .labelColor
        maximizeButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .semibold
        )
        maximizeButton.toolTip = "Maximize — fills the screen, keeps the menu bar"
        container.addSubview(maximizeButton)

        // key tape
        keyTape = KeyTapeView(frame: NSRect(x: 10, y: 10, width: size.width - 20, height: 120))
        keyTape.wantsLayer = true
        keyTape.layer?.cornerRadius = 8
        keyTape.addSubview(voiceButton)
        container.addSubview(keyTape)

        // Collapsible final-response panel under the key tape.
        responseButton = NSButton(title: "Response ▸", target: nil, action: nil)
        responseButton.isBordered = false
        responseButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        responseButton.contentTintColor = NSColor.secondaryLabelColor
        responseButton.alignment = .left
        responseButton.isHidden = true
        container.addSubview(responseButton)

        // Prompt history: pick a previous question to see the answer that
        // followed it. Sits between the textbox and the response panel.
        queryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        queryPopup.bezelStyle = .rounded
        queryPopup.controlSize = .regular
        queryPopup.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        queryPopup.addItem(withTitle: "Latest answer")
        queryPopup.isHidden = true
        queryPopup.isEnabled = false
        queryPopup.toolTip = "Show the answer for a previous prompt in this session"
        container.addSubview(queryPopup)

        responseWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        responseWebView.isHidden = true
        container.addSubview(responseWebView)

        super.init()

        window.delegate = self
        keyTape.controller = self
        // native caret; no manual blink timer needed.
        voiceButton.target = self
        voiceButton.action = #selector(toggleVoice)
        voiceButton.sendAction(on: [.leftMouseDown])
        updateVoiceButton(listening: false)
        closeButton.target = self
        closeButton.action = #selector(closeApp)
        closeButton.sendAction(on: [.leftMouseDown])
        minimizeButton.target = self
        minimizeButton.action = #selector(toggleMinimize)
        minimizeButton.sendAction(on: [.leftMouseDown])
        updateMinimizeButton()
        maximizeButton.target = self
        maximizeButton.action = #selector(toggleMaximize)
        maximizeButton.sendAction(on: [.leftMouseDown])
        updateMaximizeButton()
        responseButton.target = self
        responseButton.action = #selector(toggleResponse)
        responseButton.sendAction(on: [.leftMouseDown])
        queryPopup.target = self
        queryPopup.action = #selector(querySelected(_:))
        newTabButton.target = self
        newTabButton.action = #selector(openNewTab)
        newSessionButton.target = self
        newSessionButton.action = #selector(newSession)
        newSessionButton.sendAction(on: [.leftMouseDown])
        responseWebView.navigationDelegate = self
        responseWebView.loadHTMLString(Self.markdownHTML(), baseURL: nil)

        if isSelfMode {
            rebuildDirectoryMenu()
        }

        layoutViews()
        startIPCReader()
        window.makeKeyAndOrderFront(nil)
        keyTape.focusTextView()
    }

    /// Default status when no transient message is showing. Input is always
    /// enabled while the overlay has focus, so there is no capture state.
    private func showIdleStatus() {
        switch mode {
        case .selfHost:
            guard let tab = activeRpcTab else {
                statusLabel.stringValue = "READY"
                statusLabel.textColor = .systemGreen
                return
            }
            if tab.isLaunching {
                statusLabel.stringValue = "STARTING PI"
                statusLabel.textColor = .systemOrange
            } else if tab.directory == nil {
                statusLabel.stringValue = "SELECT PROJECT"
                statusLabel.textColor = .systemOrange
            } else if tab.session == nil, tab.exitStatus != nil {
                statusLabel.stringValue = "PI EXITED"
                statusLabel.textColor = .systemRed
            } else if tab.session == nil {
                statusLabel.stringValue = "NO PI SESSION"
                statusLabel.textColor = .systemOrange
            } else {
                statusLabel.stringValue = "READY"
                statusLabel.textColor = .systemGreen
            }
        case .selfTerminal:
            if terminalSessions[activeDirectory.path] == nil {
                statusLabel.stringValue = "NO PI SESSION"
                statusLabel.textColor = .systemOrange
            } else {
                statusLabel.stringValue = "READY"
                statusLabel.textColor = .systemGreen
            }
        case .tty:
            if ttyPath == nil {
                statusLabel.stringValue = "NO PI SESSION"
                statusLabel.textColor = .systemOrange
            } else {
                statusLabel.stringValue = "READY"
                statusLabel.textColor = .systemGreen
            }
        default:
            statusLabel.stringValue = "READY"
            statusLabel.textColor = .systemGreen
        }
    }

    /// Opens the terminal injector and starts a session when one is configured.
    /// Typing never needs to be enabled: the key view only receives keys while
    /// the overlay window is focused.
    func prepareInput() {
        if mode == .tty, let inj = injector {
            if !inj.openIfNeeded() {
                statusLabel.stringValue = "TTY OPEN ERROR"
                statusLabel.textColor = .systemRed
            } else {
                statusLabel.stringValue = "READY"
                statusLabel.textColor = .systemGreen
            }
        } else if mode == .selfHost {
            // Blank tabs wait for a directory pick; sessions are started above.
            if let tab = activeRpcTab, tab.session == nil, let directory = tab.directory {
                startRpcSession(in: tab, directory: directory, resumeLatest: true)
            }
        } else if mode == .selfTerminal, terminalSessions[activeDirectory.path] == nil {
            switchSession(to: activeDirectory)
        }

        keyTape.needsDisplay = true
    }

    private func updateVoiceButton(listening: Bool) {
        voiceButton.image = NSImage(
            systemSymbolName: listening ? "waveform" : "mic.fill",
            accessibilityDescription: "Speak"
        )
        voiceButton.contentTintColor = listening ? .systemRed : NSColor(white: 0.88, alpha: 1)
        voiceButton.toolTip = listening
            ? "Stop listening (Option+V)"
            : "Speak (Option+V)"
        voiceButton.setAccessibilityLabel("Speak")
    }

    // MARK: - Self mode sessions

    func startInitialSelfSession() {
        guard isSelfMode else { return }

        if mode == .selfHost, rpcTabs.isEmpty {
            loadProfiles()

            // An explicit --dir beats the saved tabs.
            let explicitDirectory = cliDirectory != nil ? activeDirectory : nil
            if restoreOpenTabs() {
                if let explicitDirectory { switchSession(to: explicitDirectory) }
                return
            }
            let tab = makeBlankTab()
            rpcTabs.append(tab)
            activateRpcTab(tab)
        }
        switchSession(to: activeDirectory)
    }

    // MARK: - Profiles

    /// Loads profiles.conf, importing the legacy tabs.conf into a "default"
    /// profile on first run.
    private func loadProfiles() {
        guard mode == .selfHost else { return }

        let loaded = profileStore.load()
        if loaded.profiles.isEmpty {
            if !FileManager.default.fileExists(atPath: profileStore.url.path) {
                // First run with profiles: bring the legacy tab list into a
                // profile named "default".
                let legacy = tabStore.load()
                let tabs = legacy.map {
                    ProfileTab(path: $0.path, active: $0.active, session: $0.session)
                }
                profiles = [OverlayProfile(name: ProfileStore.defaultName, tabs: tabs)]
                activeProfileName = ProfileStore.defaultName
                debugLog("profiles.conf: imported \(tabs.count) tab(s) from tabs.conf")
            } else {
                profiles = [OverlayProfile(name: ProfileStore.defaultName, tabs: [])]
                activeProfileName = ProfileStore.defaultName
            }
        } else {
            profiles = loaded.profiles
            activeProfileName = loaded.active
        }

        if profiles.isEmpty {
            profiles = [OverlayProfile(name: ProfileStore.defaultName, tabs: [])]
        }
        if !profiles.contains(where: { $0.name == activeProfileName }) {
            activeProfileName = profiles[0].name
        }

        profileStore.save(active: activeProfileName, profiles: profiles)
        rebuildProfileMenu()
        debugLog(
            "profiles loaded active=\(activeProfileName) count=\(profiles.count) "
                + "tabs=\((profiles.first(where: { $0.name == activeProfileName })?.tabs.count ?? 0))"
        )
    }

    /// Rebuilds the tab strip from the active profile. Only the active tab gets
    /// a live pi child at launch; the rest start when they are first selected.
    @discardableResult
    private func restoreOpenTabs() -> Bool {
        guard let profile = profiles.first(where: { $0.name == activeProfileName }) else {
            return false
        }

        var seen = Set<String>()
        var restored: [(tab: RpcTab, active: Bool)] = []

        for entry in profile.tabs {
            guard let url = directoryStore.normalize(entry.path) else {
                debugLog("profiles.conf: skipping missing directory \(entry.path)")
                missingTabPaths.append(entry.path)
                continue
            }
            guard !seen.contains(url.path) else { continue }
            seen.insert(url.path)

            let tab = makeBlankTab()
            tab.directory = url
            tab.sessionFile = entry.session
            rpcTabs.append(tab)
            restored.append((tab, entry.active))
        }

        guard let first = restored.first else { return false }
        let active = restored.first(where: { $0.active })?.tab ?? first.tab
        if let directory = active.directory { activeDirectory = directory }
        debugLog(
            "profile restored name=\(activeProfileName) tabs=\(restored.count) "
                + "from \(profileStore.url.path)"
        )
        activateRpcTab(active)
        return true
    }

    /// Mirrors the active profile's tab strip into profiles.conf.
    private func saveOpenTabs() {
        guard mode == .selfHost else { return }
        guard let index = profiles.firstIndex(where: { $0.name == activeProfileName }) else {
            return
        }

        var tabs: [ProfileTab] = rpcTabs.compactMap { tab in
            guard let directory = tab.directory else { return nil }
            return ProfileTab(
                path: directory.path,
                active: tab.id == activeRpcTabID,
                session: tab.sessionFile
            )
        }
        let live = Set(tabs.map { $0.path })
        for path in missingTabPaths where !live.contains(path) {
            tabs.append(ProfileTab(path: path, active: false, session: nil))
        }

        profiles[index].tabs = tabs
        profileStore.save(active: activeProfileName, profiles: profiles)
    }

    private func rebuildProfileMenu() {
        guard mode == .selfHost else { return }

        let menu = NSMenu()
        // For a pull-down button the first item supplies the visible title.
        let header = NSMenuItem(
            title: "👤 \(activeProfileName)",
            action: nil,
            keyEquivalent: ""
        )
        header.toolTip = "Profile — its tabs are shown to the right"
        menu.addItem(header)
        menu.addItem(.separator())

        for profile in profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(profileMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.name
            item.state = profile.name == activeProfileName ? .on : .off
            item.toolTip = "\(profile.tabs.count) tab(s)"
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let new = NSMenuItem(
            title: "New Profile…",
            action: #selector(newProfile),
            keyEquivalent: ""
        )
        new.target = self
        menu.addItem(new)

        let rename = NSMenuItem(
            title: "Rename Profile…",
            action: #selector(renameProfile),
            keyEquivalent: ""
        )
        rename.target = self
        menu.addItem(rename)

        let delete = NSMenuItem(
            title: "Delete Profile…",
            action: #selector(deleteProfile),
            keyEquivalent: ""
        )
        delete.target = self
        delete.isEnabled = profiles.count > 1
        menu.addItem(delete)

        profilePopup.menu = menu
        profilePopup.title = "👤 \(activeProfileName)"
        profilePopup.toolTip = "Profile: \(activeProfileName) — its tabs are shown to the right"
        updateStatusItem()
    }

    @objc private func profileMenuItemSelected(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        switchProfile(to: name)
    }

    /// Swaps the whole tab strip for another profile. The outgoing profile's
    /// tabs are parked in memory (not stopped), so a running turn keeps going
    /// and switching back shows its result.
    private func switchProfile(
        to name: String,
        savingCurrent: Bool = true,
        discardingCurrent: Bool = false
    ) {
        guard mode == .selfHost,
              name != activeProfileName,
              profiles.contains(where: { $0.name == name }) else { return }

        if savingCurrent { saveOpenTabs() }

        let oldName = activeProfileName
        let oldTabs = rpcTabs

        if discardingCurrent {
            for tab in oldTabs {
                tab.session?.stop()
                tab.session = nil
                tab.webView.navigationDelegate = nil
                tab.webView.removeFromSuperview()
            }
            profileRuntime.removeValue(forKey: oldName)
        } else {
            // Park the runtime; only the UI is detached.
            saveActiveTabState()
            for tab in oldTabs { tab.webView.isHidden = true }
            profileRuntime[oldName] = ProfileRuntime(
                tabs: oldTabs,
                activeTabID: activeRpcTabID,
                missingPaths: missingTabPaths
            )
        }

        rpcTabs = []
        activeRpcTabID = nil
        missingTabPaths = []

        injector?.closeAll()
        injector = nil
        appleInjector = nil
        terminalInjector = nil
        ttyPath = nil
        responseText = ""
        responseExpanded = false
        responseUserCollapsed = false
        latestResponseText = ""
        sessionQueries = []
        selectedQueryID = nil
        rawText = ""
        tape = []
        keyTape.agentStatus = .idle
        rebuildQueryMenu()
        updateResponseButton()
        renderMarkdown()

        activeProfileName = name
        rebuildProfileMenu()

        if let runtime = profileRuntime.removeValue(forKey: name) {
            rpcTabs = runtime.tabs
            missingTabPaths = runtime.missingPaths
            let active = runtime.tabs.first(where: { $0.id == runtime.activeTabID })
                ?? runtime.tabs.first
            if let active {
                activateRpcTab(active)
            } else {
                let blank = makeBlankTab()
                rpcTabs.append(blank)
                activateRpcTab(blank)
            }
        } else if !restoreOpenTabs() {
            let blank = makeBlankTab()
            rpcTabs.append(blank)
            activateRpcTab(blank)
        }

        rebuildTabBar()
        saveOpenTabs()
        layoutViews()
        focusOverlay()
        debugLog("profile switched active=\(activeProfileName)")
    }

    private func askedProfileName(
        title: String,
        initial: String,
        completion: @escaping (String?) -> Void
    ) {
        if isMinimized { toggleMinimize() }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Tabs opened in the overlay belong to this profile."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(field.stringValue)
        }
    }

    private func sanitizedProfileName(_ raw: String) -> String? {
        let name = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return String(name.prefix(40))
    }

    @objc private func newProfile() {
        askedProfileName(title: "New Profile", initial: "Profile \(profiles.count + 1)") { [weak self] raw in
            guard let self,
                  let name = raw.flatMap({ self.sanitizedProfileName($0) }) else { return }
            guard !self.profiles.contains(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                self.showAlert(
                    title: "Profile already exists",
                    message: "A profile named “\(name)” already exists."
                )
                return
            }

            self.saveOpenTabs()
            self.profiles.append(OverlayProfile(name: name, tabs: []))
            self.profileStore.save(active: self.activeProfileName, profiles: self.profiles)
            self.switchProfile(to: name)
        }
    }

    @objc private func renameProfile() {
        guard let index = profiles.firstIndex(where: { $0.name == activeProfileName }) else {
            return
        }
        let oldName = profiles[index].name
        askedProfileName(title: "Rename Profile", initial: oldName) { [weak self] raw in
            guard let self,
                  let name = raw.flatMap({ self.sanitizedProfileName($0) }),
                  name != oldName else { return }
            guard !self.profiles.contains(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                self.showAlert(
                    title: "Profile already exists",
                    message: "A profile named “\(name)” already exists."
                )
                return
            }

            self.profiles[index].name = name
            self.activeProfileName = name
            if let runtime = self.profileRuntime.removeValue(forKey: oldName) {
                self.profileRuntime[name] = runtime
            }
            self.profileStore.save(active: name, profiles: self.profiles)
            self.rebuildProfileMenu()
        }
    }

    @objc private func deleteProfile() {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.name == activeProfileName }) else {
            return
        }

        if isMinimized { toggleMinimize() }

        let alert = NSAlert()
        alert.messageText = "Delete profile “\(activeProfileName)”?"
        alert.informativeText =
            "Its tabs and pi processes will be stopped. Saved conversations stay on disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }

            self.profiles.remove(at: index)
            let next = self.profiles[min(index, self.profiles.count - 1)].name
            self.profileStore.save(active: next, profiles: self.profiles)
            self.switchProfile(to: next, savingCurrent: false, discardingCurrent: true)
        }
    }

    private func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Menu bar status item

    /// Installs the background menu-bar icon (self mode only). It mirrors the
    /// processing/completed state of every tab in every profile.
    func installStatusItem() {
        guard mode == .selfHost, statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.toolTip = "pi overlay"
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let statusItem else { return }

        var processing = 0
        var done = 0
        var rows: [(name: String, tabs: [RpcTab])] = []

        if mode == .selfHost {
            for profile in profiles {
                let tabs: [RpcTab]
                if profile.name == activeProfileName {
                    tabs = rpcTabs
                } else {
                    tabs = profileRuntime[profile.name]?.tabs ?? []
                }
                rows.append((profile.name, tabs))
                processing += tabs.filter { $0.status == .processing }.count
                done += tabs.filter { $0.status == .done }.count
            }
        } else {
            if keyTape.agentStatus == .processing { processing = 1 }
            else if keyTape.agentStatus == .done { done = 1 }
        }

        statusItem.button?.image = statusImage(processing: processing, done: done)
        statusItem.button?.toolTip = statusTooltip(processing: processing, done: done)
        statusItem.menu = statusMenu(rows: rows, processing: processing, done: done)
    }

    private func statusImage(processing: Int, done: Int) -> NSImage? {
        let symbol: String
        let color: NSColor?
        if processing > 0 {
            symbol = "hourglass"
            color = .systemOrange
        } else if done > 0 {
            symbol = "checkmark.circle.fill"
            color = .systemGreen
        } else {
            symbol = "terminal"
            color = nil
        }

        guard let base = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "pi overlay status"
        ) else { return nil }

        let size = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let color {
            let palette = NSImage.SymbolConfiguration(paletteColors: [color])
            let image = base.withSymbolConfiguration(size.applying(palette))
            image?.isTemplate = false
            return image
        }
        let image = base.withSymbolConfiguration(size)
        image?.isTemplate = true
        return image
    }

    private func statusTooltip(processing: Int, done: Int) -> String {
        if processing > 0 { return "pi — \(processing) processing" }
        if done > 0 { return "pi — \(done) completed" }
        return "pi overlay"
    }

    private func statusMenu(
        rows: [(name: String, tabs: [RpcTab])],
        processing: Int,
        done: Int
    ) -> NSMenu {
        let menu = NSMenu()

        let show = NSMenuItem(
            title: "Show Overlay",
            action: #selector(statusShowOverlay),
            keyEquivalent: ""
        )
        show.target = self
        menu.addItem(show)

        if mode == .selfHost {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)

            for row in rows {
                let item = NSMenuItem(
                    title: row.name,
                    action: #selector(statusProfileSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = row.name
                item.state = row.name == activeProfileName ? .on : .off
                item.attributedTitle = profileStatusTitle(name: row.name, tabs: row.tabs)
                item.submenu = statusTabMenu(profile: row.name, tabs: row.tabs)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit TTY Overlay",
            action: #selector(statusQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func profileStatusTitle(name: String, tabs: [RpcTab]) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        let processing = tabs.filter { $0.status == .processing }.count
        let done = tabs.filter { $0.status == .done }.count
        if processing > 0 {
            title.append(NSAttributedString(
                string: "  ● \(processing)",
                attributes: [.foregroundColor: NSColor.systemRed]
            ))
        }
        if done > 0 {
            title.append(NSAttributedString(
                string: "  ✓ \(done)",
                attributes: [.foregroundColor: NSColor.systemGreen]
            ))
        }
        if processing == 0, done == 0 {
            title.append(NSAttributedString(
                string: "  idle",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return title
    }

    private func statusTabMenu(profile: String, tabs: [RpcTab]) -> NSMenu {
        let menu = NSMenu()
        if tabs.isEmpty {
            let empty = NSMenuItem(title: "No tabs", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for tab in tabs {
            let item = NSMenuItem(
                title: tab.directory?.lastPathComponent ?? "New Tab",
                action: #selector(statusTabSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = StatusTabRef(profile: profile, tabID: tab.id)
            item.attributedTitle = tabStatusTitle(tab)
            menu.addItem(item)
        }
        return menu
    }

    private func tabStatusTitle(_ tab: RpcTab) -> NSAttributedString {
        let (mark, color) = statusMark(for: tab)
        let name = tab.directory?.lastPathComponent ?? "New Tab"
        let title = NSMutableAttributedString()
        if !mark.isEmpty {
            title.append(NSAttributedString(
                string: "\(mark) ",
                attributes: [.foregroundColor: color]
            ))
        }
        title.append(NSAttributedString(
            string: name,
            attributes: [.foregroundColor: NSColor.labelColor]
        ))

        let status: String
        switch tab.status {
        case .processing: status = "processing"
        case .done: status = "done"
        case .idle: status = tab.exitStatus != nil ? "exited" : "idle"
        }
        title.append(NSAttributedString(
            string: "  \(status)",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        ))
        return title
    }

    private func statusMark(for tab: RpcTab) -> (String, NSColor) {
        if tab.exitStatus != nil, tab.session == nil, tab.status == .idle {
            return ("!", .systemRed)
        }
        switch tab.status {
        case .processing: return ("●", .systemRed)
        case .done: return ("✓", .systemGreen)
        case .idle: return ("", .secondaryLabelColor)
        }
    }

    @objc private func statusShowOverlay() {
        if isMinimized { toggleMinimize() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focusOverlay()
    }

    @objc private func statusProfileSelected(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if name != activeProfileName { switchProfile(to: name) }
        statusShowOverlay()
    }

    @objc private func statusTabSelected(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? StatusTabRef else { return }
        if ref.profile != activeProfileName { switchProfile(to: ref.profile) }
        if let tab = rpcTab(withID: ref.tabID),
           rpcTabs.contains(where: { $0.id == tab.id }) {
            activateRpcTab(tab)
        }
        statusShowOverlay()
    }

    @objc private func statusQuit() {
        closeApp()
    }

    private func rebuildDirectoryMenu() {
        let selectedDirectory: URL? = mode == .selfHost
            ? activeRpcTab?.directory
            : activeDirectory
        let menu = NSMenu()

        // For a pull-down button the first item supplies the button title.
        let header = NSMenuItem(
            title: "📁 \(selectedDirectory?.lastPathComponent ?? "Select project…")",
            action: nil,
            keyEquivalent: ""
        )
        header.toolTip = selectedDirectory?.path ?? "Choose a project directory"
        menu.addItem(header)

        for url in directoryStore.recents {
            let item = NSMenuItem(
                title: displayPath(url),
                action: #selector(directoryMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url.path
            item.state = url.path == selectedDirectory?.path ? .on : .off
            if hasSession(for: url.path) {
                item.toolTip = "pi session open"
            }
            menu.addItem(item)
        }

        if !directoryStore.recents.isEmpty {
            menu.addItem(.separator())
        }

        let choose = NSMenuItem(
            title: "Choose Folder…   ⌃N",
            action: #selector(chooseDirectory),
            keyEquivalent: ""
        )
        choose.target = self
        menu.addItem(choose)

        if selectedDirectory != nil {
            let reveal = NSMenuItem(
                title: "Reveal in Finder",
                action: #selector(revealActiveDirectory),
                keyEquivalent: ""
            )
            reveal.target = self
            menu.addItem(reveal)
        }

        if mode == .selfHost {
            if let tab = activeRpcTab, tab.directory != nil, tab.session == nil {
                let restart = NSMenuItem(
                    title: tab.exitStatus == nil ? "Start pi" : "Restart pi",
                    action: #selector(restartActiveSession),
                    keyEquivalent: ""
                )
                restart.target = self
                menu.addItem(restart)
            }
            if activeRpcTab != nil {
                let close = NSMenuItem(
                    title: "Close tab",
                    action: #selector(closeActiveSession),
                    keyEquivalent: ""
                )
                close.target = self
                menu.addItem(close)
            }
        } else if hasSession(for: activeDirectory.path) {
            let close = NSMenuItem(
                title: "Close pi session",
                action: #selector(closeActiveSession),
                keyEquivalent: ""
            )
            close.target = self
            menu.addItem(close)
        }

        directoryPopup.menu = menu
        directoryPopup.title = "📁 \(selectedDirectory?.lastPathComponent ?? "Select project…")"
        directoryPopup.toolTip = selectedDirectory?.path ?? "Choose a project directory"
    }

    @objc private func directoryMenuItemSelected(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        switchSession(to: URL(fileURLWithPath: path))
    }

    @objc func chooseDirectory() {
        // A 32pt-tall window cannot host a sheet; come back up first.
        if isMinimized { toggleMinimize() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open pi here"
        panel.message = "Choose the working directory for a new pi session."
        panel.directoryURL = (mode == .selfHost ? activeRpcTab?.directory : nil)
            ?? activeDirectory
        NSApp.activate(ignoringOtherApps: true)

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                self?.focusOverlay()
                return
            }
            self?.switchSession(to: url)
        }
    }

    @objc private func revealActiveDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([activeDirectory])
    }

    /// pi's `name` field is provider-supplied and sometimes padded with
    /// generated ids ("Deepseek V4 1 Flash 763205315794"). Show the stable
    /// `provider/model` reference instead, like pi's own `--model` flag.
    private func modelIdentifier(_ model: [String: Any]?) -> String? {
        guard let model,
              let provider = model["provider"] as? String, !provider.isEmpty,
              let id = model["id"] as? String, !id.isEmpty else { return nil }
        return "\(provider)/\(id)"
    }

    private func modelFriendlyName(_ model: [String: Any]?) -> String? {
        guard let name = model?["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != modelIdentifier(model) else { return nil }
        return trimmed
    }

    private func modelDisplayName(_ model: [String: Any]?) -> String {
        guard let model else { return "Model…" }
        return modelIdentifier(model) ?? (model["name"] as? String) ?? "Model"
    }

    private func isSameModel(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        guard let a, let b else { return false }
        return (a["provider"] as? String) == (b["provider"] as? String)
            && (a["id"] as? String) == (b["id"] as? String)
    }

    private func setModelTooltip(_ model: [String: Any]?) {
        guard let model,
              let provider = model["provider"] as? String,
              let modelId = model["id"] as? String else {
            modelPopup.toolTip = "Model for this pi RPC session"
            return
        }
        if let friendly = modelFriendlyName(model) {
            modelPopup.toolTip = "\(friendly)\n\(provider)/\(modelId)"
        } else {
            modelPopup.toolTip = "\(provider)/\(modelId)"
        }
    }

    private func rebuildModelMenu() {
        guard mode == .selfHost, let tab = activeRpcTab else {
            modelPopup.removeAllItems()
            modelPopup.addItem(withTitle: "Model…")
            modelPopup.isEnabled = false
            modelPopup.toolTip = "Model for this pi RPC session"
            return
        }

        let models = tab.models ?? []
        let current = tab.currentModel
        let key = tab.directory?.path ?? "blank"

        modelPopup.removeAllItems()

        guard !models.isEmpty else {
            modelPopup.addItem(withTitle: modelDisplayName(current))
            modelPopup.lastItem?.isEnabled = false
            modelPopup.isEnabled = false
            setModelTooltip(current)
            debugLog("model menu key=\(key) models=0 current=\(modelDisplayName(current)) items=\(modelPopup.numberOfItems)")
            return
        }

        var selectedIndex = 0

        if current == nil {
            modelPopup.addItem(withTitle: "Model…")
        } else if !models.contains(where: { isSameModel($0, current) }) {
            modelPopup.addItem(withTitle: modelDisplayName(current))
        }

        for model in models {
            let provider = model["provider"] as? String ?? ""
            let modelId = model["id"] as? String ?? ""
            let label = "\(provider)/\(modelId)"
            let ref = ModelRef(provider: provider, modelId: modelId, name: label)

            modelPopup.addItem(withTitle: label)
            guard let item = modelPopup.lastItem else { continue }
            item.representedObject = ref
            item.target = self
            item.action = #selector(modelSelected(_:))
            let friendly = modelFriendlyName(model)
            item.toolTip = friendly.map { "\($0)\n\(label)" } ?? label

            if isSameModel(current, model) {
                item.state = .on
                selectedIndex = modelPopup.numberOfItems - 1
            }
        }

        modelPopup.selectItem(at: selectedIndex)
        modelPopup.isEnabled = (tab.session != nil && tab.exitStatus == nil)
        setModelTooltip(current)
        debugLog("model menu key=\(key) models=\(models.count) current=\(modelDisplayName(current)) items=\(modelPopup.numberOfItems) selected=\(modelPopup.titleOfSelectedItem ?? "nil")")
    }

    @objc private func modelSelected(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ModelRef,
              let tab = activeRpcTab,
              let session = tab.session,
              session.isRunning else { return }

        statusLabel.stringValue = "SWITCHING MODEL"
        statusLabel.textColor = .systemOrange
        session.setModel(provider: ref.provider, modelId: ref.modelId)
        focusOverlay()
    }

    // MARK: - Tabs

    /// Marker shown before the tab name plus the color it should be drawn in.
    private func tabTitleParts(_ tab: RpcTab) -> (marker: String, name: String, color: NSColor?) {
        let name = tab.directory?.lastPathComponent ?? "New Tab"
        if tab.isLaunching {
            return ("…", name, nil)
        }
        if tab.exitStatus != nil && tab.session == nil {
            return ("!", name, nil)
        }
        switch tab.status {
        case .processing:
            return ("●", name, .systemRed)
        case .done:
            return ("✓", name, .systemGreen)
        case .idle:
            return ("", name, nil)
        }
    }

    private func tabTitle(_ tab: RpcTab) -> String {
        let parts = tabTitleParts(tab)
        return parts.marker.isEmpty ? parts.name : "\(parts.marker) \(parts.name)"
    }

    private func rebuildTabBar() {
        guard mode == .selfHost else { return }

        tabContentView.subviews.forEach { $0.removeFromSuperview() }

        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var x: CGFloat = 0
        var activeOrigin: CGFloat = 0

        for (index, tab) in rpcTabs.enumerated() {
            let parts = tabTitleParts(tab)
            let title = tabTitle(tab)
            let width = min(
                220,
                max(96, (title as NSString).size(withAttributes: attrs).width + 40)
            )
            let button = NSButton(
                title: title,
                target: self,
                action: #selector(selectTabButton(_:))
            )
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.borderWidth = 0.5
            button.layer?.borderColor = NSColor(white: 0.76, alpha: 0.8).cgColor
            button.layer?.backgroundColor = (tab.id == activeRpcTabID
                ? NSColor.white
                : NSColor(white: 0.84, alpha: 1)).cgColor
            button.alignment = .center
            button.toolTip = tab.directory?.path ?? "No project selected"
            button.frame = NSRect(x: x, y: 1, width: width, height: 26)
            let titleColor = tab.id == activeRpcTabID
                ? NSColor.labelColor
                : NSColor.secondaryLabelColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.tailIndent = -22
            let attributed = NSMutableAttributedString(
                string: title,
                attributes: [
                    .font: tab.id == activeRpcTabID
                        ? NSFont.systemFont(ofSize: 10, weight: .semibold)
                        : font,
                    .foregroundColor: titleColor,
                    .paragraphStyle: paragraph,
                ]
            )
            // Tint only the status marker: red while processing, green when done.
            if !parts.marker.isEmpty, let markerColor = parts.color {
                attributed.addAttribute(
                    .foregroundColor,
                    value: markerColor,
                    range: NSRange(location: 0, length: parts.marker.utf16.count)
                )
            }
            button.attributedTitle = attributed
            tabContentView.addSubview(button)

            let close = NSButton(
                title: "×",
                target: self,
                action: #selector(closeTabButton(_:))
            )
            close.tag = index
            close.isBordered = false
            close.wantsLayer = true
            close.layer?.cornerRadius = 3
            close.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            close.contentTintColor = .secondaryLabelColor
            close.toolTip = "Close tab (Ctrl+W)"
            close.frame = NSRect(x: x + width - 20, y: 5, width: 14, height: 18)
            tabContentView.addSubview(close)

            if tab.id == activeRpcTabID {
                activeOrigin = x
            }
            x += width + 6
        }

        tabContentView.frame = NSRect(x: 0, y: 0, width: max(1, x), height: 26)

        let visibleWidth = tabScrollView.contentSize.width
        let maxScroll = max(0, x - visibleWidth)
        let targetX = min(max(0, activeOrigin - 8), maxScroll)
        tabScrollView.contentView.scroll(to: NSPoint(x: targetX, y: 0))
        tabScrollView.reflectScrolledClipView(tabScrollView.contentView)
        saveOpenTabs()
        updateStatusItem()
    }

    // MARK: - Saved sessions row

    /// Rescans the directory's session folder off the main thread.
    private func refreshSessionRow() {
        guard mode == .selfHost else { return }

        guard let directory = activeRpcTab?.directory else {
            sessionInfos = []
            rebuildSessionMenu()
            return
        }

        sessionLoadToken += 1
        let token = sessionLoadToken
        DispatchQueue.global(qos: .utility).async {
            let infos = PiSessionStore.list(for: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.sessionLoadToken else { return }
                self.sessionInfos = infos
                self.rebuildSessionMenu()
            }
        }
    }

    private static func sessionTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    private func rebuildSessionMenu() {
        guard mode == .selfHost else { return }

        sessionPopup.removeAllItems()

        guard !sessionInfos.isEmpty else {
            sessionPopup.addItem(withTitle: "No saved sessions")
            sessionPopup.lastItem?.isEnabled = false
            sessionPopup.isEnabled = false
            return
        }

        let currentFile = activeRpcTab?.sessionFile
        var selected = 0

        for (index, info) in sessionInfos.enumerated() {
            let stamp = Self.sessionTimestamp(info.modified)
            let label = info.name ?? info.preview
            let title = label.map { "\($0) · \(stamp)" } ?? stamp

            sessionPopup.addItem(withTitle: title)
            guard let item = sessionPopup.lastItem else { continue }
            item.representedObject = info.path
            item.target = self
            item.action = #selector(sessionMenuItemSelected(_:))
            item.toolTip = "\(info.path)\nLast activity \(stamp)"
            if info.path == currentFile {
                item.state = .on
                selected = index
            }
        }

        sessionPopup.selectItem(at: selected)
        let running = activeRpcTab?.session?.isRunning == true
        sessionPopup.isEnabled = running
        newSessionButton.isEnabled = running

        debugLog(
            "session menu key=\(activeRpcTab?.directory?.path ?? "blank") "
                + "count=\(sessionInfos.count) "
                + "current=\((currentFile as NSString?)?.lastPathComponent ?? "none")"
        )
    }

    @objc private func newSession() {
        guard mode == .selfHost,
              let tab = activeRpcTab,
              let session = tab.session,
              session.isRunning else {
            statusLabel.stringValue = "NO PI SESSION"
            statusLabel.textColor = .systemRed
            return
        }
        guard !session.isStreaming else {
            statusLabel.stringValue = "BUSY — CANNOT START NEW SESSION"
            statusLabel.textColor = .systemOrange
            return
        }

        session.newSession()
        statusLabel.stringValue = "STARTING NEW SESSION"
        statusLabel.textColor = .systemOrange
        focusOverlay()
    }

    @objc private func sessionMenuItemSelected(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let tab = activeRpcTab,
              let session = tab.session,
              session.isRunning else { return }

        guard path != tab.sessionFile else { return }

        guard !session.isStreaming else {
            statusLabel.stringValue = "BUSY — CANNOT SWITCH"
            statusLabel.textColor = .systemOrange
            return
        }

        statusLabel.stringValue = "SWITCHING SESSION"
        statusLabel.textColor = .systemOrange
        session.switchToSession(path: path)
        focusOverlay()
    }

    @objc private func selectTabButton(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < rpcTabs.count else { return }
        activateRpcTab(rpcTabs[sender.tag])
    }

    private func makeBlankTab() -> RpcTab {
        let tab = RpcTab()
        tab.webView.navigationDelegate = self
        tab.webView.loadHTMLString(Self.markdownHTML(), baseURL: nil)
        tab.webView.isHidden = true
        window.contentView?.addSubview(tab.webView)
        return tab
    }

    private func removeTab(_ tab: RpcTab) {
        tab.session?.stop()
        tab.session = nil
        tab.webView.navigationDelegate = nil
        tab.webView.removeFromSuperview()
        rpcTabs.removeAll { $0.id == tab.id }
    }

    private func saveActiveTabState() {
        guard mode == .selfHost, let tab = activeRpcTab else { return }
        tab.responseText = responseText
        tab.responseExpanded = responseExpanded
        tab.responseUserCollapsed = responseUserCollapsed
        tab.queries = sessionQueries
        tab.selectedQueryID = selectedQueryID
        tab.rawText = rawText
        tab.tape = tape
        tab.status = keyTape.agentStatus
    }

    private func loadTabState(_ tab: RpcTab) {
        responseText = tab.responseText
        responseExpanded = tab.responseExpanded
        responseUserCollapsed = tab.responseUserCollapsed
        sessionQueries = tab.queries
        selectedQueryID = tab.selectedQueryID
        rawText = tab.rawText
        tape = tab.tape
        keyTape.agentStatus = tab.status
    }

    // MARK: - Prompt history

    private static func queryID(from message: [String: Any], fallbackIndex: Int?) -> String {
        if let stamp = (message["timestamp"] as? NSNumber)?.doubleValue {
            return String(stamp)
        }
        if let fallbackIndex {
            return "user-\(fallbackIndex)"
        }
        return "user-\(UUID().uuidString)"
    }

    /// Session entries form an append-only tree; walk from the current leaf
    /// back to the root so abandoned branches are not shown as history.
    private static func activeBranch(
        from entries: [[String: Any]],
        leafId: String?
    ) -> [[String: Any]] {
        guard let leafId else { return [] }

        var byID: [String: [String: Any]] = [:]
        for entry in entries {
            if let id = entry["id"] as? String { byID[id] = entry }
        }

        var path: [[String: Any]] = []
        var current: String? = leafId
        var remaining = entries.count + 1
        while let id = current, let entry = byID[id], remaining > 0 {
            path.append(entry)
            current = entry["parentId"] as? String
            remaining -= 1
        }
        return path.reversed()
    }

    /// Groups the conversation into user prompts and the last assistant text
    /// that followed each one. Messages arrive in conversation order.
    private static func buildQueries(from messages: [[String: Any]]) -> [SessionQuery] {
        var queries: [SessionQuery] = []
        var current: SessionQuery?

        for (index, message) in messages.enumerated() {
            let role = message["role"] as? String
            guard role == "user" || role == "assistant" else { continue }

            let text = RpcSession.messageText(from: message)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if role == "user" {
                if let open = current { queries.append(open) }
                current = SessionQuery(
                    id: Self.queryID(from: message, fallbackIndex: index),
                    prompt: text.isEmpty ? "(image prompt)" : text,
                    answer: ""
                )
            } else if var open = current, !text.isEmpty {
                open.answer = text
                current = open
            }
        }

        if let open = current { queries.append(open) }
        return queries
    }

    private static func queryTitle(_ prompt: String, limit: Int = 90) -> String {
        let flat = prompt
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !flat.isEmpty else { return "(empty prompt)" }
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func rebuildQueryMenu() {
        queryPopup.removeAllItems()
        queryPopup.addItem(withTitle: "Latest answer")

        for query in sessionQueries.reversed() {
            queryPopup.addItem(withTitle: Self.queryTitle(query.prompt))
            guard let item = queryPopup.lastItem else { continue }
            item.representedObject = query.id
            item.toolTip = query.prompt
        }

        if let id = selectedQueryID,
           let index = sessionQueries.firstIndex(where: { $0.id == id }) {
            // Items are newest-first; item 0 is the synthetic "Latest answer".
            queryPopup.selectItem(at: sessionQueries.count - index)
        } else {
            selectedQueryID = nil
            if mode == .selfHost, let tab = activeRpcTab {
                tab.selectedQueryID = nil
            }
            queryPopup.selectItem(at: 0)
        }

        queryPopup.isEnabled = !sessionQueries.isEmpty
        queryPopup.isHidden = isMinimized || sessionQueries.isEmpty
        updateResponseButton()
    }

    @objc private func querySelected(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index <= 0 {
            selectedQueryID = nil
        } else {
            let queryIndex = sessionQueries.count - index
            guard sessionQueries.indices.contains(queryIndex) else { return }
            selectedQueryID = sessionQueries[queryIndex].id
        }

        if mode == .selfHost, let tab = activeRpcTab {
            tab.selectedQueryID = selectedQueryID
        }
        applyQuerySelection(expand: true)
        focusOverlay()
    }

    /// Puts the selected prompt's answer (or the latest answer) into the
    /// response panel. `expand` is true when the user picked an item.
    private func applyQuerySelection(expand: Bool) {
        if let id = selectedQueryID,
           !sessionQueries.contains(where: { $0.id == id }) {
            selectedQueryID = nil
        }

        let latest: String
        if mode == .selfHost, let tab = activeRpcTab {
            latest = tab.latestAnswerText.isEmpty ? tab.streamingText : tab.latestAnswerText
        } else {
            latest = latestResponseText
        }

        let text: String
        if let id = selectedQueryID,
           let query = sessionQueries.first(where: { $0.id == id }) {
            text = query.answer
        } else {
            text = latest
        }

        responseText = text
        if expand && !text.isEmpty {
            responseExpanded = true
            responseUserCollapsed = false
        }

        if mode == .selfHost, let tab = activeRpcTab {
            tab.responseText = text
            tab.responseExpanded = responseExpanded
            tab.responseUserCollapsed = responseUserCollapsed
            renderMarkdown(in: tab.webView, text: text)
        }
        updateResponseButton()
        renderMarkdown()
        layoutViews()
    }

    private func activateRpcTab(_ tab: RpcTab) {
        if activeRpcTabID != tab.id {
            saveActiveTabState()
            activeRpcTabID = tab.id
            loadTabState(tab)
        }
        if let directory = tab.directory {
            activeDirectory = directory
        }

        if speech.isListening {
            stopVoice()
        }

        ttyPath = nil
        injector?.closeAll()
        injector = nil
        appleInjector = nil
        terminalInjector = nil

        let directory = tab.directory
        directoryPopup.title = directory.map { "📁 \($0.lastPathComponent)" }
            ?? "📁 Select project…"
        directoryPopup.toolTip = directory?.path ?? "Choose a project directory"
        window.title = "pi rpc · \(directory?.lastPathComponent ?? "New Tab")"

        if let session = tab.session {
            pidLabel.stringValue = "pi \(session.processIdentifier)"
            pidLabel.toolTip = "pi RPC child process ID \(session.processIdentifier)"
        } else if tab.exitStatus != nil {
            pidLabel.stringValue = "pi —"
            pidLabel.toolTip = nil
        } else {
            pidLabel.stringValue = ""
            pidLabel.toolTip = nil
        }

        rebuildModelMenu()
        refreshSessionRow()

        if tab.isLaunching {
            statusLabel.stringValue = "STARTING PI"
            statusLabel.textColor = .systemOrange
        } else if tab.directory == nil {
            statusLabel.stringValue = "SELECT PROJECT"
            statusLabel.textColor = .systemOrange
        } else if tab.session == nil, tab.exitStatus != nil {
            statusLabel.stringValue = "PI EXITED"
            statusLabel.textColor = .systemRed
        } else if tab.session == nil {
            statusLabel.stringValue = "NO PI SESSION"
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "READY"
            statusLabel.textColor = .systemGreen
        }

        rebuildQueryMenu()
        updateResponseButton()
        rebuildDirectoryMenu()
        rebuildTabBar()
        layoutViews()
        renderMarkdown()
        keyTape.needsDisplay = true

        // Tabs restored from tabs.conf have a directory but no child yet, so
        // start one the first time the tab is activated.
        if tab.session == nil, tab.exitStatus == nil, let directory = tab.directory {
            startRpcSession(in: tab, directory: directory, resumeLatest: true)
        }

        focusOverlay()

        debugLog("rpc tab active dir=\(directory?.path ?? "blank")")
    }

    @objc func openNewTab() {
        guard mode == .selfHost else { return }
        if isMinimized { toggleMinimize() }

        if let tab = activeRpcTab, tab.directory == nil, tab.session == nil {
            chooseDirectory()
            return
        }

        let tab = makeBlankTab()
        rpcTabs.append(tab)
        activateRpcTab(tab)
        chooseDirectory()
    }

    private func closeTab(_ tab: RpcTab) {
        guard mode == .selfHost else { return }

        let wasActive = tab.id == activeRpcTabID
        let index = rpcTabs.firstIndex(where: { $0.id == tab.id }) ?? 0

        if wasActive {
            saveActiveTabState()
        }
        removeTab(tab)

        if wasActive {
            if rpcTabs.isEmpty {
                let blank = makeBlankTab()
                rpcTabs.append(blank)
                activateRpcTab(blank)
            } else {
                let nextIndex = min(max(0, index - 1), rpcTabs.count - 1)
                activateRpcTab(rpcTabs[nextIndex])
            }
        }
        rebuildTabBar()
    }

    private func closeActiveTab() {
        guard mode == .selfHost, let tab = activeRpcTab else { return }
        closeTab(tab)
    }

    @objc private func closeTabButton(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < rpcTabs.count else { return }
        closeTab(rpcTabs[sender.tag])
    }

    private func startRpcSession(
        in tab: RpcTab,
        directory: URL,
        resumeLatest: Bool = false
    ) {
        tab.session?.stop()

        // Resume the session pinned to this tab (restored from tabs.conf) or,
        // for a restored tab without one, the newest session for the project.
        let pinned = tab.sessionFile.flatMap {
            FileManager.default.fileExists(atPath: $0) ? $0 : nil
        }
        let resumePath = pinned
            ?? (resumeLatest ? PiSessionStore.list(for: directory, limit: 1).first?.path : nil)

        tab.session = nil
        tab.directory = directory
        tab.isLaunching = true
        tab.exitStatus = nil
        tab.status = .idle
        tab.sessionFile = resumePath
        tab.sessionName = nil
        tab.assistantText = ""
        tab.streamingText = ""
        tab.latestAnswerText = ""
        tab.responseText = ""
        tab.responseExpanded = false
        tab.responseUserCollapsed = false
        tab.queries = []
        tab.selectedQueryID = nil
        activeDirectory = directory
        directoryStore.addRecent(directory)
        rebuildTabBar()

        if activeRpcTabID == tab.id {
            keyTape.agentStatus = .idle
            keyTape.needsDisplay = true
            responseText = ""
            responseExpanded = false
            responseUserCollapsed = false
            sessionQueries = []
            selectedQueryID = nil
            rebuildQueryMenu()
            statusLabel.stringValue = "STARTING PI"
            statusLabel.textColor = .systemOrange
        }

        debugLog(
            "rpc start dir=\(directory.path) session="
                + "\((resumePath as NSString?)?.lastPathComponent ?? "new")"
        )

        do {
            let session = try RpcSession.launch(in: directory, sessionFile: resumePath)
            let tabID = tab.id
            session.onEvent = { [weak self, weak session] record in
                guard let session else { return }
                self?.handleRpcEvent(record, tabID: tabID, session: session)
            }
            session.onExit = { [weak self, weak session] status in
                guard let session else { return }
                self?.handleRpcExit(tabID: tabID, session: session, status: status)
            }
            tab.session = session
            tab.isLaunching = false
            session.requestState()
            session.requestModels()
            // Load the resumed session's last answer and prompt history so the
            // response panel and query dropdown are populated immediately.
            session.requestLastAssistantText()
            session.requestEntries()

            if activeRpcTabID == tab.id {
                activateRpcTab(tab)
            } else {
                rebuildTabBar()
            }
        } catch {
            tab.isLaunching = false
            let message = error.localizedDescription
            debugLog("rpc launch failed: \(message)")

            if activeRpcTabID == tab.id {
                statusLabel.stringValue = "LAUNCH ERROR"
                statusLabel.textColor = .systemRed
                showAlert(title: "Could not start pi", message: message)
            }
            rebuildTabBar()
        }
    }

    private func switchSession(to url: URL) {
        guard let normalized = directoryStore.normalize(url.path) else {
            statusLabel.stringValue = "DIR MISSING"
            statusLabel.textColor = .systemRed
            return
        }

        let key = normalized.path
        directoryStore.addRecent(normalized)

        switch mode {
        case .selfHost:
            if let existing = rpcTabs.first(where: { $0.directory?.path == key }) {
                if let blank = activeRpcTab,
                   blank.directory == nil,
                   blank.session == nil,
                   blank.id != existing.id {
                    removeTab(blank)
                }

                activateRpcTab(existing)
                if existing.session == nil {
                    startRpcSession(in: existing, directory: normalized)
                }
                return
            }

            saveActiveTabState()

            let tab: RpcTab
            if let blank = activeRpcTab, blank.directory == nil, blank.session == nil {
                tab = blank
            } else {
                tab = makeBlankTab()
                rpcTabs.append(tab)
            }

            activateRpcTab(tab)
            startRpcSession(in: tab, directory: normalized)

        case .selfTerminal:
            activeDirectory = normalized

            if let session = terminalSessions[key] {
                activateTerminalSession(session)
                return
            }

            rebuildDirectoryMenu()
            statusLabel.stringValue = "STARTING PI"
            statusLabel.textColor = .systemOrange

            guard !pendingSessions.contains(key) else { return }
            pendingSessions.insert(key)

            launcher.launch(in: normalized) { [weak self] result in
                guard let self else { return }
                self.pendingSessions.remove(key)
                switch result {
                case .success(let session):
                    self.terminalSessions[key] = session
                    if self.activeDirectory.path == key {
                        self.activateTerminalSession(session)
                    } else {
                        self.rebuildDirectoryMenu()
                    }
                case .failure(let error):
                    debugLog("self launch failed: \(error.localizedDescription)")
                    self.statusLabel.stringValue = "LAUNCH ERROR"
                    self.statusLabel.textColor = .systemRed
                    self.targetLabel.stringValue = error.localizedDescription
                    self.rebuildDirectoryMenu()
                    self.showAlert(title: "Could not start pi", message: error.localizedDescription)
                }
            }

        default:
            break
        }
    }

    private func activateTerminalSession(_ session: PiSession) {
        activeDirectory = session.directory
        ttyPath = session.ttyPath
        injector = session.ttyPath.map { TtyInjector(path: $0) }
        appleInjector = session.ttyPath.map { AppleScriptInjector(ttyPath: $0) }
        terminalInjector = AppleScriptInjector(
            ttyPath: session.ttyPath ?? "",
            windowId: session.terminalWindowId
        )

        targetLabel.stringValue = session.ttyPath.map { "TTY \($0)" } ?? "TTY unknown"
        terminalTitleLabel.stringValue = displayPath(session.directory)
        directoryPopup.title = "📁 \(session.directory.lastPathComponent)"
        directoryPopup.toolTip = session.directory.path
        window.title = "pi · \(session.directory.lastPathComponent)"

        rawText.removeAll()
        tape.removeAll()
        // The extension may have already written the current session's
        // response and prompt history into the pipe while the overlay was
        // launching, so only clear them when switching backend modes.
        if mode != .tty {
            responseText = ""
            responseExpanded = false
            responseUserCollapsed = false
            sessionQueries = []
            selectedQueryID = nil
            latestResponseText = ""
        }
        keyTape.agentStatus = .idle
        rebuildQueryMenu()
        updateResponseButton()
        statusLabel.stringValue = "READY"
        statusLabel.textColor = .systemGreen
        rebuildDirectoryMenu()
        layoutViews()
        keyTape.needsDisplay = true
        focusOverlay()

        debugLog("terminal session active dir=\(session.directory.path) tty=\(session.ttyPath ?? "nil")")
    }

    private func handleRpcEvent(_ record: [String: Any], tabID: UUID, session: RpcSession) {
        guard let tab = rpcTab(withID: tabID),
              tab.session === session,
              let type = record["type"] as? String else { return }

        let isActive = tab.id == activeRpcTabID
        let previousStatus = tab.status

        if type == "agent_start" || type == "agent_settled" {
            debugLog("rpc event tab=\(tabTitle(tab)) type=\(type)")
        }

        switch type {
        case "agent_start":
            tab.status = .processing
            tab.assistantText = ""
            tab.streamingText = ""

        case "agent_settled":
            tab.status = .done
            let finalText = tab.assistantText.isEmpty ? tab.streamingText : tab.assistantText
            if !finalText.isEmpty {
                tab.assistantText = finalText
                tab.latestAnswerText = finalText
                if !tab.queries.isEmpty {
                    tab.queries[tab.queries.count - 1].answer = finalText
                }
            }
            if tab.selectedQueryID == nil || tab.selectedQueryID == tab.queries.last?.id {
                tab.responseText = finalText
                if !finalText.isEmpty && !tab.responseExpanded && !tab.responseUserCollapsed {
                    tab.responseExpanded = true
                }
                renderMarkdown(in: tab.webView, text: tab.responseText)
            }
            debugLog("rpc final tab=\(tabTitle(tab)) chars=\(finalText.count)")

        case "message_update":
            if let update = record["assistantMessageEvent"] as? [String: Any],
               update["type"] as? String == "text_delta",
               let delta = update["delta"] as? String {
                tab.streamingText += delta
            }

        case "message_end":
            if let message = record["message"] as? [String: Any],
               let role = message["role"] as? String {
                let text = RpcSession.messageText(from: message)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if role == "user" {
                    let id = Self.queryID(from: message, fallbackIndex: nil)
                    if !tab.queries.contains(where: { $0.id == id }) {
                        tab.queries.append(
                            SessionQuery(
                                id: id,
                                prompt: text.isEmpty ? "(image prompt)" : text,
                                answer: ""
                            )
                        )
                        if isActive {
                            sessionQueries = tab.queries
                            rebuildQueryMenu()
                            layoutViews()
                        }
                    }
                } else if role == "assistant", !text.isEmpty {
                    tab.assistantText = text
                    tab.latestAnswerText = text
                    if !tab.queries.isEmpty {
                        tab.queries[tab.queries.count - 1].answer = text
                    }
                    let latestID = tab.queries.last?.id
                    if tab.selectedQueryID == nil || tab.selectedQueryID == latestID {
                        tab.responseText = text
                        if !tab.responseExpanded && !tab.responseUserCollapsed {
                            tab.responseExpanded = true
                        }
                        renderMarkdown(in: tab.webView, text: text)
                    }
                }
            }

        case "response":
            let command = record["command"] as? String
            let success = record["success"] as? Bool ?? false
            let data = record["data"] as? [String: Any]

            if !success {
                let error = record["error"] as? String ?? "RPC command failed"
                debugLog("rpc error tab=\(tabTitle(tab)) command=\(command ?? "?"): \(error)")

                if command == "prompt" {
                    tab.status = .idle
                    if isActive {
                        statusLabel.stringValue = "RPC ERROR"
                        statusLabel.textColor = .systemRed
                    }
                } else if command == "set_model", isActive {
                    statusLabel.stringValue = "MODEL ERROR"
                    statusLabel.textColor = .systemRed
                    rebuildModelMenu()
                }
            } else {
                switch command {
                case "get_state":
                    if let model = data?["model"] as? [String: Any] {
                        tab.currentModel = model
                    }
                    if let file = data?["sessionFile"] as? String {
                        if tab.sessionFile != file {
                            tab.sessionFile = file
                            saveOpenTabs()
                        }
                    } else {
                        tab.sessionFile = nil
                    }
                    tab.sessionName = data?["sessionName"] as? String
                    if isActive {
                        rebuildModelMenu()
                        rebuildSessionMenu()
                    }

                case "switch_session":
                    debugLog(
                        "rpc switch_session tab=\(tabTitle(tab)) "
                            + "cancelled=\(data?["cancelled"] as? Bool == true) "
                            + "file=\((data?["sessionFile"] as? String).map { ($0 as NSString).lastPathComponent } ?? "-")"
                    )
                    if data?["cancelled"] as? Bool == true {
                        if isActive {
                            statusLabel.stringValue = "SWITCH CANCELED"
                            statusLabel.textColor = .systemOrange
                        }
                    } else {
                        // The conversation changed: drop the old transcript and
                        // show the resumed session's last answer instead.
                        tab.assistantText = ""
                        tab.streamingText = ""
                        tab.latestAnswerText = ""
                        tab.responseText = ""
                        tab.responseExpanded = false
                        tab.responseUserCollapsed = false
                        tab.queries = []
                        tab.selectedQueryID = nil
                        tab.status = .idle
                        session.requestState()
                        session.requestLastAssistantText()
                        session.requestEntries()
                        if isActive {
                            responseText = ""
                            responseExpanded = false
                            responseUserCollapsed = false
                            sessionQueries = []
                            selectedQueryID = nil
                            rebuildQueryMenu()
                            statusLabel.stringValue = "READY"
                            statusLabel.textColor = .systemGreen
                            keyTape.agentStatus = .idle
                            renderMarkdown()
                            layoutViews()
                            rebuildSessionMenu()
                        }
                    }

                case "new_session":
                    debugLog(
                        "rpc new_session tab=\(tabTitle(tab)) "
                            + "cancelled=\(data?["cancelled"] as? Bool == true)"
                    )
                    if data?["cancelled"] as? Bool == true {
                        if isActive {
                            statusLabel.stringValue = "NEW SESSION CANCELED"
                            statusLabel.textColor = .systemOrange
                        }
                    } else {
                        tab.assistantText = ""
                        tab.streamingText = ""
                        tab.latestAnswerText = ""
                        tab.responseText = ""
                        tab.responseExpanded = false
                        tab.responseUserCollapsed = false
                        tab.queries = []
                        tab.selectedQueryID = nil
                        tab.status = .idle
                        tab.sessionName = nil
                        tab.sessionFile = nil
                        session.requestState()
                        session.requestLastAssistantText()
                        session.requestEntries()
                        if isActive {
                            responseText = ""
                            responseExpanded = false
                            responseUserCollapsed = false
                            latestResponseText = ""
                            sessionQueries = []
                            selectedQueryID = nil
                            rebuildQueryMenu()
                            updateResponseButton()
                            statusLabel.stringValue = "READY"
                            statusLabel.textColor = .systemGreen
                            keyTape.agentStatus = .idle
                            renderMarkdown()
                            layoutViews()
                            rebuildSessionMenu()
                        }
                        refreshSessionRow()
                    }

                case "get_last_assistant_text":
                    if let text = data?["text"] as? String, !text.isEmpty {
                        tab.assistantText = text
                        tab.latestAnswerText = text
                        if tab.selectedQueryID == nil {
                            tab.responseText = text
                            if !tab.responseExpanded && !tab.responseUserCollapsed {
                                tab.responseExpanded = true
                            }
                            renderMarkdown(in: tab.webView, text: text)
                        }
                        if isActive {
                            responseText = tab.responseText
                            responseExpanded = tab.responseExpanded
                            updateResponseButton()
                            renderMarkdown()
                            layoutViews()
                        }
                    }

                case "get_entries":
                    let entries = data?["entries"] as? [[String: Any]] ?? []
                    let messages = Self.activeBranch(
                        from: entries,
                        leafId: data?["leafId"] as? String
                    ).compactMap { $0["message"] as? [String: Any] }
                    if !entries.isEmpty || data?["leafId"] != nil {
                        tab.queries = Self.buildQueries(from: messages)
                        if let id = tab.selectedQueryID,
                           !tab.queries.contains(where: { $0.id == id }) {
                            tab.selectedQueryID = nil
                        }
                        if let id = tab.selectedQueryID,
                           let query = tab.queries.first(where: { $0.id == id }) {
                            tab.responseText = query.answer
                        } else if let latest = tab.queries.last?.answer, !latest.isEmpty {
                            tab.assistantText = latest
                            tab.latestAnswerText = latest
                            tab.responseText = latest
                            if !tab.responseExpanded && !tab.responseUserCollapsed {
                                tab.responseExpanded = true
                            }
                        }
                        renderMarkdown(in: tab.webView, text: tab.responseText)
                        if isActive {
                            sessionQueries = tab.queries
                            selectedQueryID = tab.selectedQueryID
                            rebuildQueryMenu()
                            renderMarkdown()
                            layoutViews()
                        }
                        debugLog(
                            "rpc queries tab=\(tabTitle(tab)) count=\(tab.queries.count) "
                                + "selected=\(tab.selectedQueryID ?? "latest")"
                        )
                    }

                case "get_available_models":
                    if let models = data?["models"] as? [[String: Any]] {
                        tab.models = models
                        if isActive {
                            rebuildModelMenu()
                        }
                    }

                case "set_model":
                    if let model = data {
                        tab.currentModel = model
                        if isActive {
                            rebuildModelMenu()
                            statusLabel.stringValue = "READY"
                            statusLabel.textColor = .systemGreen
                        }
                    }

                case "prompt":
                    if data?["disposition"] as? String == "handled" {
                        tab.status = .idle
                    }

                default:
                    break
                }
            }

        case "extension_ui_request":
            handleRpcExtensionRequest(record, tabID: tabID)

        default:
            break
        }

        if isActive {
            responseText = tab.responseText
            responseExpanded = tab.responseExpanded
            responseUserCollapsed = tab.responseUserCollapsed
            sessionQueries = tab.queries
            selectedQueryID = tab.selectedQueryID
            keyTape.agentStatus = tab.status
            keyTape.needsDisplay = true
            updateResponseButton()

            if type == "message_end" || type == "agent_settled" {
                layoutViews()
                renderMarkdown()
            }
            if type == "agent_settled" {
                refreshSessionRow()
            }
            if tab.status != previousStatus {
                rebuildTabBar()
            }
        } else if tab.status != previousStatus {
            rebuildTabBar()
        }
        updateStatusItem()
    }

    private func handleRpcExit(tabID: UUID, session: RpcSession, status: Int32) {
        guard let tab = rpcTab(withID: tabID),
              tab.session === session else { return }

        tab.session = nil
        tab.status = .idle
        tab.exitStatus = status

        if tab.id == activeRpcTabID {
            keyTape.agentStatus = .idle
            keyTape.needsDisplay = true
            statusLabel.stringValue = "PI EXITED (\(status))"
            statusLabel.textColor = .systemRed
            pidLabel.stringValue = "pi —"
            pidLabel.toolTip = nil
            modelPopup.isEnabled = false
            modelPopup.toolTip = "pi exited"

            if status != 0 {
                let detail = session.recentStderr()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty {
                    showAlert(
                        title: "pi exited (\(status))",
                        message: String(detail.suffix(1500))
                    )
                }
            }
        }

        rebuildTabBar()
        rebuildDirectoryMenu()
        updateStatusItem()
    }

    private func handleRpcExtensionRequest(_ request: [String: Any], tabID: UUID) {
        let method = request["method"] as? String ?? ""
        switch method {
        case "setTitle":
            if tabID == activeRpcTabID,
               let title = request["title"] as? String,
               !title.isEmpty {
                window.title = title
            }
        case "notify":
            if let message = request["message"] as? String {
                debugLog("rpc notify[\(tabID)]: \(message)")
            }
        case "confirm", "select", "input", "editor":
            dialogQueue.append((tabID, request))
            showNextRpcDialog()
        default:
            break
        }
    }

    private func showNextRpcDialog() {
        guard !dialogVisible, !dialogQueue.isEmpty, mode == .selfHost else { return }

        if window.attachedSheet != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showNextRpcDialog()
            }
            return
        }

        let item = dialogQueue.removeFirst()
        guard let tab = rpcTab(withID: item.tabID),
              let session = tab.session else {
            showNextRpcDialog()
            return
        }

        let request = item.request
        guard let id = request["id"] as? String else { return }
        let method = request["method"] as? String ?? ""

        let alert = NSAlert()
        alert.messageText = request["title"] as? String ?? "pi"
        var infoParts: [String] = []
        if let message = request["message"] as? String, !message.isEmpty {
            infoParts.append(message)
        }
        infoParts.append("Session: \(tab.directory.map { displayPath($0) } ?? "New Tab")")
        alert.informativeText = infoParts.joined(separator: "\n\n")
        alert.alertStyle = .informational

        var popup: NSPopUpButton?
        var textField: NSTextField?
        var textView: NSTextView?

        switch method {
        case "confirm":
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

        case "select":
            let options = request["options"] as? [String] ?? []
            let picker = NSPopUpButton(
                frame: NSRect(x: 0, y: 0, width: 280, height: 26),
                pullsDown: false
            )
            picker.addItems(withTitles: options)
            alert.accessoryView = picker
            popup = picker
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

        case "input":
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = request["placeholder"] as? String ?? ""
            alert.accessoryView = field
            textField = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

        case "editor":
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
            editor.isRichText = false
            editor.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            editor.string = request["prefill"] as? String ?? ""
            editor.isVerticallyResizable = true
            editor.autoresizingMask = [.width]
            scroll.documentView = editor
            alert.accessoryView = scroll
            textView = editor
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

        default:
            session.cancelExtensionUI(id: id)
            showNextRpcDialog()
            return
        }

        dialogVisible = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.dialogVisible = false
            defer { self.showNextRpcDialog() }

            if response == .alertFirstButtonReturn {
                switch method {
                case "confirm":
                    session.respondExtensionUI(id: id, confirmed: true)
                case "select":
                    session.respondExtensionUI(id: id, value: popup?.titleOfSelectedItem ?? "")
                case "input":
                    session.respondExtensionUI(id: id, value: textField?.stringValue ?? "")
                case "editor":
                    session.respondExtensionUI(id: id, value: textView?.string ?? "")
                default:
                    break
                }
            } else if response == .alertSecondButtonReturn {
                if method == "confirm" {
                    session.respondExtensionUI(id: id, confirmed: false)
                } else {
                    session.cancelExtensionUI(id: id)
                }
            } else {
                session.cancelExtensionUI(id: id)
            }
            self.focusOverlay()
        }
    }

    @objc private func restartActiveSession() {
        guard mode == .selfHost,
              let tab = activeRpcTab,
              let directory = tab.directory else { return }
        tab.exitStatus = nil
        startRpcSession(in: tab, directory: directory, resumeLatest: true)
    }

    @objc private func closeActiveSession() {
        if mode == .selfHost {
            closeActiveTab()
            return
        }

        let key = activeDirectory.path
        guard mode == .selfTerminal,
              let session = terminalSessions.removeValue(forKey: key) else { return }
        launcher.close(session)
        resetActiveSessionUI()
    }

    private func resetActiveSessionUI() {
        injector?.closeAll()
        injector = nil
        appleInjector = nil
        terminalInjector = nil
        ttyPath = nil
        statusLabel.stringValue = "NO PI SESSION"
        statusLabel.textColor = .systemOrange
        targetLabel.stringValue = "NO SESSION"
        pidLabel.stringValue = ""
        pidLabel.toolTip = nil
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: "Model…")
        modelPopup.isEnabled = false
        modelPopup.toolTip = "Model for this pi RPC session"
        rawText.removeAll()
        tape.removeAll()
        responseText = ""
        responseExpanded = false
        responseUserCollapsed = false
        keyTape.agentStatus = .idle
        updateResponseButton()
        rebuildDirectoryMenu()
        layoutViews()
        renderMarkdown()
        keyTape.needsDisplay = true
        focusOverlay()
    }

    private func sendToActiveSession(_ text: String) -> Bool {
        if mode == .selfHost {
            guard let tab = activeRpcTab,
                  let session = tab.session,
                  session.isRunning else {
                statusLabel.stringValue = "NO PI SESSION"
                statusLabel.textColor = .systemRed
                return false
            }
            guard session.prompt(text) else {
                statusLabel.stringValue = "SEND ERROR"
                statusLabel.textColor = .systemRed
                return false
            }

            tab.status = .processing
            tab.rawText = ""
            tab.tape = []
            // A new question returns the viewer to the latest answer; the
            // prompt itself appears in the dropdown via message_end.
            tab.selectedQueryID = nil
            selectedQueryID = nil
            tab.responseText = tab.latestAnswerText.isEmpty
                ? tab.streamingText
                : tab.latestAnswerText
            responseText = tab.responseText
            rebuildQueryMenu()
            layoutViews()
            keyTape.agentStatus = .processing
            keyTape.needsDisplay = true
            rebuildTabBar()
            return true
        }

        guard terminalSessions[activeDirectory.path] != nil else {
            statusLabel.stringValue = "NO PI SESSION"
            statusLabel.textColor = .systemRed
            return false
        }

        // Fast path: only works when the overlay shares the controlling TTY.
        if let tty = ttyPath, tty == controllingTTY(), let inj = injector {
            if inj.inject(text + "\r") {
                return true
            }
            debugLog("self tty inject failed: \(inj.lastError)")
        }

        // Primary path for GUI-launched overlays.
        if let inj = terminalInjector, inj.sendTerminalScript(text) {
            focusOverlay()
            return true
        }

        // Last resort: type into the frontmost Terminal window.
        if let inj = terminalInjector, inj.activateWindow() {
            let ok = inj.sendText(text)
            if ok {
                _ = inj.sendKey(36)
            }
            focusOverlay()
            return ok
        }

        return false
    }

    func shutdown() {
        injector?.closeAll()
        for tab in rpcTabs {
            tab.session?.stop()
            tab.session = nil
        }
        for runtime in profileRuntime.values {
            for tab in runtime.tabs {
                tab.session?.stop()
                tab.session = nil
            }
        }
        profileRuntime.removeAll()
        pendingSessions.removeAll()
        dialogQueue.removeAll()
    }

    private func focusOverlay() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        keyTape.focusTextView()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private static func markdownHTML() -> String {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let jsURL = exeDir.appendingPathComponent("markdown-it.min.js")
        let js = (try? String(contentsOf: jsURL, encoding: .utf8)) ?? ""

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        :root { color-scheme: light; }
        html, body { margin: 0; padding: 0; background: #ffffff; color: #111827; }
        body { font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
        #content { padding: 10px 12px 14px; }
        h1, h2, h3, h4 { margin: 0.75em 0 0.35em; line-height: 1.2; color: #0f172a; }
        h1 { font-size: 1.45em; }
        h2 { font-size: 1.25em; }
        h3 { font-size: 1.1em; }
        p { margin: 0.5em 0; line-height: 1.5; }
        ul, ol { margin: 0.5em 0; padding-left: 1.5em; }
        li { margin: 0.15em 0; }
        table { border-collapse: collapse; width: 100%; margin: 0.65em 0; font-size: 12px; }
        th, td { border: 1px solid #dbe3ee; padding: 5px 7px; text-align: left; vertical-align: top; }
        th { background: #f1f5f9; font-weight: 600; }
        code { font-family: ui-monospace, Menlo, monospace; background: #f3f4f6; padding: 1px 4px; border-radius: 4px; }
        pre { background: #0f172a; color: #e5e7eb; padding: 10px 12px; border-radius: 8px; overflow: auto; }
        pre code { background: none; padding: 0; color: inherit; }
        blockquote { margin: 0.6em 0; padding: 0.1em 0.8em; border-left: 3px solid #cbd5e1; color: #475569; }
        a { color: #2563eb; text-decoration: none; }
        a:hover { text-decoration: underline; }
        hr { border: none; border-top: 1px solid #e2e8f0; margin: 0.9em 0; }
        </style>
        <script>\(js)</script>
        </head>
        <body>
        <div id="content"></div>
        <script>
        const md = window.markdownit
          ? window.markdownit({ html: false, linkify: true, typographer: true, breaks: true })
          : null;
        window.renderMarkdown = function(text) {
          const content = document.getElementById('content');
          if (md) {
            content.innerHTML = md.render(text || '');
          } else {
            content.textContent = text || '';
          }
        };
        </script>
        </body>
        </html>
        """
    }

    private func renderMarkdown(in webView: WKWebView, text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
              let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("renderMarkdown(\(literal));", completionHandler: nil)
    }

    private func renderMarkdown() {
        if mode == .selfHost {
            guard let tab = activeRpcTab else { return }
            renderMarkdown(in: tab.webView, text: tab.responseText)
        } else {
            renderMarkdown(in: responseWebView, text: responseText)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = rpcTabs.first(where: { $0.webView === webView }) {
            renderMarkdown(in: webView, text: tab.responseText)
        } else {
            renderMarkdown(in: webView, text: responseText)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func startIPCReader() {
        // Only read stdin when it is a pipe (the pi extension); do not steal
        // keyboard input when launched manually from a terminal.
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)

                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(0...newline)

                    guard !line.isEmpty,
                          let object = try? JSONSerialization.jsonObject(with: Data(line)),
                          let event = object as? [String: Any] else { continue }

                    DispatchQueue.main.async {
                        self?.handleIPCEvent(event)
                    }
                }
            }
        }
    }

    private func handleIPCEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        switch type {
        case "status":
            let value = (event["value"] as? String)?.lowercased() ?? ""
            let next: KeyTapeView.AgentStatus
            if value == "processing" {
                next = .processing
            } else if value == "done" {
                next = .done
            } else {
                next = .idle
            }
            if keyTape.agentStatus != next {
                keyTape.agentStatus = next
                keyTape.needsDisplay = true
            }

        case "response":
            let text = (event["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isNewAnswer = text != latestResponseText
            latestResponseText = text
            if selectedQueryID == nil {
                responseText = text
                if text.isEmpty {
                    responseExpanded = false
                    responseUserCollapsed = false
                } else {
                    // Show the latest answer by default. A manual collapse is
                    // kept for the answer the user collapsed, but a fresh
                    // answer re-opens the panel.
                    if isNewAnswer { responseUserCollapsed = false }
                    responseExpanded = !responseUserCollapsed
                }
            }
            updateResponseButton()
            layoutViews()
            renderMarkdown()

        case "queries":
            let items = event["items"] as? [[String: Any]] ?? []
            sessionQueries = items.compactMap { item in
                guard let id = item["id"] as? String,
                      let prompt = item["prompt"] as? String else { return nil }
                return SessionQuery(
                    id: id,
                    prompt: prompt,
                    answer: item["answer"] as? String ?? ""
                )
            }
            rebuildQueryMenu()
            applyQuerySelection(expand: false)

        default:
            break
        }
    }

    private func updateResponseButton() {
        responseButton.isHidden = isMinimized || responseText.isEmpty
        responseButton.title = responseExpanded ? "Response ▾" : "Response ▸"
    }

    private func updateMinimizeButton() {
        let symbol = isMinimized ? "chevron.up" : "chevron.down"
        let description = isMinimized ? "Restore overlay" : "Minimize overlay"
        if let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: description
        ) {
            minimizeButton.image = image
            minimizeButton.title = ""
        } else {
            // Fallback for a missing SF Symbol: keep a visible text chevron.
            minimizeButton.image = nil
            minimizeButton.title = isMinimized ? "▴" : "▾"
        }
        minimizeButton.toolTip = isMinimized
            ? "Restore the overlay (Cmd+M)"
            : "Minimize to the tab strip (Cmd+M)"
        minimizeButton.setAccessibilityLabel(description)
    }

    private func updateMaximizeButton() {
        let maximized = isMaximizedWindow
        let symbol = maximized
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        let description = maximized ? "Restore window" : "Maximize window"
        if let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: description
        ) {
            maximizeButton.image = image
            maximizeButton.title = ""
        } else {
            maximizeButton.image = nil
            maximizeButton.title = maximized ? "⤡" : "⤢"
        }
        maximizeButton.toolTip = maximized
            ? "Restore the overlay window"
            : "Maximize — fills the screen, keeps the menu bar, and leaves overlay mode"
        maximizeButton.setAccessibilityLabel(description)
    }

    /// Maximizes like the green zoom button: fills the screen's *visible* frame
    /// so the menu bar and Dock stay usable. It also leaves overlay mode (normal
    /// window level, current space only) instead of entering a fullscreen space.
    @objc func toggleMaximize() {
        if isMaximizedWindow {
            restoreWindow()
        } else {
            maximizeWindow()
        }
    }

    private func maximizeWindow() {
        if isMinimized { toggleMinimize() }
        if window.attachedSheet != nil { return }

        maximizeRestoreLevel = window.level
        maximizeRestoreBehavior = window.collectionBehavior
        maximizeWasMovable = window.isMovableByWindowBackground

        window.level = .normal
        window.collectionBehavior = []
        window.isMovableByWindowBackground = false
        // Do not let the maximized geometry overwrite the saved compact overlay
        // frame; it is restored when we leave maximize.
        window.setFrameAutosaveName("")

        let screen = window.screen ?? NSScreen.main
        let target = screen?.visibleFrame ?? window.frame
        window.setFrame(target, display: true, animate: true)

        window.contentView?.layer?.cornerRadius = 0
        window.contentView?.layer?.borderWidth = 0
        isMaximizedWindow = true
        updateMaximizeButton()
        layoutViews()
        debugLog("maximize frame=\(NSStringFromRect(window.frame)) level=\(window.level.rawValue)")
    }

    /// Leaves maximize and re-activates overlay mode (floating level, all-spaces
    /// behavior). The window returns to its compact default frame, anchored to
    /// the bottom of the visible screen so the textbox and answer fit there.
    private func exitMaximize(animated: Bool) {
        guard isMaximizedWindow else { return }
        isMaximizedWindow = false
        window.level = maximizeRestoreLevel
        window.collectionBehavior = maximizeRestoreBehavior
        window.isMovableByWindowBackground = maximizeWasMovable
        window.setFrame(defaultOverlayFrame, display: true, animate: animated)
        window.contentView?.layer?.cornerRadius = 10
        window.contentView?.layer?.borderWidth = 1.4
        updateMaximizeButton()
        // Re-enable frame autosave once the restore animation has settled, so an
        // intermediate (still large) frame is never what gets saved.
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isMaximizedWindow else { return }
                self.window.setFrameAutosaveName("PiOverlayWindow")
            }
        } else {
            window.setFrameAutosaveName("PiOverlayWindow")
        }
        debugLog("restore compact frame=\(NSStringFromRect(window.frame))")
    }

    private func restoreWindow() {
        exitMaximize(animated: true)
        layoutViews()
        focusOverlay()
        debugLog("restore frame=\(NSStringFromRect(window.frame)) level=\(window.level.rawValue)")
    }

    @objc func toggleMinimize() {
        // Collapsing a maximized window must bring back overlay mode first, so
        // the collapsed strip and its restore size use the overlay geometry.
        if !isMinimized, isMaximizedWindow {
            exitMaximize(animated: false)
            debugLog("collapse from maximize -> overlay frame=\(NSStringFromRect(window.frame))")
        }

        isMinimized.toggle()
        window.minSize = isMinimized ? NSSize(width: 300, height: collapsedHeight) : baseMinSize

        var frame = window.frame
        let target: CGFloat
        if isMinimized {
            expandedHeight = frame.height
            target = collapsedHeight
        } else {
            target = max(
                expandedHeight,
                window.frame.height,
                baseMinSize.height,
                responseExpanded ? comfortableHeight : 0
            )
        }

        frame.size.height = target
        frame.origin.y = window.frame.maxY - target   // keep the top edge pinned
        // The width is free to shrink while collapsed; restore a usable one.
        if !isMinimized { frame.size.width = max(frame.size.width, baseMinSize.width) }
        window.setFrame(frame, display: true)

        updateMinimizeButton()

        layoutViews()
        keyTape.needsDisplay = true
        focusOverlay()
    }

    @objc func toggleResponse() {
        guard !responseText.isEmpty else { return }
        responseExpanded.toggle()
        responseUserCollapsed = !responseExpanded
        if mode == .selfHost, let tab = activeRpcTab {
            tab.responseExpanded = responseExpanded
            tab.responseUserCollapsed = responseUserCollapsed
        }
        updateResponseButton()
        layoutViews()
    }

    private static let responsePanelHeight: CGFloat = 160

    /// Height the key tape keeps while the response panel is open. Extra
    /// window height from scaling the overlay goes to the response panel
    /// instead of stretching the textbox.
    private static let keyTapeBaseHeight: CGFloat = 128

    /// Height at which the key tape keeps its normal size with the response
    /// panel open. Growing to this once (instead of on every toggle) keeps the
    /// window size predictable and avoids drift between launches.
    private var comfortableHeight: CGFloat {
        (mode == .selfHost ? 258 : 198) + Self.responsePanelHeight
    }

    /// Height reserved under the header row for the saved-session list.
    private static let sessionRowHeight: CGFloat = 24
    private var sessionRowExtra: CGFloat { mode == .selfHost ? 30 : 0 }

    /// The user owns the window height. The only adjustment made here is to
    /// make room for the response panel when the window is too short for it.
    private func syncResponsePanelHeight() {
        guard responseExpanded, !isMinimized else { return }
        var frame = window.frame
        let target = max(comfortableHeight, window.minSize.height)
        guard frame.height < target else { return }

        let delta = target - frame.height
        frame.size.height = target
        frame.origin.y -= delta          // keep the top edge pinned
        window.setFrame(frame, display: true)
    }

    /// Lays out against the window's *current* size. The window height is owned
    /// by the user (resize handles), so nothing here resizes it except making
    /// room for the response panel.
    private func layoutViews() {
        guard let container = window.contentView else { return }
        syncResponsePanelHeight()

        let width = container.bounds.width
        let height = container.bounds.height
        let tabBarExtra: CGFloat = mode == .selfHost ? 30 : 0
        let headerBase = height - tabBarExtra
        // In RPC mode the collapsed window shows only the tab strip, so the
        // header contents go away. The × and ▾ buttons stay in the tab strip.
        let collapseHeader = isMinimized && mode == .selfHost

        let textY: CGFloat = 8
        let sessionRow = sessionRowExtra
        let responseVisible = responseExpanded && !isMinimized
        let textHeight: CGFloat
        if responseVisible {
            // Keep the textbox at its base height and give every extra point
            // of window height to the Markdown response panel. The 28pt is the
            // Response button row (4pt gap + 24pt button) between them.
            let keyTop = headerBase - 34 - sessionRow
            let verticalSpace = max(0, keyTop - textY)
            textHeight = max(
                Self.responsePanelHeight,
                verticalSpace - 28 - Self.keyTapeBaseHeight
            )
        } else {
            textHeight = 0
        }
        let headerY = textY + textHeight + 4
        let keyY = headerY + 24

        let topRowY = height - 29
        let headerRowY = headerBase - 28
        // Right cluster is [▾] [⤢] [×]. In RPC mode the window controls live in
        // the tab strip so they stay reachable when collapsed.
        let windowControlY = mode == .selfHost ? topRowY : headerRowY
        statusLabel.frame = NSRect(x: 16, y: headerBase - 26, width: 120, height: 20)
        closeButton.frame = NSRect(x: width - 36, y: windowControlY, width: 28, height: 24)
        maximizeButton.frame = NSRect(x: width - 70, y: windowControlY, width: 28, height: 24)
        minimizeButton.frame = NSRect(x: width - 104, y: windowControlY, width: 28, height: 24)

        // Left edge of the right-hand control cluster, leaving room for the PID.
        let controlsRight = width - 272

        if isSelfMode {
            let middle = max(200, controlsRight - 138)
            let dirWidth = max(110, middle * 0.5)
            let modelWidth = max(130, middle - dirWidth - 8)
            directoryPopup.frame = NSRect(x: 138, y: headerBase - 28, width: dirWidth, height: 24)
            modelPopup.frame = NSRect(
                x: 138 + dirWidth + 8,
                y: headerBase - 28,
                width: modelWidth,
                height: 24
            )
            pidLabel.frame = NSRect(x: controlsRight, y: headerBase - 25, width: 70, height: 18)
        } else {
            targetLabel.frame = NSRect(x: 138, y: headerBase - 25, width: 150, height: 18)
            terminalTitleLabel.frame = NSRect(
                x: 296,
                y: headerBase - 24,
                width: max(60, width - 236 - 296),
                height: 16
            )
        }
        targetLabel.isHidden = isSelfMode || collapseHeader
        terminalTitleLabel.isHidden = isSelfMode || collapseHeader
        directoryPopup.isHidden = !isSelfMode || collapseHeader
        modelPopup.isHidden = mode != .selfHost || collapseHeader
        pidLabel.isHidden = mode != .selfHost || collapseHeader
        statusLabel.isHidden = collapseHeader
        closeButton.isHidden = false
        maximizeButton.isHidden = false

        // The textbox is never visible while collapsed, but it stays in the
        // window (transparent, not hidden) so it remains first responder and
        // the Option/Ctrl/Cmd chords keep working.
        keyTape.alphaValue = isMinimized ? 0 : 1

        // Saved sessions row, directly under the header row and above the
        // textbox. Only RPC mode has one.
        sessionLabel.isHidden = sessionRow == 0 || collapseHeader
        sessionPopup.isHidden = sessionRow == 0 || collapseHeader
        newSessionButton.isHidden = sessionRow == 0 || collapseHeader
        if sessionRow > 0 {
            let rowBottom = headerBase - 34 - Self.sessionRowHeight
            sessionLabel.frame = NSRect(
                x: 12,
                y: rowBottom + Self.sessionRowHeight - 14,
                width: 54,
                height: 12
            )
            sessionPopup.frame = NSRect(
                x: 70,
                y: rowBottom,
                width: min(max(200, width - 82), 420),
                height: Self.sessionRowHeight
            )
            newSessionButton.frame = NSRect(
                x: sessionPopup.frame.maxX + 6,
                y: rowBottom,
                width: 28,
                height: Self.sessionRowHeight
            )
        }

        // With the response panel closed, the key tape is the flexible area.
        // With it open, the panel has already taken the extra height above, so
        // this settles at its base height.
        let keyTop = headerBase - 34 - sessionRow
        keyTape.frame = NSRect(x: 10, y: keyY, width: width - 20, height: max(56, keyTop - keyY))

        // Speak button: bottom-left inside the textbox, with a little padding.
        let micSize: CGFloat = 22
        voiceButton.frame = NSRect(
            x: 12,
            y: keyTape.bounds.height - micSize - 10,
            width: micSize,
            height: micSize
        )

        // Response toggle and prompt-history dropdown share the row between
        // the textbox and the response panel.
        let responseToggleVisible = !isMinimized && !responseText.isEmpty
        responseButton.frame = NSRect(x: 16, y: headerY, width: 140, height: 20)
        let queryX: CGFloat = responseToggleVisible ? 16 + 148 : 16
        queryPopup.frame = NSRect(
            x: queryX,
            y: headerY - 1,
            width: max(CGFloat(120), width - 16 - queryX),
            height: 24
        )
        queryPopup.isHidden = isMinimized || sessionQueries.isEmpty

        tabBar.frame = NSRect(
            x: 4,
            y: height - 30,
            width: width - 8,
            height: 28
        )
        tabBar.isHidden = mode != .selfHost
        let profileWidth: CGFloat = 140
        profilePopup.frame = NSRect(x: 4, y: 1, width: profileWidth, height: 24)
        profilePopup.isHidden = mode != .selfHost
        tabScrollView.frame = NSRect(
            x: profileWidth + 8,
            y: 0,
            width: max(40, tabBar.frame.width - profileWidth - 8 - 140),
            height: 26
        )
        newTabButton.frame = NSRect(
            x: tabBar.frame.width - 132,
            y: 1,
            width: 26,
            height: 24
        )
        // The window controls sit to the right of the tab strip in RPC mode;
        // their frames are set above alongside the header row.

        if mode == .selfHost {
            responseWebView.isHidden = true
            for tab in rpcTabs {
                tab.webView.frame = NSRect(
                    x: 10,
                    y: textY,
                    width: width - 20,
                    height: textHeight
                )
                tab.webView.isHidden = isMinimized || !(tab.id == activeRpcTabID && responseExpanded)
            }
        } else {
            responseWebView.frame = NSRect(
                x: 10,
                y: textY,
                width: width - 20,
                height: textHeight
            )
            responseWebView.isHidden = isMinimized || !responseExpanded
        }

        window.invalidateCursorRects(for: container)
        updateResponseButton()
    }

    private static func appendText(_ base: String, _ addition: String) -> String {
        let add = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if add.isEmpty { return base }
        if base.isEmpty { return add }
        if add.hasPrefix(base) { return add }
        return base + " " + add
    }

    @objc func toggleVoice() {
        if speech.isListening {
            stopVoice()
            return
        }
        startVoice()
    }

    private func startVoice() {
        if isMinimized { toggleMinimize() }
        statusLabel.stringValue = "MIC PERMISSION"
        statusLabel.textColor = .systemOrange
        updateVoiceButton(listening: true)

        speech.onTranscript = { [weak self] text, final in
            guard let self else { return }

            if final {
                self.voiceBase = Self.appendText(self.voiceBase, text)
                self.voicePartial = ""
                self.rawText = self.voiceBase
                self.keyTape.needsDisplay = true
                self.stopVoice()
                return
            }

            // Keep partial transcription append-only. If the recognizer
            // starts a new chunk instead of extending the current one,
            // commit the previous partial before showing the new chunk.
            if self.voicePartial.isEmpty || text.hasPrefix(self.voicePartial) {
                self.voicePartial = text
            } else {
                self.voiceBase = Self.appendText(self.voiceBase, self.voicePartial)
                self.voicePartial = text
            }

            self.rawText = Self.appendText(self.voiceBase, self.voicePartial)
            self.keyTape.needsDisplay = true
        }

        speech.onError = { [weak self] message in
            guard let self else { return }
            debugLog("speech error: \(message)")
            self.statusLabel.stringValue = "VOICE ERROR"
            self.statusLabel.textColor = .systemRed
            self.stopVoice()
        }

        speech.requestPermissions { [weak self] granted in
            guard let self else { return }
            if !granted {
                self.statusLabel.stringValue = "MIC DENIED"
                self.statusLabel.textColor = .systemRed
                self.updateVoiceButton(listening: false)
                return
            }

            self.voiceBase = self.rawText
            self.voicePartial = ""
            if !self.voiceBase.isEmpty && !self.voiceBase.hasSuffix(" ") {
                self.voiceBase += " "
            }

            self.statusLabel.stringValue = "LISTENING"
            self.statusLabel.textColor = .systemRed
            self.updateVoiceButton(listening: true)
            self.speech.start()
            if !self.speech.isListening {
                self.stopVoice()
            }
        }
    }

    private func stopVoice() {
        speech.stop()
        voicePartial = ""
        updateVoiceButton(listening: false)
        showIdleStatus()
        keyTape.needsDisplay = true
    }

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let cleaned = text.trimmingCharacters(in: .newlines)
        guard !cleaned.isEmpty else { return }
        // Insert at the caret, replacing any selection.
        keyTape.insert(cleaned)
        keyTape.needsDisplay = true
    }

    @objc func closeApp() {
        shutdown()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        shutdown()
    }

    func windowDidResize(_ notification: Notification) {
        if !isMinimized { expandedHeight = window.frame.height }
        layoutViews()
    }

    // MARK: - Prompt box key handling

    /// Cmd chords the overlay owns. Returns true when the chord was consumed;
    /// anything else falls through to the text view (copy, select all, undo…).
    func handlePromptKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased()

        if chars == "q" {
            closeApp()
            return true
        }

        // Cmd+M: collapse to the tab strip / restore.
        if chars == "m" {
            toggleMinimize()
            return true
        }

        // Cmd+V: paste through the clipboard cleaner, at the caret.
        if event.keyCode == 9 {
            pasteFromClipboard()
            return true
        }

        // Cmd+1…9: jump to the Nth tab (RPC self mode).
        if mode == .selfHost, let number = Self.tabNumber(for: event.keyCode) {
            if number <= rpcTabs.count {
                activateRpcTab(rpcTabs[number - 1])
            }
            return true
        }

        return false
    }

    /// Window-level keys for the prompt box. Returns true when the key was
    /// consumed, false to let the text view handle it natively (typing, arrows,
    /// selection, undo, …).
    func handlePromptKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.command), handlePromptKeyEquivalent(event) { return true }

        // Ctrl chords.
        if mods.contains(.control) {
            // Ctrl+N: choose a working directory for a pi session (self mode).
            if event.keyCode == 45 || event.charactersIgnoringModifiers?.lowercased() == "n" {
                chooseDirectory()
                return true
            }
            // Ctrl+T / Ctrl+W: new tab / close tab (RPC self mode).
            if mode == .selfHost {
                let chars = event.charactersIgnoringModifiers?.lowercased()
                if event.keyCode == 17 || chars == "t" {
                    openNewTab()
                    return true
                }
                if event.keyCode == 13 || chars == "w" {
                    closeActiveTab()
                    return true
                }
            }
            return false
        }

        // Option+V: start/stop voice input.
        if mods.contains(.option), event.keyCode == 9 {
            toggleVoice()
            return true
        }

        // Escape aborts a running RPC turn (self mode).
        if event.keyCode == 53 {
            if mode == .selfHost, let session = activeRpcTab?.session, session.isStreaming {
                session.abort()
                return true
            }
            return false
        }

        // While collapsed there is no visible textbox, so plain keys are
        // swallowed; the chords above keep working.
        if isMinimized { return true }

        // Return sends the prompt; Shift+Return is a real line break.
        guard event.keyCode == 36 || event.keyCode == 52 || event.keyCode == 76 else {
            return false
        }
        if mods.contains(.shift) { return false }
        sendPrompt()
        return true
    }

    private static func tabNumber(for keyCode: UInt16) -> Int? {
        [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
            22: 6, 26: 7, 28: 8, 25: 9,
        ][Int(keyCode)]
    }

    /// Called by the text box whenever the user edits the prompt.
    func promptTextChanged(_ text: String) {
        if rawText != text { rawText = text }
    }

    /// Sends the pending prompt through the active backend and clears the box
    /// when the send succeeded.
    private func sendPrompt() {
        if speech.isListening {
            stopVoice()
        }

        // The text view is authoritative for what the user typed.
        let chunk = keyTape.text
        if rawText != chunk { rawText = chunk }

        var sentOk = true
        if isSelfMode {
            sentOk = sendToActiveSession(chunk)
        } else if mode == .tty, let inj = injector {
            sentOk = inj.inject(chunk + "\r")
        } else if mode == .terminal, let inj = terminalInjector {
            sentOk = inj.sendTerminalScript(chunk)
        } else if mode == .apple, let inj = appleInjector {
            sentOk = inj.sendText(chunk) && inj.sendKey(36)
        }

        if sentOk {
            sentBytes += chunk.utf8.count
            tape.removeAll()
            rawText.removeAll()
        } else {
            statusLabel.stringValue = "SEND ERROR"
            statusLabel.textColor = .systemRed
        }

        keyTape.needsDisplay = true
    }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: OverlayController
    init(controller: OverlayController) { self.controller = controller }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
        controller.keyTape.focusTextView()
        controller.keyTape.needsDisplay = true
        controller.startInitialSelfSession()
        controller.prepareInput()
        controller.installStatusItem()

        // App-level key/flag monitor so we can see if any input actually lands
        // in the overlay even when it’s not first responder.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { (event) -> NSEvent? in
            debugLog("monitor event type=\(event.type) code=\(event.keyCode) chars='\(event.characters ?? "")' mods=\(event.modifierFlags)")

            return event
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

func controllingTTY() -> String? {
    let tty = String(cString: ctermid(nil))
    return tty.isEmpty ? nil : tty
}

func parseArgs() -> (Mode, String?, String?) {
    var mode: Mode = .selfHost
    var ttyPath: String? = nil
    var directory: String? = nil
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "-m" || arg == "--mode" {
            if i + 1 < args.count {
                let v = args[i + 1].lowercased()
                if v == "tty" { mode = .tty }
                else if v == "apple" { mode = .apple }
                else if v == "terminal" { mode = .terminal }
                else if v == "self" || v == "self-host" || v == "rpc" { mode = .selfHost }
                else if v == "self-tui" || v == "self-terminal" { mode = .selfTerminal }
                else if v == "dry" { mode = .dry }
                i += 1
            }
        } else if arg == "--tty" {
            if i + 1 < args.count { ttyPath = args[i + 1]; i += 1 }
        } else if arg.hasPrefix("--tty=") {
            ttyPath = String(arg.dropFirst("--tty=".count))
        } else if arg == "--dir" {
            if i + 1 < args.count { directory = args[i + 1]; i += 1 }
        } else if arg.hasPrefix("--dir=") {
            directory = String(arg.dropFirst("--dir=".count))
        }
        i += 1
    }
    return (mode, ttyPath, directory)
}

var (mode, ttyPath, directory) = parseArgs()
if mode == .tty && (ttyPath == nil || ttyPath?.isEmpty == true) {
    ttyPath = controllingTTY()
}
debugLog("launch mode=\(mode) tty=\(ttyPath ?? "nil") dir=\(directory ?? "nil")")
let controller = OverlayController(mode: mode, ttyPath: ttyPath, directory: directory)
let appDelegate = AppDelegate(controller: controller)
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()