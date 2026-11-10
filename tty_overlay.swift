import AppKit
import AVFoundation
import Foundation
import Speech

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

enum Mode {
    case dry
    case tty
    case apple
    case terminal
}

final class AppleScriptInjector {
    let ttyPath: String
    var lastError: String = ""

    init(ttyPath: String) {
        self.ttyPath = ttyPath
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
        let escaped = ttyPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\" to get name of (first window whose tty is \"\(escaped)\")"
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
        let escaped = ttyPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            set frontmost of (first window whose tty is "\(escaped)") to true
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
            do script "\(escaped)" in tab 1 of (first window whose tty is "\(ttyPath)")
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

final class KeyTapeView: NSView {
    enum AgentStatus {
        case idle
        case processing
        case done
    }

    weak var controller: OverlayController?
    var caretVisible = true
    var agentStatus: AgentStatus = .idle

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        debugLog("keyDown code=\(event.keyCode) chars='\(event.characters ?? "")' mods=\(event.modifierFlags)")
        controller?.handleKeyDown(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        debugLog("keyUp code=\(event.keyCode) chars='\(event.characters ?? "")' mods=\(event.modifierFlags)")
        controller?.handleKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        debugLog("flagsChanged code=\(event.keyCode) mods=\(event.modifierFlags)")
        controller?.handleFlagsChanged(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // normal textbox look: white background, subtle border
        NSColor.white.setFill()
        dirtyRect.fill()

        NSColor(white: 0.82, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()

        guard let controller = controller else { return }

        let text: String
        let color: NSColor
        if controller.isCapturing {
            if controller.rawText.isEmpty {
                text = "type…"
                color = NSColor(white: 0.35, alpha: 1)
            } else {
                text = controller.rawText
                color = NSColor(white: 0.13, alpha: 1)
            }
        } else {
            text = "click START or Option+Space, then type"
            color = NSColor.systemGray
        }

        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byCharWrapping
        para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]

        // Put the caret inline at the end of the text and let it wrap with the text.
        var display = text
        if controller.isCapturing {
            display += caretVisible ? "▌" : " "
        }

        let textRect = NSRect(
            x: 12,
            y: 8,
            width: max(10, bounds.width - 24),
            height: max(10, bounds.height - 36)
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        NSAttributedString(string: display, attributes: attrs)
            .draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        NSGraphicsContext.restoreGraphicsState()

        drawAgentStatus()
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
        let size = (label as NSString).size(withAttributes: attrs)
        let x = bounds.width - size.width - 12
        let y = bounds.height - size.height - 7

        let pill = NSRect(
            x: x - 6,
            y: y - 3,
            width: size.width + 12,
            height: size.height + 6
        )
        NSColor(white: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        label.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
}

// ---------------------------------------------------------------------------
// Controller / UI
// ---------------------------------------------------------------------------

final class OverlayController: NSObject, NSWindowDelegate {
    let window: OverlayWindow
    let keyTape: KeyTapeView
    let ttyPath: String?
    let statusLabel: NSTextField
    let targetLabel: NSTextField
    let terminalTitleLabel: NSTextField
    let startButton: NSButton
    let voiceButton: NSButton
    let closeButton: NSButton

    private let speech = SpeechInput()
    private var voiceBase = ""

    let injector: TtyInjector?
    let appleInjector: AppleScriptInjector?
    let terminalInjector: AppleScriptInjector?
    let mode: Mode

    var isCapturing = false
    var tape: [String] = []
    var rawText: String = ""
    var sentBytes = 0
    var ttyFD: Int32 = -1

    init(mode: Mode, ttyPath: String?) {
        self.mode = mode
        self.ttyPath = ttyPath
        self.injector = ttyPath.map { TtyInjector(path: $0) }
        self.appleInjector = ttyPath.map { AppleScriptInjector(ttyPath: $0) }
        self.terminalInjector = ttyPath.map { AppleScriptInjector(ttyPath: $0) }

        let size = NSSize(width: 760, height: 170)
        let origin = NSPoint(
            x: max(20, (NSScreen.main?.frame.width ?? 1440) / 2 - size.width / 2),
            y: max(80, (NSScreen.main?.frame.height ?? 900) / 2 - size.height - 260)
        )

        window = OverlayWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.title = "TTY Overlay · \(ttyPath ?? "dry")"

        // container
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.45).cgColor
        container.layer?.borderWidth = 1.4
        window.contentView = container

        // status label
        statusLabel = NSTextField(labelWithString: "CAPTURE OFF")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .systemOrange
        statusLabel.frame = NSRect(x: 16, y: size.height - 26, width: 250, height: 20)
        container.addSubview(statusLabel)

        targetLabel = NSTextField(labelWithString: ttyPath.map { "TTY \($0)" } ?? "DRY RUN")
        targetLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        targetLabel.textColor = NSColor.systemGray
        targetLabel.frame = NSRect(x: 138, y: size.height - 25, width: 180, height: 18)
        container.addSubview(targetLabel)

        let termTitle = terminalInjector?.terminalWindowName() ?? ""
        terminalTitleLabel = NSTextField(labelWithString: termTitle)
        terminalTitleLabel.font = NSFont.systemFont(ofSize: 9)
        terminalTitleLabel.textColor = NSColor.systemGray
        terminalTitleLabel.lineBreakMode = .byTruncatingTail
        terminalTitleLabel.frame = NSRect(x: 326, y: size.height - 24, width: 240, height: 16)
        container.addSubview(terminalTitleLabel)

        // start button
        startButton = NSButton(title: "START", target: nil, action: nil)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .regular
        startButton.frame = NSRect(x: size.width - 118, y: size.height - 28, width: 58, height: 24)
        startButton.title = "START"
        container.addSubview(startButton)

        // voice button
        voiceButton = NSButton(title: "MIC", target: nil, action: nil)
        voiceButton.bezelStyle = .rounded
        voiceButton.controlSize = .regular
        voiceButton.frame = NSRect(x: size.width - 186, y: size.height - 28, width: 60, height: 24)
        container.addSubview(voiceButton)

        // close button
        closeButton = NSButton(title: "×", target: nil, action: nil)
        closeButton.bezelStyle = .roundRect
        closeButton.controlSize = .regular
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        closeButton.frame = NSRect(x: size.width - 52, y: size.height - 28, width: 36, height: 24)
        container.addSubview(closeButton)

        // key tape
        keyTape = KeyTapeView(frame: NSRect(x: 10, y: 10, width: size.width - 20, height: 120))
        keyTape.wantsLayer = true
        keyTape.layer?.cornerRadius = 8
        container.addSubview(keyTape)

        super.init()

        window.delegate = self
        keyTape.controller = self
        Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.keyTape.caretVisible.toggle()
            self.keyTape.needsDisplay = true
        }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refreshAgentStatus()
        }
        startButton.target = self
        startButton.action = #selector(toggleCapture)
        startButton.sendAction(on: [.leftMouseDown])
        voiceButton.target = self
        voiceButton.action = #selector(toggleVoice)
        voiceButton.sendAction(on: [.leftMouseDown])
        closeButton.target = self
        closeButton.action = #selector(closeApp)
        closeButton.sendAction(on: [.leftMouseDown])

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(keyTape)
    }

    @objc func toggleCapture() {
        #if arch(x86_64) || arch(arm64)
        // no-op
        #endif
        // Toggle capture and make the key view active.
        isCapturing.toggle()
        startButton.title = isCapturing ? "STOP" : "START"
        if isCapturing {
            statusLabel.stringValue = "CAPTURE ON"
            statusLabel.textColor = .systemGreen
            if mode == .tty, let inj = injector {
                if !inj.openIfNeeded() {
                    statusLabel.stringValue = "TTY OPEN ERROR"
                    statusLabel.textColor = .systemRed
                    isCapturing = false
                    startButton.title = "START"
                }
            }
        } else {
            speech.stop()
            voiceButton.title = "MIC"
            statusLabel.stringValue = "CAPTURE OFF"
            statusLabel.textColor = .systemOrange
        }
        keyTape.needsDisplay = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(keyTape)
    }

    private func refreshAgentStatus() {
        guard let ttyPath else { return }
        let name = (ttyPath as NSString).lastPathComponent
        let file = "/tmp/pi-overlay-\(name).status"
        guard let raw = try? String(contentsOfFile: file, encoding: .utf8) else {
            if keyTape.agentStatus != .idle {
                keyTape.agentStatus = .idle
                keyTape.needsDisplay = true
            }
            return
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    }

    @objc func toggleVoice() {
        if speech.isListening {
            stopVoice()
            return
        }
        if !isCapturing {
            toggleCapture()
        }
        guard isCapturing else { return }
        startVoice()
    }

    private func startVoice() {
        statusLabel.stringValue = "MIC PERMISSION"
        statusLabel.textColor = .systemOrange
        voiceButton.title = "STOP"

        speech.onTranscript = { [weak self] text, final in
            guard let self else { return }
            self.rawText = self.voiceBase + text
            self.keyTape.needsDisplay = true
            if final {
                self.stopVoice()
            }
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
                self.voiceButton.title = "MIC"
                return
            }

            self.voiceBase = self.rawText
            if !self.voiceBase.isEmpty && !self.voiceBase.hasSuffix(" ") {
                self.voiceBase += " "
            }

            self.statusLabel.stringValue = "LISTENING"
            self.statusLabel.textColor = .systemRed
            self.voiceButton.title = "STOP"
            self.speech.start()
            if !self.speech.isListening {
                self.stopVoice()
            }
        }
    }

    private func stopVoice() {
        speech.stop()
        voiceButton.title = "MIC"
        if isCapturing {
            statusLabel.stringValue = "CAPTURE ON"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "CAPTURE OFF"
            statusLabel.textColor = .systemOrange
        }
        keyTape.needsDisplay = true
    }

    @objc func closeApp() {
        injector?.closeAll()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        injector?.closeAll()
    }

    func handleKeyUp(_ event: NSEvent) {
        // Some modifier key events surface on keyUp instead of keyDown.
        if event.keyCode == 58 || event.keyCode == 61 {
            toggleCapture()
            return
        }
    }

    func handleFlagsChanged(_ event: NSEvent) {
        // Option key: 58 = left option, 61 = right option
        if event.keyCode == 58 || event.keyCode == 61 {
            debugLog("option flagsChanged -> toggle")
            toggleCapture()
        }
    }

    func handleKeyDown(_ event: NSEvent) {
        // Cmd+Q quits
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            closeApp()
            return
        }

        // macOS does not deliver a keyDown for a bare Option press.
        // Use Option+Space as the reliable toggle chord.
        if event.modifierFlags.contains(.option) && event.keyCode == 49 {
            toggleCapture()
            return
        }

        guard isCapturing else { return }

        var label = Self.label(for: event)
        if label.isEmpty { return }
        if label == " " { label = " " }
        if label == "\n" || label == "\r" { label = "⏎" }
        if label == "\t" { label = "⇥" }
        if label == "\u{1B}" { label = "⎋" }

        // Backspace should edit the pending line, not be sent to the tty.
        if event.keyCode == 51 || event.keyCode == 117 {
            if rawText.count > 0 { rawText.removeLast() }
            keyTape.needsDisplay = true
            return
        }

        tape.append(label)
        if label != "SP" && label != "⏎" && label != "⇥" && label != "⌫" && label != "⎋" {
            rawText += label
        }
        if tape.count > 48 { tape.removeFirst(tape.count - 48) }

        let isEnter = (event.keyCode == 36 || event.keyCode == 52)
        if isEnter {
            if speech.isListening {
                stopVoice()
            }
            let chunk = rawText
            var sentOk = true
            if mode == .tty, let inj = injector {
                let raw = chunk + "\r"
                sentOk = inj.inject(raw)
            } else if mode == .terminal, let inj = terminalInjector {
                sentOk = inj.sendTerminalScript(chunk)
            } else if mode == .apple, let inj = appleInjector {
                sentOk = inj.sendKey(36)
            }
            if sentOk {
                sentBytes += chunk.utf8.count
                tape.removeAll()
                rawText.removeAll()
            } else {
                statusLabel.stringValue = "SEND ERROR"
                statusLabel.textColor = .systemRed
                startButton.title = "START"
                isCapturing = false
            }
        }

        keyTape.needsDisplay = true

    }

    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 36, 52: return "⏎"   // return / kp enter
        case 51, 117: return "⌫"  // delete / backspace
        case 48: return "⇥"
        case 49: return " "
        case 53: return "⎋"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F9"
        case 101: return "F10"
        case 109: return "F11"
        case 103: return "F12"
        default: break
        }

        if let chars = event.characters, let clean = cleanText(chars), !clean.isEmpty {
            return clean
        }
        if let mods = event.charactersIgnoringModifiers, let clean = cleanText(mods), !clean.isEmpty {
            return clean
        }
        return ""
    }

    static func cleanText(_ text: String) -> String? {
        let allowed = text.unicodeScalars.filter { scalar in
            if scalar.value < 0x100 {
                return !(scalar.value < 0x20 || scalar.value == 0x7f)
            }
            return true
        }
        if allowed.isEmpty { return nil }
        return String(String.UnicodeScalarView(allowed))
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
        controller.window.makeFirstResponder(controller.keyTape)
        controller.keyTape.needsDisplay = true
        
        // App-level key/flag monitor so we can see if any input actually lands
        // in the overlay even when it’s not first responder.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { (event) -> NSEvent? in
            debugLog("monitor event type=\(event.type) code=\(event.keyCode) chars='\(event.characters ?? "")' mods=\(event.modifierFlags)")

            return event
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.injector?.closeAll()
    }
}

func controllingTTY() -> String? {
    let tty = String(cString: ctermid(nil))
    return tty.isEmpty ? nil : tty
}

func parseArgs() -> (Mode, String?) {
    var mode: Mode = .dry
    var ttyPath: String? = nil
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "-m" || arg == "--mode" {
            if i + 1 < args.count {
                let v = args[i + 1]
                if v.lowercased() == "tty" { mode = .tty }
                else if v.lowercased() == "apple" { mode = .apple }
                else if v.lowercased() == "terminal" { mode = .terminal }
                i += 1
            }
        } else if arg == "--tty" {
            if i + 1 < args.count { ttyPath = args[i + 1]; i += 1 }
        } else if arg.hasPrefix("--tty=") {
            ttyPath = String(arg.dropFirst("--tty=".count))
        }
        i += 1
    }
    return (mode, ttyPath)
}

var (mode, ttyPath) = parseArgs()
if mode == .tty && (ttyPath == nil || ttyPath?.isEmpty == true) {
    ttyPath = controllingTTY()
}
debugLog("launch mode=\(mode) tty=\(ttyPath ?? "nil")")
let controller = OverlayController(mode: mode, ttyPath: ttyPath)
let appDelegate = AppDelegate(controller: controller)
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()