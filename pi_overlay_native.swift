import AppKit
import AVFoundation
import Darwin
import Foundation
import QuartzCore
import Speech
import UniformTypeIdentifiers
import WebKit

// ---------------------------------------------------------------------------
// TIOCSTI injection
// ---------------------------------------------------------------------------

let TIOCSTI: UInt = 0x80017472 // macOS: _IOW('t', 114, char)

func debugLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/pi-overlay-native.log"
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

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

/// Single source of truth for the overlay's look. The palette follows the
/// light card design: white rounded card, lavender-free neutral surfaces,
/// near-black input, purple accent.
enum Theme {
    static let card = NSColor(calibratedWhite: 1.0, alpha: 1)
    static let tabStrip = NSColor(calibratedWhite: 1.0, alpha: 1)
    static let text = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    static let textSecondary = NSColor(calibratedRed: 0.42, green: 0.42, blue: 0.48, alpha: 1)
    static let textTertiary = NSColor(calibratedWhite: 0.62, alpha: 1)
    static let border = NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.93, alpha: 1)
    static let borderStrong = NSColor(calibratedRed: 0.82, green: 0.82, blue: 0.86, alpha: 1)
    static let field = NSColor(calibratedWhite: 1.0, alpha: 1)
    static let fieldAlt = NSColor(calibratedRed: 0.955, green: 0.955, blue: 0.972, alpha: 1)
    static let fieldHover = NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.96, alpha: 1)

    static let accent = NSColor(calibratedRed: 0.49, green: 0.36, blue: 1.0, alpha: 1)   // #7C5CFF
    static let accentSoft = NSColor(calibratedRed: 0.92, green: 0.89, blue: 1.0, alpha: 1)
    static let accentText = NSColor.white

    static let ok = NSColor(calibratedRed: 0.16, green: 0.60, blue: 0.35, alpha: 1)
    static let okFill = NSColor(calibratedRed: 0.87, green: 0.95, blue: 0.89, alpha: 1)
    static let warn = NSColor(calibratedRed: 0.93, green: 0.57, blue: 0.10, alpha: 1)
    static let warnFill = NSColor(calibratedRed: 0.99, green: 0.95, blue: 0.87, alpha: 1)
    static let bad = NSColor(calibratedRed: 0.85, green: 0.22, blue: 0.24, alpha: 1)
    static let badFill = NSColor(calibratedRed: 0.99, green: 0.90, blue: 0.90, alpha: 1)

    static let input = NSColor(calibratedRed: 0.050, green: 0.050, blue: 0.062, alpha: 1)
    static let inputRaised = NSColor(calibratedRed: 0.115, green: 0.115, blue: 0.135, alpha: 1)
    static let inputBorder = NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.19, alpha: 1)
    static let inputText = NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    static let inputMuted = NSColor(calibratedRed: 0.50, green: 0.50, blue: 0.55, alpha: 1)

    static let tabStripHeight: CGFloat = 56
    static let controlHeight: CGFloat = 34
    static let fieldRadius: CGFloat = 9
    static let inputRadius: CGFloat = 16
    static let responseRadius: CGFloat = 12
    /// Bottom strip that shows the context window usage and the token rate.
    static let footerHeight: CGFloat = 26

    /// Reasoning-effort dropdown, sits next to the model dropdown.
    static let thinkingPopupWidth: CGFloat = 106
    static let thinkingTint = NSColor(calibratedRed: 0.45, green: 0.36, blue: 0.86, alpha: 1)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    /// SF Symbol rotated in a square canvas. The result is a template image,
    /// so `contentTintColor` on the button still controls its color.
    static func rotatedSymbol(
        _ name: String,
        size: CGFloat,
        weight: NSFont.Weight = .semibold,
        degrees: CGFloat
    ) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let image = base.withSymbolConfiguration(config) else { return nil }

        let width = image.size.width
        let height = image.size.height
        let side = max(width, height)
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: side / 2, yBy: side / 2)
        transform.rotate(byDegrees: degrees)
        transform.concat()
        image.draw(in: NSRect(
            x: -width / 2,
            y: -height / 2,
            width: width,
            height: height
        ))
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }

    /// SF Symbol tinted through a palette configuration (macOS 12+).
    static func symbol(
        _ name: String,
        size: CGFloat,
        weight: NSFont.Weight = .semibold,
        color: NSColor
    ) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(config)
    }

    struct PillTone {
        let fill: NSColor
        let dot: NSColor
    }

    static func tone(for status: String) -> PillTone {
        let value = status.uppercased()
        let badWords = [
            "ERROR", "FAILED", "EXITED", "MISSING", "DENIED", "BUSY", "CANCELED",
            "CANCELLED", "NO ", "UNAVAILABLE",
        ]
        if badWords.contains(where: { value.contains($0) }) {
            return PillTone(fill: badFill, dot: bad)
        }
        if value.contains("READY") || value.contains("DONE") {
            return PillTone(fill: okFill, dot: ok)
        }
        let busyWords = [
            "PROCESS", "START", "CONNECT", "SWITCH", "SEND", "CHOOSE", "SELECT",
            "LOADING", "RESTART",
        ]
        if busyWords.contains(where: { value.contains($0) }) {
            return PillTone(fill: warnFill, dot: warn)
        }
        return PillTone(fill: fieldAlt, dot: textTertiary)
    }
}

/// Header status chip. Keeps `stringValue` / `textColor` (the controller sets
/// those in dozens of places) but draws a rounded pill with a status dot.
final class StatusPillLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        let text = stringValue
        guard !text.isEmpty else { return }

        let font = Theme.font(12, .semibold)
        let tone = Theme.tone(for: text)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: tone.dot,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let width = min(bounds.width, max(54, textSize.width + 34))
        let pill = NSRect(x: 0, y: (bounds.height - 26) / 2, width: width, height: 26)
        tone.fill.setFill()
        Theme.rounded(pill, 8).fill()

        tone.dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: 11, y: pill.midY - 4, width: 8, height: 8)).fill()

        (text as NSString).draw(
            at: NSPoint(
                x: 25,
                y: pill.minY + (pill.height - textSize.height) / 2
            ),
            withAttributes: attrs
        )
    }
}

/// Neutral rounded chip for the pid / remote host label.
final class ChipLabel: NSTextField {
    var symbolName: String?

    override func draw(_ dirtyRect: NSRect) {
        let text = stringValue
        guard !text.isEmpty else { return }

        Theme.fieldAlt.setFill()
        Theme.rounded(bounds, 8).fill()

        let font = Theme.mono(10, .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.textSecondary,
        ]
        var x: CGFloat = 9
        if let symbolName,
           let symbol = Theme.symbol(symbolName, size: 10, weight: .medium, color: Theme.textTertiary) {
            symbol.draw(in: NSRect(x: x, y: (bounds.height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            x += symbol.size.width + 6
        }
        let textSize = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2),
            withAttributes: attrs
        )
    }
}

/// Small translucent caption used above the compact capsule to name the
/// profile and tab that the textbox will send to.
final class PillCaption: NSTextField {
    var symbolName: String?

    override func draw(_ dirtyRect: NSRect) {
        let text = stringValue
        guard !text.isEmpty else { return }

        let font = Theme.font(11, .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let iconWidth: CGFloat = symbolName == nil ? 0 : 17
        let width = min(bounds.width, textSize.width + iconWidth + 22)
        let pill = NSRect(x: 0, y: (bounds.height - 22) / 2, width: width, height: 22)
        NSColor(calibratedWhite: 0.02, alpha: 0.55).setFill()
        Theme.rounded(pill, 11).fill()

        var x: CGFloat = 10
        if let symbolName,
           let symbol = Theme.symbol(
                symbolName,
                size: 10,
                color: NSColor.white.withAlphaComponent(0.85)
           ) {
            symbol.draw(in: NSRect(
                x: x,
                y: (bounds.height - symbol.size.height) / 2,
                width: symbol.size.width,
                height: symbol.size.height
            ))
            x += symbol.size.width + 5
        }
        (text as NSString).draw(
            in: NSRect(
                x: x,
                y: (bounds.height - textSize.height) / 2,
                width: max(8, width - x - 9),
                height: textSize.height
            ),
            withAttributes: attrs
        )
    }
}

/// Footer strip along the bottom edge: the context window (current/total) with
/// a small usage meter, and the output token rate for the turn that is running
/// — or for the last one while idle. The numbers come from pi: RPC
/// `get_session_stats`, the `usage` on each assistant message, or the
/// extension's `usage` event in tty mode.
final class FooterView: NSView {
    var contextTokens: Int?
    var contextWindow: Int?
    var tokensPerSecond: Double?
    /// A live rate reads in the accent colour; a finished turn reads as history.
    var isStreaming = false
    /// True when the rate is our char-count estimate rather than usage reported
    /// by the provider. It reads as `≈ 12 tok/s` so the two are not confused.
    var rateIsEstimated = false
    /// The active tab's last compaction. The usage number is already the
    /// post-compaction estimate, so the amount freed is drawn next to it; without it
    /// the meter looks like it dropped by itself.
    var compactedFrom: Int?
    var compactedTo: Int?

    private static let font = Theme.mono(11, .medium)
    private static let meterWidth: CGFloat = 56
    private static let meterHeight: CGFloat = 8
    private static let inset: CGFloat = 16

    override var isFlipped: Bool { true }

    static func tokenCount(_ value: Int) -> String {
        if abs(value) < 1000 { return String(value) }
        let k = Double(value) / 1000.0
        return k < 10 ? String(format: "%.1fk", k) : String(format: "%.0fk", k)
    }

    private var contextText: String {
        guard let window = contextWindow, window > 0 else { return "context —" }
        guard let tokens = contextTokens else { return "— / \(Self.tokenCount(window))" }
        return "\(Self.tokenCount(tokens)) / \(Self.tokenCount(window))"
    }

    private var rateText: String {
        guard let rate = tokensPerSecond, rate > 0 else { return "— tok/s" }
        let number = rate < 10 ? String(format: "%.1f", rate) : String(format: "%.0f", rate)
        return (rateIsEstimated ? "≈ " : "") + number + " tok/s"
    }

    private var meterFraction: CGFloat {
        guard let tokens = contextTokens, let window = contextWindow, window > 0 else { return 0 }
        return min(1, max(0, CGFloat(tokens) / CGFloat(window)))
    }

    private var meterTone: NSColor {
        let used = meterFraction
        if used >= 0.85 { return Theme.bad }
        if used >= 0.70 { return Theme.warn }
        return Theme.accent
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        guard height > 12, bounds.width > 2 * Self.inset else { return }

        Theme.border.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 1)).fill()

        let neutral: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: Theme.textSecondary,
        ]
        let rateColor = isStreaming ? Theme.accent : Theme.textSecondary
        let rateAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: rateColor,
        ]
        let contextString = contextText as NSString
        let rateString = rateText as NSString
        let savedAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: Theme.ok,
        ]
        var savedString: NSString?
        var savedWidth: CGFloat = 0
        if let from = compactedFrom, let to = compactedTo, from > to {
            let text = ("↓" + Self.tokenCount(from - to)) as NSString
            savedString = text
            savedWidth = text.size(withAttributes: savedAttrs).width
        }
        let contextWidth = contextString.size(withAttributes: neutral).width
        let rateWidth = rateString.size(withAttributes: rateAttrs).width
        let gap: CGFloat = 9

        // Drop the meter when the window is too narrow for meter + both texts.
        let showMeter = bounds.width >= Self.inset + Self.meterWidth + gap
            + contextWidth + (savedWidth > 0 ? gap + savedWidth : 0) + 18 + rateWidth + Self.inset
        let textTop = (height - (Self.font.ascender - Self.font.descender)) / 2

        var x = Self.inset
        if showMeter {
            let track = NSRect(
                x: x,
                y: (height - Self.meterHeight) / 2,
                width: Self.meterWidth,
                height: Self.meterHeight
            )
            Theme.fieldAlt.setFill()
            Theme.rounded(track, Self.meterHeight / 2).fill()
            if meterFraction > 0 {
                meterTone.setFill()
                Theme.rounded(
                    NSRect(
                        x: track.minX,
                        y: track.minY,
                        width: max(2, track.width * meterFraction),
                        height: track.height
                    ),
                    Self.meterHeight / 2
                ).fill()
            }
            x += Self.meterWidth + gap
        }

        contextString.draw(at: NSPoint(x: x, y: textTop), withAttributes: neutral)
        if let savedString,
           x + contextWidth + gap + savedWidth + 18 <= bounds.width - Self.inset - rateWidth {
            savedString.draw(at: NSPoint(x: x + contextWidth + gap, y: textTop), withAttributes: savedAttrs)
        }
        rateString.draw(
            at: NSPoint(x: bounds.width - Self.inset - rateWidth, y: textTop),
            withAttributes: rateAttrs
        )
    }
}

/// Popup button drawn as a rounded white field with an SF Symbol and a
/// chevron. `NSPopUpButton` still owns the menu and the title/selection API.
final class ThemedPopUpButton: NSPopUpButton {
    var symbolName: String?
    var symbolTint: NSColor = Theme.textSecondary
    var titleFont: NSFont = Theme.font(12, .medium)

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = Theme.rounded(rect, Theme.fieldRadius)

        (isEnabled ? Theme.field : Theme.fieldAlt).setFill()
        path.fill()
        (isHighlighted ? Theme.borderStrong : Theme.border).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x: CGFloat = 11
        if let symbolName,
           let symbol = Theme.symbol(
                symbolName,
                size: 12,
                color: isEnabled ? symbolTint : Theme.textTertiary
           ) {
            symbol.draw(in: NSRect(
                x: x,
                y: (bounds.height - symbol.size.height) / 2,
                width: symbol.size.width,
                height: symbol.size.height
            ))
            x += symbol.size.width + 7
        }

        let chevronWidth: CGFloat = 20
        let textRect = NSRect(
            x: x,
            y: (bounds.height - 17) / 2,
            width: max(8, bounds.width - x - chevronWidth - 6),
            height: 17
        )
        let raw = title
            .replacingOccurrences(of: "📁 ", with: "")
            .replacingOccurrences(of: "👤 ", with: "")
            .replacingOccurrences(of: "☁ ", with: "☁ ")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (raw as NSString).draw(
            in: textRect,
            withAttributes: [
                .font: titleFont,
                .foregroundColor: isEnabled ? Theme.text : Theme.textTertiary,
                .paragraphStyle: paragraph,
            ]
        )

        if let chevron = Theme.symbol("chevron.down", size: 10, color: Theme.textTertiary) {
            chevron.draw(in: NSRect(
                x: bounds.width - chevron.size.width - 9,
                y: (bounds.height - chevron.size.height) / 2,
                width: chevron.size.width,
                height: chevron.size.height
            ))
        }
    }
}

/// Flat SF Symbol button used by the tab strip and the response row.
final class IconButton: NSButton {
    var symbolName: String = "circle"
    var symbolSize: CGFloat = 14
    var symbolTint: NSColor = Theme.textSecondary
    var hoverFill: NSColor = Theme.fieldAlt
    var baseFill: NSColor = .clear
    var symbolRotation: CGFloat = 0

    convenience init(
        symbol: String,
        size: CGFloat = 14,
        tint: NSColor = Theme.textSecondary,
        tooltip: String? = nil,
        rotation: CGFloat = 0
    ) {
        self.init(frame: .zero)
        symbolName = symbol
        symbolSize = size
        symbolTint = tint
        symbolRotation = rotation
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 7
        setSymbol(symbol, size: size, tint: tint)
        toolTip = tooltip
    }

    func setSymbol(_ name: String, size: CGFloat? = nil, tint: NSColor? = nil) {
        symbolName = name
        if let size { symbolSize = size }
        if let tint { symbolTint = tint }
        if symbolRotation == 0 {
            image = Theme.symbol(name, size: symbolSize, weight: .medium, color: symbolTint)
        } else {
            image = Theme.rotatedSymbol(
                name,
                size: symbolSize,
                weight: .medium,
                degrees: symbolRotation
            )
        }
        contentTintColor = symbolTint
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = isHighlighted
            ? hoverFill.cgColor
            : baseFill.cgColor
    }
}

/// Filled pill button used for Send and the small attachment chip.
final class PillButton: NSButton {
    var fillColor: NSColor = Theme.accent
    var textColor: NSColor = Theme.accentText

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        Theme.rounded(bounds, bounds.height / 2).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.font(12, .semibold),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let textSize = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            in: NSRect(
                x: 10,
                y: (bounds.height - textSize.height) / 2,
                width: max(10, bounds.width - 20),
                height: textSize.height
            ),
            withAttributes: attrs
        )
    }
}

/// One discoverable pi command (`get_commands`). Only skills and the MCP
/// command are kept for now.
struct PiCommand: Equatable {
    enum Action: Equatable {
        case setSessionName
        case reloadPi
        case compactSession
    }

    let name: String
    let description: String
    let source: String
    let sourceInfo: String?
    let action: Action?

    init(
        name: String,
        description: String,
        source: String,
        sourceInfo: String? = nil,
        action: Action? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.sourceInfo = sourceInfo
        self.action = action
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        let description = (json["description"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = json["source"] as? String ?? ""
        var sourceInfo: String?
        if let info = json["sourceInfo"] as? [String: Any] {
            var parts: [String] = []
            if let scope = info["scope"] as? String, !scope.isEmpty { parts.append(scope) }
            if let path = info["path"] as? String, !path.isEmpty { parts.append(path) }
            sourceInfo = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        self.init(
            name: name,
            description: description,
            source: source,
            sourceInfo: sourceInfo,
            action: nil
        )
    }

    static let sessionName = PiCommand(
        name: "name",
        description: "Set the session display name",
        source: "builtin",
        action: .setSessionName
    )

    static let reload = PiCommand(
        name: "reload",
        description: "Restart the pi RPC process and reload extensions/skills",
        source: "builtin",
        action: .reloadPi
    )

    static let compact = PiCommand(
        name: "compact",
        description: "Summarise older context to free the context window",
        source: "builtin",
        action: .compactSession
    )
}

/// One row in the slash-command palette.
final class CommandRowView: NSView {
    override var isFlipped: Bool { true }

    let command: PiCommand
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    var onAccept: ((PiCommand) -> Void)?

    init(command: PiCommand) {
        self.command = command
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onAccept?(command)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Theme.accentSoft.setFill()
            Theme.rounded(bounds.insetBy(dx: 2, dy: 1), 8).fill()
        }

        let badgeFont = Theme.font(9, .semibold)
        let badgeText = command.name == "mcp" ? "mcp" : command.source
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: Theme.textSecondary,
        ]
        let badgeSize = (badgeText as NSString).size(withAttributes: badgeAttrs)
        let badgeWidth = badgeSize.width + 12
        let badgeRect = NSRect(
            x: bounds.width - badgeWidth - 10,
            y: (bounds.height - 16) / 2,
            width: badgeWidth,
            height: 16
        )
        Theme.fieldAlt.setFill()
        Theme.rounded(badgeRect, 8).fill()
        (badgeText as NSString).draw(
            at: NSPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 3),
            withAttributes: badgeAttrs
        )

        let nameFont = Theme.mono(12, .medium)
        let nameParagraph = NSMutableParagraphStyle()
        nameParagraph.lineBreakMode = .byTruncatingMiddle
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: Theme.text,
            .paragraphStyle: nameParagraph,
        ]
        (("/" + command.name) as NSString).draw(
            in: NSRect(
                x: 12,
                y: 6,
                width: max(20, badgeRect.minX - 20),
                height: 16
            ),
            withAttributes: nameAttrs
        )

        if !command.description.isEmpty {
            let descParagraph = NSMutableParagraphStyle()
            descParagraph.lineBreakMode = .byTruncatingTail
            let descAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.font(10.5, .regular),
                .foregroundColor: Theme.textSecondary,
                .paragraphStyle: descParagraph,
            ]
            (command.description as NSString).draw(
                in: NSRect(
                    x: 12,
                    y: 21,
                    width: max(20, badgeRect.minX - 20),
                    height: 14
                ),
                withAttributes: descAttrs
            )
        }
    }
}

/// Floating list of slash commands. Rows are created from `PiCommand`s and
/// kept in a scroll view so a long skill list still works.
final class CommandPaletteView: NSView {
    private let scrollView = NSScrollView()
    private let document = CommandPaletteDocumentView()
    private var rows: [CommandRowView] = []
    private(set) var commands: [PiCommand] = []
    private(set) var selectedIndex = 0
    var onAccept: ((PiCommand) -> Void)?

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        min(320, CGFloat(max(1, commands.count)) * 38 + 12)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = document
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.card.setFill()
        Theme.rounded(bounds, 12).fill()
        Theme.border.setStroke()
        let border = Theme.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), 12)
        border.lineWidth = 1
        border.stroke()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds.insetBy(dx: 6, dy: 6)
        let width = max(10, scrollView.contentSize.width)
        let height = max(scrollView.contentSize.height, CGFloat(rows.count) * 38)
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * 38, width: width, height: 38)
        }
    }

    func setCommands(_ commands: [PiCommand]) {
        self.commands = commands
        for row in rows { row.removeFromSuperview() }
        rows = commands.map { command in
            let row = CommandRowView(command: command)
            row.onAccept = { [weak self] selected in
                self?.onAccept?(selected)
            }
            document.addSubview(row)
            return row
        }
        selectedIndex = 0
        updateSelection()
        needsLayout = true
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
        updateSelection()
    }

    func selectedCommand() -> PiCommand? {
        guard rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex].command
    }

    private func updateSelection() {
        for (index, row) in rows.enumerated() {
            row.isSelected = index == selectedIndex
        }
        guard rows.indices.contains(selectedIndex) else { return }
        rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
    }
}

/// Flipped document view for top-down command rows.
final class CommandPaletteDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Non-activating floating panel so the command list can extend above the
/// overlay window without stealing focus from the prompt text view.
final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

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

    static let font = Theme.font(16, .regular)
    /// Dark box, light text.
    static let background = Theme.input
    static let textColor = Theme.inputText
    static let borderColor = Theme.inputBorder
    static let placeholderColor = Theme.inputMuted
    static let selectionColor = Theme.accent.withAlphaComponent(0.35)
    static var paragraphStyle: NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.alignment = .left
        return para
    }

    /// Height of the strip along the bottom edge reserved for the Speak button
    /// and the status pill, so wrapped text never runs underneath them.
    static let bottomBand: CGFloat = 58
    private static let textInset = NSSize(width: 10, height: 8)
    private var bottomBand: CGFloat { isCompact ? 0 : Self.bottomBand }

    weak var controller: OverlayController? {
        didSet { textView.controller = controller }
    }

    var agentStatus: AgentStatus = .idle {
        didSet {
            guard agentStatus != oldValue else { return }
            needsDisplay = true
            onStatusChange?(agentStatus)
        }
    }
    /// Called when the Processing/Done state changes (drives the Send button).
    var onStatusChange: ((AgentStatus) -> Void)?
    /// Space reserved on the right of the bottom band for the Send button.
    var statusRightInset: CGFloat = 18
    /// Compact single-capsule mode: no status band, the text area sits between
    /// the microphone and the pid/Send controls.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }
    /// Right-hand space (pid + Send) reserved in compact mode.
    var compactRightInset: CGFloat = 200

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
        textView.insertionPointColor = Theme.accent
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
        if isCompact {
            let left: CGFloat = 64
            let top = max(8, (bounds.height - 26) / 2)
            return NSRect(
                x: left,
                y: top,
                width: max(10, bounds.width - left - compactRightInset),
                height: 26
            )
        }
        let inset = Self.textInset
        return NSRect(
            x: inset.width,
            y: inset.height,
            width: max(10, bounds.width - inset.width * 2),
            height: max(10, bounds.height - inset.height - bottomBand)
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
        if isCompact, let window {
            window.performDrag(with: event)
            return
        }
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
        // Dark input card: large radius, near-black fill, hairline border.
        let radius = isCompact ? bounds.height / 2 : Theme.inputRadius
        // In compact mode the capsule is translucent: the desktop shows
        // through, while the text keeps enough contrast to stay readable.
        let fill = isCompact
            ? NSColor(calibratedWhite: 0.03, alpha: 0.30)
            : Self.background
        NSGraphicsContext.saveGraphicsState()
        Theme.rounded(bounds, radius).addClip()
        fill.setFill()
        dirtyRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        let stroke = isCompact
            ? NSColor.white.withAlphaComponent(0.14)
            : Self.borderColor
        stroke.setStroke()
        let border = Theme.rounded(
            bounds.insetBy(dx: 0.5, dy: 0.5),
            radius
        )
        border.lineWidth = 1
        border.stroke()

        // The placeholder sits under the (transparent) text view.
        if textView.string.isEmpty {
            let area = textArea
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: isCompact
                    ? NSColor.white.withAlphaComponent(0.55)
                    : Self.placeholderColor,
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
        let label = agentStatus == .processing ? "●  Processing" : "✓  Done"
        let font = Theme.font(11, .semibold)
        let size = (label as NSString).size(withAttributes: [.font: font])
        return NSRect(
            x: bounds.width - statusRightInset - size.width - 18,
            y: bounds.height - size.height - 22,
            width: size.width + 18,
            height: size.height + 10
        )
    }

    private func drawAgentStatus() {
        guard agentStatus != .idle, !isCompact else { return }

        let label = agentStatus == .processing ? "●  Processing" : "✓  Done"
        let font = Theme.font(11, .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: agentStatus == .processing ? Theme.warn : Theme.accentText,
        ]
        let pill = statusPillRect

        let fill = agentStatus == .processing ? Theme.inputRaised : Theme.accent
        fill.setFill()
        Theme.rounded(pill, pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 9, y: pill.minY + 5), withAttributes: attrs)
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
    private let remoteRecentsKey = "piOverlay.recentRemoteLocations"
    private let remoteLastKey = "piOverlay.lastRemoteLocation"
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

    // MARK: - Remote recents

    /// Remote folders are remembered as `ssh://host[:port]/abs/path` strings,
    /// so one array holds them without touching the local filesystem checks
    /// that `recents` applies.
    func remoteRecents() -> [(host: RemoteHost, path: String)] {
        let raw = defaults.stringArray(forKey: remoteRecentsKey) ?? []
        return raw.compactMap { entry in
            let decoded = TabLocationCodec.decode(entry)
            guard let host = decoded.host, !decoded.path.isEmpty else { return nil }
            return (host, decoded.path)
        }
    }

    func addRemoteRecent(host: RemoteHost, path: String) {
        let key = TabLocationCodec.encode(host: host, path: path)
        defaults.set(key, forKey: remoteLastKey)

        var entries = defaults.stringArray(forKey: remoteRecentsKey) ?? []
        entries.removeAll { $0 == key }
        entries.insert(key, at: 0)
        if entries.count > maxRecents {
            entries = Array(entries.prefix(maxRecents))
        }
        defaults.set(entries, forKey: remoteRecentsKey)
    }

    var lastRemote: (host: RemoteHost, path: String)? {
        guard let raw = defaults.string(forKey: remoteLastKey) else { return nil }
        let decoded = TabLocationCodec.decode(raw)
        guard let host = decoded.host else { return nil }
        return (host, decoded.path)
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

            var rawSession: String?
            if let separator = tabLine.firstIndex(of: "\t") {
                let suffix = String(tabLine[tabLine.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                rawSession = suffix.isEmpty ? nil : suffix
                tabLine = String(tabLine[..<separator]).trimmingCharacters(in: .whitespaces)
            }
            guard !tabLine.isEmpty else { continue }

            // `ssh://host/abs/path` is a remote tab; anything else is local and
            // keeps the historical `~` expansion.
            let location = TabLocationCodec.decode(tabLine)
            guard !location.path.isEmpty else { continue }
            let session = rawSession.map { value -> String in
                location.host == nil ? (value as NSString).expandingTildeInPath : value
            }

            if current == nil {
                profiles.append(OverlayProfile(name: Self.defaultName, tabs: []))
                current = profiles.count - 1
            }
            guard let index = current else { continue }
            profiles[index].tabs.append(ProfileTab(
                path: TabLocationCodec.encode(host: location.host, path: location.path),
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
    /// `--<encoded-cwd>--`, pi's on-disk grouping name for a project folder.
    static func encodedDirectoryName(for path: String) -> String {
        var stripped = path
        if stripped.hasPrefix("/") { stripped.removeFirst() }
        return "--"
            + stripped.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            + "--"
    }

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
        return agentDirectory
            .appendingPathComponent("sessions")
            .appendingPathComponent(encodedDirectoryName(for: resolved))
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
    /// `RemotePiSessionStore` feeds the same parser with fetched head/tail
    /// bytes, so local and remote session rows label sessions identically.
    static func summarize(_ path: String) -> (name: String?, preview: String?)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        let tailLength = min(size, 96 * 1024)
        try? handle.seek(toOffset: size - tailLength)
        let tail = (try? handle.readToEnd()) ?? Data()

        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: Int(min(size, 64 * 1024)))) ?? Data()

        return summarize(head: head, tail: tail)
    }

    static func summarize(head: Data, tail: Data) -> (name: String?, preview: String?) {
        // Name: latest session_info in the tail.
        var name: String?
        for line in tail.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_info",
                  let value = object["name"] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            name = trimmed.isEmpty ? nil : trimmed
        }

        // Preview: first user message in the head.
        var preview: String?
        for line in head.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "user",
                  let text = messageText(message) else { continue }
            preview = text
            break
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
    private static let lock = NSLock()

    static func loginShell() -> [String: String] {
        // Remote session listing and tab launches can ask concurrently from
        // background queues; only the first call needs to run the shell.
        lock.lock()
        defer { lock.unlock() }
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
// Remote hosts (RPC over SSH)
// ---------------------------------------------------------------------------

/// An SSH destination: either a `~/.ssh/config` alias or `user@host`, with an
/// optional port. The overlay never handles credentials itself; it runs the
/// system `ssh`, which uses the user's keys and config.
struct RemoteHost: Equatable, Hashable {
    let name: String
    let port: Int?

    var display: String { port.map { "\(name):\($0)" } ?? name }

    static func parse(_ raw: String) -> RemoteHost? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }

        // Bracketed IPv6: [::1] or [::1]:2222
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let port = Int(rest.dropFirst()) else { return nil }
                return RemoteHost(name: host, port: port)
            }
            return rest.isEmpty ? RemoteHost(name: host, port: nil) : nil
        }

        // user@host:2222 — only treat the suffix as a port when it is numeric
        // and there is no earlier colon (which would be a bare IPv6 address).
        if let colon = trimmed.lastIndex(of: ":"), !trimmed[..<colon].contains(":") {
            let portText = trimmed[trimmed.index(after: colon)...]
            if !portText.isEmpty,
               portText.allSatisfy(\.isNumber),
               let port = Int(portText) {
                return RemoteHost(name: String(trimmed[..<colon]), port: port)
            }
        }
        return RemoteHost(name: trimmed, port: nil)
    }
}

/// `profiles.conf` round-trip for a tab's location. Local tabs keep the plain
/// path they always had; remote tabs use `ssh://host[:port]/abs/path` so the
/// existing `path<TAB>session` column shape is unchanged.
enum TabLocationCodec {
    static func encode(host: RemoteHost?, path: String) -> String {
        guard let host else { return path }
        let authority = host.port.map { "\(host.name):\($0)" } ?? host.name
        var remotePath = path
        if remotePath.hasPrefix("~") {
            remotePath = "/" + remotePath
        } else if !remotePath.hasPrefix("/") {
            remotePath = "/" + remotePath
        }
        return "ssh://\(authority)\(remotePath)"
    }

    static func decode(_ raw: String) -> (host: RemoteHost?, path: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("ssh://") else {
            return (nil, (trimmed as NSString).expandingTildeInPath)
        }

        let rest = String(trimmed.dropFirst("ssh://".count))
        guard let slash = rest.firstIndex(of: "/") else { return (nil, rest) }
        let authority = String(rest[..<slash])
        var path = String(rest[slash...])
        // `ssh://host/~/code` means `~/code` on the remote side.
        if path.hasPrefix("/~") { path.removeFirst() }
        guard let host = RemoteHost.parse(authority) else { return (nil, path) }
        return (host, path)
    }
}

/// Runs short-lived commands on a remote host (`pi` lookup, directory
/// validation, session listing). The long-lived RPC stream has its own
/// transport in `RpcSession`; these helpers never touch that stdin.
enum RemotePi {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        var ok: Bool { status == 0 }
    }

    static var sshBinary: String {
        let env = ProcessInfo.processInfo.environment["PI_OVERLAY_SSH"]
        if let env, !env.isEmpty { return (env as NSString).expandingTildeInPath }
        return "/usr/bin/ssh"
    }

    /// Login shell used for one-shot remote commands. It gives us the remote
    /// user's PATH (Homebrew, ~/.local/bin, nvm) and their exported variables;
    /// it never carries the local environment. May contain arguments
    /// (`bash -l`); each word is quoted separately.
    static var remoteShell: String {
        let env = ProcessInfo.processInfo.environment["PI_OVERLAY_REMOTE_SHELL"]
        if let env, !env.isEmpty { return env }
        return "sh"
    }

    static var remotePiOverride: String? {
        guard let value = ProcessInfo.processInfo.environment["PI_OVERLAY_REMOTE_PI"],
              !value.isEmpty else { return nil }
        return value
    }

    /// Shell prologue that expands a leading `~` in the variable `name`.
    /// The overlay single-quotes every remote path (so the shell cannot expand
    /// it), and `cd '~/code'` would otherwise look for a literal `~` directory.
    static func homeExpansion(for name: String) -> String {
        """
        case "$\(name)" in
          "~") \(name)="$HOME" ;;
          "~/"*) \(name)="$HOME/${\(name)#\\~/}" ;;
        esac
        """
    }

    /// Shared SSH options: no pty (so stdout stays raw JSONL), fail instead of
    /// prompting (a GUI app has no tty), keepalives, and connection reuse so
    /// several tabs to one host share a single TCP connection.
    static func sshArguments(host: RemoteHost, extra: [String] = []) -> [String] {
        var args = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        if let port = host.port {
            args.append(contentsOf: ["-p", String(port)])
        }
        if ProcessInfo.processInfo.environment["PI_OVERLAY_SSH_CONTROL"] != "0" {
            // Keep the path short: ControlPath must fit in a unix socket path
            // (104 bytes on macOS) including the 40-char `%C` hash.
            let controlPath = "/tmp/pi-overlay-ssh-%C"
            args.append(contentsOf: [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=10m",
            ])
        }
        args.append(host.name)
        args.append(contentsOf: extra)
        return args
    }

    /// ssh joins its remote arguments with spaces before handing them to the
    /// server's shell, so the script has to be quoted *inside* one argument.
    /// Passing `[shell, "-lc", script]` as separate argv loses the quoting and
    /// runs only the first word of the script (`sh -lc cd …` → `cd` with no
    /// argument, i.e. the remote home).
    static func remoteCommand(_ script: String) -> String {
        let shellWords = remoteShell
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { PiLauncher.shellQuote(String($0)) }
            .joined(separator: " ")
        return "\(shellWords) -lc \(PiLauncher.shellQuote(script))"
    }

    /// Runs `script` in the remote login shell and captures stdout/stderr.
    /// Uses temp files so a large listing cannot deadlock on a full pipe.
    /// Blocking: call from a background queue only.
    static func run(
        host: RemoteHost,
        script: String,
        timeout: TimeInterval = 25
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshBinary)
        process.arguments = sshArguments(
            host: host,
            extra: [remoteCommand(script)]
        )
        // The ssh *client* needs the local env for HOME/PATH/SSH_AUTH_SOCK. The
        // remote pi's environment comes from the remote login shell instead.
        process.environment = PiEnvironment.loginShell()

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-overlay-remote-\(UUID().uuidString)", isDirectory: true)
        let outURL = base.appendingPathComponent("stdout")
        let errURL = base.appendingPathComponent("stderr")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try? FileHandle(forWritingTo: outURL)
        let errHandle = try? FileHandle(forWritingTo: errURL)
        process.standardOutput = outHandle ?? FileHandle.nullDevice
        process.standardError = errHandle ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        var status: Int32 = -1
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                debugLog("remote: ssh \(host.display) timed out after \(Int(timeout))s")
                process.terminate()
                process.waitUntilExit()
            } else {
                process.waitUntilExit()
                status = process.terminationStatus
            }
        } catch {
            debugLog("remote: ssh \(host.display) launch failed: \(error)")
        }

        try? outHandle?.close()
        try? errHandle?.close()
        let stdout = (try? Data(contentsOf: outURL)) ?? Data()
        let stderr = ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: base)
        return Result(status: status, stdout: stdout, stderr: stderr)
    }

    /// Resolves the remote working directory (`cd` + `pwd -P`) and looks for
    /// `pi` before a tab is created, so a typo becomes an alert instead of a
    /// dead tab.
    static func prepare(
        host: RemoteHost,
        path: String
    ) -> (path: String, pi: String?, error: String) {
        let failure = PiLauncher.shellQuote("pi-overlay-native: cannot cd to \(path)")
        let script = """
        target=\(PiLauncher.shellQuote(path))
        \(homeExpansion(for: "target"))
        cd "$target" || { printf '%s\\n' \(failure) >&2; exit 9; }
        printf 'CWD\\t%s\\n' "$(pwd -P)"
        printf 'PI\\t%s\\n' "$(command -v pi 2>/dev/null || true)"
        """
        let result = run(host: host, script: script, timeout: 20)
        guard result.ok else {
            return (path, nil, result.stderr.isEmpty
                ? "ssh exited with status \(result.status)"
                : result.stderr)
        }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        var resolved: String?
        var pi: String?
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            switch fields[0] {
            case "CWD": resolved = String(fields[1])
            case "PI": pi = String(fields[1])
            default: continue
            }
        }
        guard let resolved, !resolved.isEmpty else {
            return (path, nil, "no working directory reported")
        }
        return (resolved, pi, "")
    }

    /// Lists the immediate subdirectories of `path` for the folder browser.
    /// One ssh round trip; hidden folders are skipped (the path field can still
    /// be used to jump into one).
    static func listDirectories(
        host: RemoteHost,
        path: String
    ) -> (path: String, dirs: [String], error: String) {
        let failure = PiLauncher.shellQuote("pi-overlay-native: cannot cd to \(path)")
        let script = """
        target=\(PiLauncher.shellQuote(path))
        \(homeExpansion(for: "target"))
        cd "$target" 2>/dev/null || { printf '%s\\n' \(failure) >&2; exit 9; }
        printf 'CWD\\t%s\\n' "$(pwd -P)"
        for d in */; do
          [ -d "$d" ] || continue
          printf 'D\\t%s\\n' "${d%/}"
        done
        """
        let result = run(host: host, script: script, timeout: 20)
        guard result.ok else {
            return (path, [], result.stderr.isEmpty
                ? "ssh exited with status \(result.status)"
                : result.stderr)
        }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        var resolved: String?
        var dirs: [String] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            switch fields[0] {
            case "CWD": resolved = String(fields[1])
            case "D": dirs.append(String(fields[1]))
            default: break
            }
        }
        guard let resolved, !resolved.isEmpty else {
            return (path, [], "no working directory reported")
        }
        return (resolved, dirs, "")
    }
}

/// Remote counterpart of `PiSessionStore.list`. One SSH round trip per refresh:
/// the remote script lists the project's session files (`ls -t`, newest first)
/// and returns the bounded head/tail bytes base64-encoded. Parsing stays local
/// and shared with the on-disk reader, so labels look identical.
enum RemotePiSessionStore {
    static func list(host: RemoteHost, path: String, limit: Int = 40) -> [PiSessionInfo] {
        let script = """
        target=\(PiLauncher.shellQuote(path))
        \(RemotePi.homeExpansion(for: "target"))
        cd "$target" 2>/dev/null || exit 0
        cwd=$(pwd -P)
        enc=$(printf '%s' "$cwd" | sed 's|^/||; s|[/\\\\:]|-|g')
        dir="${PI_CODING_AGENT_SESSION_DIR:-}"
        if [ -z "$dir" ]; then
          base="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
          dir="$base/sessions/--$enc--"
        fi
        [ -d "$dir" ] || exit 0
        b64() {
          if command -v base64 >/dev/null 2>&1; then base64 | tr -d '\\n\\r'; else openssl base64 -A 2>/dev/null; fi
        }
        n=0
        for f in $(ls -t "$dir"/*.jsonl 2>/dev/null); do
          n=$((n+1)); [ "$n" -gt \(limit) ] && break
          mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
          size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          head=$(head -c 65536 "$f" 2>/dev/null | b64)
          tail=$(tail -c 98304 "$f" 2>/dev/null | b64)
          printf 'F\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$f" "$mt" "$size" "$head" "$tail"
        done
        """

        let result = RemotePi.run(host: host, script: script)
        guard result.ok else {
            if !result.stderr.isEmpty {
                debugLog("remote sessions \(host.display): \(result.stderr)")
            }
            return []
        }
        guard let text = String(data: result.stdout, encoding: .utf8) else { return [] }

        var infos: [PiSessionInfo] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6, fields[0] == "F" else { continue }
            let filePath = String(fields[1])
            let modified = TimeInterval(fields[2]).map(Date.init(timeIntervalSince1970:))
                ?? Date.distantPast
            let head = Data(base64Encoded: String(fields[4])) ?? Data()
            let tail = Data(base64Encoded: String(fields[5])) ?? Data()
            if head.isEmpty && tail.isEmpty { continue }
            let summary = PiSessionStore.summarize(head: head, tail: tail)
            infos.append(PiSessionInfo(
                path: filePath,
                name: summary.name,
                preview: summary.preview,
                modified: modified
            ))
        }
        let sorted = infos.sorted { $0.modified > $1.modified }
        if sorted.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debugLog(
                "remote sessions \(host.display): no parseable records; "
                    + "first line: \(String(text.prefix(120)))"
            )
        } else {
            debugLog("remote sessions \(host.display):\(path) count=\(sorted.count)")
        }
        return sorted
    }
}

/// NSTableView that reports double-clicks from `mouseDown` rather than through
/// `doubleAction`. View-based cells can consume the second click, which made
/// `doubleAction` unreliable in the folder browser (the row was selected but
/// the action never fired).
final class FolderTableView: NSTableView {
    var onDoubleClickRow: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount >= 2 else { return }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        onDoubleClickRow?(row)
    }
}

/// Sheet showing the folders inside one directory on a remote host. The path
/// field is editable, so browsing is a convenience rather than a restriction,
/// and `~` is resolved on the remote side by `RemotePi.listDirectories`.
final class RemoteFolderBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let host: RemoteHost
    private let panel: NSPanel
    private let pathField: NSTextField
    private let tableView: FolderTableView
    private let statusLabel: NSTextField
    private let openButton: NSButton
    private var currentPath: String
    private var directories: [String] = []
    private var loadToken = 0
    private var finished = false

    var onChoose: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(host: RemoteHost, startPath: String) {
        self.host = host
        self.currentPath = startPath

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Open remote folder — \(host.display)"
        panel.isFloatingPanel = true
        panel.delegate = nil

        pathField = NSTextField(frame: NSRect(x: 16, y: 394, width: 420, height: 24))
        pathField.stringValue = startPath
        pathField.placeholderString = "/absolute/path or ~/code/project"
        pathField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        openButton = NSButton(title: "Open Folder", target: nil, action: nil)
        tableView = FolderTableView(frame: .zero)
        statusLabel = NSTextField(labelWithString: "")

        super.init()

        panel.setContentSize(NSSize(width: 540, height: 440))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 440))
        content.autoresizingMask = [.width, .height]

        let pathLabel = NSTextField(labelWithString: "Remote directory")
        pathLabel.frame = NSRect(x: 16, y: 420, width: 300, height: 16)
        pathLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        content.addSubview(pathLabel)

        pathField.target = self
        pathField.action = #selector(go)
        pathField.autoresizingMask = [.width]
        content.addSubview(pathField)

        let goButton = NSButton(title: "Go", target: self, action: #selector(go))
        goButton.bezelStyle = .rounded
        goButton.frame = NSRect(x: 444, y: 392, width: 80, height: 26)
        goButton.autoresizingMask = [.minXMargin]
        content.addSubview(goButton)

        let upButton = NSButton(title: "↑ Up", target: self, action: #selector(goUp))
        upButton.bezelStyle = .rounded
        upButton.frame = NSRect(x: 16, y: 360, width: 76, height: 26)
        content.addSubview(upButton)

        let enterButton = NSButton(title: "Enter", target: self, action: #selector(openSelected))
        enterButton.bezelStyle = .rounded
        enterButton.frame = NSRect(x: 98, y: 360, width: 76, height: 26)
        content.addSubview(enterButton)

        let hint = NSTextField(labelWithString: "Double-click a folder to open it")
        hint.frame = NSRect(x: 184, y: 364, width: 340, height: 16)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.autoresizingMask = [.width]
        content.addSubview(hint)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 70, width: 508, height: 282))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dir"))
        column.width = 480
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 20
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onDoubleClickRow = { [weak self] row in
            self?.open(row: row)
        }
        scroll.documentView = tableView
        content.addSubview(scroll)

        statusLabel.frame = NSRect(x: 16, y: 46, width: 508, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 348, y: 12, width: 82, height: 28)
        cancel.autoresizingMask = [.minXMargin]
        content.addSubview(cancel)

        openButton.target = self
        openButton.action = #selector(chooseCurrent)
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.frame = NSRect(x: 436, y: 12, width: 88, height: 28)
        openButton.autoresizingMask = [.minXMargin]
        content.addSubview(openButton)

        panel.contentView = content
        panel.delegate = self
        panel.initialFirstResponder = pathField
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onCancel?()
    }

    func begin(for parent: NSWindow) {
        parent.beginSheet(panel)
        load(currentPath)
    }

    // MARK: - Loading

    @objc private func go() {
        load(pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func goUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    private func load(_ rawPath: String) {
        var path = rawPath
        if path.isEmpty { path = "/" }
        pathField.stringValue = path
        statusLabel.stringValue = "Connecting…"
        statusLabel.textColor = .secondaryLabelColor

        loadToken += 1
        let token = loadToken
        let host = self.host
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RemotePi.listDirectories(host: host, path: path)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                if !result.error.isEmpty {
                    debugLog("remote browser: \(host.display):\(path) failed: \(result.error)")
                    self.statusLabel.stringValue = result.error
                    self.statusLabel.textColor = .systemRed
                    return
                }
                debugLog("remote browser: \(host.display):\(result.path) dirs=\(result.dirs.count)")
                self.currentPath = result.path
                self.pathField.stringValue = result.path
                self.directories = result.dirs.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                self.tableView.reloadData()
                self.tableView.deselectAll(nil)
                if self.directories.isEmpty {
                    self.statusLabel.stringValue = "No subfolders — \u{201c}Open Folder\u{201d} uses this one"
                } else {
                    self.statusLabel.stringValue = "\(self.directories.count) folder(s)"
                }
                self.statusLabel.textColor = .secondaryLabelColor
                self.panel.makeFirstResponder(self.pathField)
            }
        }
    }

    // MARK: - Actions

    @objc private func openSelected() {
        open(row: tableView.selectedRow)
    }

    private func open(row: Int) {
        guard row >= 0 else { return }
        if row == 0 {
            goUp()
        } else if directories.indices.contains(row - 1) {
            debugLog("remote browser: entering \(directories[row - 1])")
            load(currentPath + "/" + directories[row - 1])
        }
    }

    @objc private func chooseCurrent() {
        choose(currentPath)
    }

    private func choose(_ path: String) {
        guard !path.isEmpty else { return }
        finish()
        onChoose?(path)
    }

    @objc private func cancel() {
        finish()
        onCancel?()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        directories.count + 1
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTextField
            ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.font = NSFont.systemFont(ofSize: 12)
                field.lineBreakMode = .byTruncatingMiddle
                field.refusesFirstResponder = true
                return field
            }()
        if row == 0 {
            cell.stringValue = ".."
            cell.textColor = .secondaryLabelColor
        } else {
            let name = directories[row - 1]
            cell.stringValue = "\u{1f4c1} \(name)"
            cell.textColor = .labelColor
        }
        return cell
    }
}

// ---------------------------------------------------------------------------
// RPC session (self mode)
// ---------------------------------------------------------------------------

final class RpcSession {
    let directory: URL
    /// Non-nil when pi runs on another machine and this session drives it
    /// through `ssh -T host pi --mode rpc`.
    let host: RemoteHost?
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

    var isRemote: Bool { host != nil }
    var processIdentifier: Int32 { process.processIdentifier }

    /// Header label: the pid shown is ssh's on the Mac for remote tabs; the
    /// remote pi pid is not visible to us and is not needed.
    var processLabel: String {
        isRemote ? "ssh \(processIdentifier)" : "pi \(processIdentifier)"
    }

    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?

    static func launch(
        in directory: URL,
        host: RemoteHost? = nil,
        sessionFile: String? = nil
    ) throws -> RpcSession {
        if let host {
            return try RpcSession(
                directory: directory,
                host: host,
                piPath: nil,
                sessionFile: sessionFile
            )
        }
        guard let pi = PiLauncher.resolvePiBinary() else {
            throw PiLaunchError.piNotFound
        }
        return try RpcSession(
            directory: directory,
            host: nil,
            piPath: pi,
            sessionFile: sessionFile
        )
    }

    /// Remote bootstrap. Runs in the remote login shell so `pi` resolves with
    /// the user's normal PATH; it never receives the local environment.
    static func remoteLaunchScript(directory: URL, sessionFile: String?) -> String {
        let quotedPath = PiLauncher.shellQuote(directory.path)
        let failure = PiLauncher.shellQuote("pi-overlay-native: cannot cd to \(directory.path)")
        var script = "target=\(quotedPath)\n"
        script += RemotePi.homeExpansion(for: "target") + "\n"
        script += "cd \"$target\" || { printf '%s\\n' \(failure) >&2; exit 9; }\n"
        if let override = RemotePi.remotePiOverride {
            script += "p=\(PiLauncher.shellQuote(override))\n"
        } else {
            script += "p=pi\n"
            script += "if ! command -v pi >/dev/null 2>&1; then "
                + "for c in \"$HOME/.local/bin/pi\" \"$HOME/.bun/bin/pi\" \"$HOME/n/bin/pi\" "
                + "\"$HOME/node_modules/.bin/pi\" /opt/homebrew/bin/pi /usr/local/bin/pi; "
                + "do [ -x \"$c\" ] && { p=\"$c\"; break; }; done; fi\n"
            script += "if [ \"$p\" = pi ] && ! command -v pi >/dev/null 2>&1; then "
                + "printf '%s\\n' 'pi-overlay-native: pi not found on the remote host "
                + "(set PI_OVERLAY_REMOTE_PI to its path)' >&2; exit 127; fi\n"
        }
        script += "exec \"$p\" --mode rpc"
        if let sessionFile {
            script += " --session \(PiLauncher.shellQuote(sessionFile))"
        }
        return script
    }

    private init(
        directory: URL,
        host: RemoteHost?,
        piPath: String?,
        sessionFile: String?
    ) throws {
        self.directory = directory
        self.host = host
        self.parseQueue = DispatchQueue(label: "pi-overlay.rpc.\(UUID().uuidString)")

        process = Process()
        if let host {
            process.executableURL = URL(fileURLWithPath: RemotePi.sshBinary)
            let script = Self.remoteLaunchScript(directory: directory, sessionFile: sessionFile)
            process.arguments = RemotePi.sshArguments(
                host: host,
                extra: [RemotePi.remoteCommand(script)]
            )
        } else {
            process.executableURL = URL(fileURLWithPath: piPath ?? "")
            var arguments = ["--mode", "rpc"]
            if let sessionFile {
                arguments.append(contentsOf: ["--session", sessionFile])
            }
            process.arguments = arguments
            process.currentDirectoryURL = directory
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // The local env matters for a local pi (Finder-launched apps get a
        // minimal PATH) and for the ssh client (HOME/SSH_AUTH_SOCK). A remote
        // pi gets its environment from the remote login shell instead.
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

        if let host {
            debugLog("rpc launched dir=\(directory.path) host=\(host.display) ssh=\(RemotePi.sshBinary)")
        } else {
            debugLog("rpc launched dir=\(directory.path) pi=\(piPath ?? "")")
        }
    }

    @discardableResult
    func prompt(_ message: String, images: [[String: Any]] = []) -> Bool {
        var record: [String: Any] = [
            "id": nextID(),
            "type": "prompt",
            "message": message,
        ]
        if !images.isEmpty {
            record["images"] = images
        }
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

    /// Token totals and the current context-window estimate for the footer.
    func requestSessionStats() {
        _ = send(["type": "get_session_stats"])
    }

    /// Manual compaction. `customInstructions` focuses the summary, same as
    /// `/compact [instructions]` in the TUI.
    func requestCompact(customInstructions: String?) {
        var command: [String: Any] = ["type": "compact"]
        if let customInstructions { command["customInstructions"] = customInstructions }
        _ = send(command)
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

    /// Discoverable commands (extension commands, prompt templates, skills).
    /// The palette currently keeps only `skill:*` and `mcp`.
    func requestCommands() {
        _ = send(["type": "get_commands"])
    }

    func setSessionName(_ name: String) {
        _ = send(["type": "set_session_name", "name": name])
    }

    func setModel(provider: String, modelId: String) {
        _ = send([
            "type": "set_model",
            "provider": provider,
            "modelId": modelId,
        ])
    }

    func requestThinkingLevels() {
        _ = send(["type": "get_available_thinking_levels"])
    }

    func setThinkingLevel(_ level: String) {
        _ = send(["type": "set_thinking_level", "level": level])
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

    /// Visible thinking/reasoning blocks in an assistant message.
    static func messageThinking(from message: [String: Any]) -> String {
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard block["type"] as? String == "thinking" else { return nil }
            return block["thinking"] as? String
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Visible thinking/reasoning that produced this answer.
    var thinking: String = ""
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
    /// Set when this tab's pi runs on another machine over SSH. `directory`
    /// then holds the absolute remote working directory.
    var remoteHost: RemoteHost?
    var session: RpcSession?
    var isLaunching = false
    var status: KeyTapeView.AgentStatus = .idle
    var exitStatus: Int32?
    var currentModel: [String: Any]?
    var models: [[String: Any]]?
    var sessionFile: String?
    var sessionName: String?
    /// Name just set through /name; protects it from a stale get_state reply.
    var pendingSessionName: String?
    /// Set while /reload is restarting the RPC child.
    var reloadPending = false
    /// Set while a compaction is running for this tab. Compaction makes its own
    /// model call that can take far longer than a flash, so the status has to hold
    /// until `compaction_end` rather than reverting after 1.4s.
    var isCompacting = false
    /// The last compaction's before/after counts, drawn in the footer. Compaction is
    /// the only event that moves the meter without an answer, so the footer has to
    /// show what the number came from.
    var compactedBefore: Int?
    var compactedAfter: Int?
    var assistantText = ""
    var streamingText = ""
    /// Thinking/reasoning for the current turn and the live stream.
    var thinkingText = ""
    var streamingThinking = ""
    /// Show the thinking section in the response panel for this tab.
    var showThinking = false
    var latestAnswerText = ""
    /// Last provider/command error, so a settled run with no text can still
    /// leave a visible message in the response panel.
    var lastError: String?
    var responseText = ""
    var responseExpanded = false
    var responseUserCollapsed = false
    var queries: [SessionQuery] = []
    /// Discoverable commands for this tab; filtered to skills + mcp.
    var commands: [PiCommand] = []
    var selectedQueryID: String?
    var rawText = ""
    var tape: [String] = []
    /// Reasoning effort for this tab plus the levels the current model supports.
    /// `["off"]` alone means the model cannot reason, which is what makes the
    /// dropdown read as disabled rather than missing.
    var thinkingLevel: String?
    var thinkingLevels: [String] = []

    /// Footer numbers: current context estimate, the model's context window,
    /// and the output token rate for this tab's running or last turn.
    var contextTokens: Int?
    var contextWindow: Int?
    var tokensPerSecond: Double?
    /// Wall clock when this tab's assistant response started, for the live rate.
    var responseStartedAt: Date?
    /// Output streamed so far this turn. Providers only report usage in the final
    /// chunk, so a live rate has to come from what has actually streamed.
    var streamedChars = 0
    var estimatedTokensPerSecond: Double?

    var isRemote: Bool { remoteHost != nil }

    /// Identity used for dedupe, recents and profiles.conf.
    var locationKey: String {
        TabLocationCodec.encode(host: remoteHost, path: directory?.path ?? "")
    }

    /// Short label for the tab strip and status menu.
    var displayName: String {
        let base = directory?.lastPathComponent ?? "New Tab"
        guard remoteHost != nil else { return base }
        return "\u{2601} \(base)"
    }

    var fullLocation: String {
        guard let remoteHost else { return directory?.path ?? "" }
        return "\(remoteHost.display):\(directory?.path ?? "")"
    }

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
    let thinkingPopup: ThemedPopUpButton
    let modelRefreshButton: IconButton
    let pidLabel: NSTextField
    let tabBar: NSView
    let profilePopup: NSPopUpButton
    let tabScrollView: NSScrollView
    let tabContentView: NSView
    let newTabButton: IconButton
    let voiceButton: NSButton
    let imageButton: IconButton
    let attachButton: IconButton
    let sendButton: PillButton
    let attachmentChip: PillButton
    let closeButton: IconButton
    let minimizeButton: IconButton
    let hideButton: IconButton
    let compactButton: IconButton
    let compactRestoreButton: IconButton
    let compactHideButton: IconButton
    let compactPidLabel: NSTextField
    let compactContextLabel: PillCaption
    let compactBackdrop: NSVisualEffectView
    let panelButton: IconButton
    let terminalButton: IconButton
    let topDivider: NSView
    let tabSeparator: NSView
    let sessionIcon: NSImageView
    let sessionPopup: NSPopUpButton
    let newSessionButton: IconButton
    let sessionLabel: NSTextField
    let headerDivider: NSView
    let responseButton: NSButton
    let responseDivider: NSView
    let responseCopyButton: IconButton
    let responseDownloadButton: IconButton
    let responseExpandButton: IconButton
    let responseWebView: WKWebView
    let queryPopup: NSPopUpButton
    let thinkingButton: IconButton
    let commandPalette: CommandPaletteView
    let commandPalettePanel: CommandPalettePanel
    let footerView: FooterView

    private var responseExpanded = false
    private var responseUserCollapsed = false
    private var responseText = ""
    private var sessionQueries: [SessionQuery] = []
    private var selectedQueryID: String?
    /// Latest assistant text in modes without per-tab state (tty/extension).
    private var latestResponseText = ""
    /// Images picked with the photo button, sent with the next prompt (RPC
    /// mode only). Cleared after a send or when switching tabs.
    private var pendingImages: [[String: Any]] = []
    private var pendingImageNames: [String] = []
    /// Captures `notify` records produced by the MCP command.
    private var mcpCaptureToken = 0
    private var mcpCaptureLines: [String] = []
    private var mcpCaptureUntil: Date?
    /// Local key monitor for copying selected text from the response WebView.
    private var responseCopyMonitor: Any?

    /// Footer numbers for modes without per-tab state (tty/extension), which
    /// come from the extension's `usage` event.
    private var eventContextTokens: Int?
    private var eventContextWindow: Int?
    private var eventTokensPerSecond: Double?
    private var eventEstimatedTokensPerSecond: Double?
    /// tty-mode reasoning level and its levels: the model's `thinkingLevelMap` is
    /// only readable from inside pi, so these arrive on the extension's event.
    private var eventThinkingLevel: String?
    private var eventThinkingLevels: [String] = []
    /// Redraw the footer only when a displayed number actually changes, so a
    /// streamed turn does not repaint it on every token.
    private var footerSignature = ""

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
    /// Kept while the remote folder sheet is up.
    private var remoteBrowser: RemoteFolderBrowser?

    private var isSelfMode: Bool { mode == .selfHost || mode == .selfTerminal }

    private func hasSession(for key: String) -> Bool {
        if mode == .selfHost {
            if rpcTabs.contains(where: { $0.locationKey == key && $0.session != nil }) {
                return true
            }
            return profileRuntime.values.contains { runtime in
                runtime.tabs.contains { $0.locationKey == key && $0.session != nil }
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
    /// Compact capsule mode: only the textbox (and a small restore button) is
    /// visible; the window background is transparent.
    private var isCompact = false
    private var compactRestoreFrame: NSRect?
    /// Preview runs resize the window to render a PNG and must not write the
    /// frame autosave, so the user's real window frame is kept.
    private let isPreviewMode: Bool
    private var expandedHeight: CGFloat = 0
    private var sessionInfos: [PiSessionInfo] = []
    private var sessionLoadToken = 0
    /// Width of the rendered tab strip, used to keep the + next to the tabs.
    private var tabContentWidth: CGFloat = 0
    private var statusItem: NSStatusItem?

    /// Height of the window when collapsed. RPC mode keeps only the tab strip;
    /// the other modes keep their single header row, which carries the button.
    private var collapsedHeight: CGFloat { mode == .selfHost ? Theme.tabStripHeight : 44 }

    private var baseMinSize: NSSize {
        NSSize(width: 720, height: (mode == .selfHost ? 320 : 210) + Theme.footerHeight)
    }

    /// Window height the overlay opens at: the default for a fresh launch and
    /// for a saved frame that filled the screen. A saved frame always wins.
    /// Clamped to the screen's visible height.
    private static let defaultWindowHeight: CGFloat = 695

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
        self.isPreviewMode = ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW"] != nil

        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: min(900, max(720, visible.width - 40)),
            height: min(
                Self.defaultWindowHeight,
                max(mode == .selfHost ? 320 : 210, visible.height - 40)
            )
        )
        let initialTabExtra: CGFloat = mode == .selfHost ? Theme.tabStripHeight : 0
        // Open centred on the visible frame. `visibleFrame` already excludes the
        // menu bar and Dock, and the `max` keeps a 12 pt gap at the bottom on
        // screens too short for a centred window.
        let origin = NSPoint(
            x: max(20, visible.midX - size.width / 2),
            y: max(visible.minY + 12, visible.midY - size.height / 2)
        )

        window = OverlayWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: (mode == .selfHost ? 320 : 210) + Theme.footerHeight)
        window.title = selfMode
            ? "pi · \(initialDirectory.lastPathComponent)"
            : "pi-overlay-native · \(ttyPath ?? "dry")"

        // Remember the size/position the user drags out. A preview run resizes the
        // window to render a PNG, so it must not persist that geometry over the
        // user's real frame.
        if !isPreviewMode {
            window.setFrameAutosaveName("PiOverlayWindow")
        }
        // One-time migration: earlier builds pinned the window 12 pt above the
        // bottom of the screen. A saved frame that is still exactly that anchor
        // means the user never moved the window, so re-centre it rather than
        // keeping the old position forever; a dragged frame is left alone.
        if !isPreviewMode, let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            var frame = window.frame
            if abs(frame.minY - (visible.minY + 12)) <= 1,
               abs(frame.midX - visible.midX) <= 1,
               frame.height < visible.height - 1 {
                frame.origin.y = visible.midY - frame.height / 2
                window.setFrame(frame, display: false)
            }
        }
        debugLog("window frame=\(NSStringFromRect(window.frame)) screen=\(NSStringFromRect((window.screen ?? NSScreen.main)?.visibleFrame ?? .zero))")
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            var restored = window.frame
            restored.size.width = max(restored.width, window.minSize.width)
            restored.size.height = max(restored.height, window.minSize.height)
            window.setFrame(restored, display: false)
        }

        // If a previous run quit while the window filled the screen, start from
        // the default centred frame instead of a screen-sized overlay.
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
                        y: max(visible.minY + 12, visible.midY - height / 2),
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
        container.layer?.backgroundColor = Theme.card.cgColor
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        container.layer?.borderColor = Theme.border.cgColor
        container.layer?.borderWidth = 1
        window.contentView = container

        // Translucent material behind the compact capsule. With a transparent
        // window this samples the desktop, so the textbox reads as glass
        // instead of a solid black bar.
        compactBackdrop = NSVisualEffectView(frame: .zero)
        compactBackdrop.material = .hudWindow
        compactBackdrop.blendingMode = .behindWindow
        compactBackdrop.state = .active
        compactBackdrop.wantsLayer = true
        compactBackdrop.layer?.masksToBounds = true
        compactBackdrop.isHidden = true
        container.addSubview(compactBackdrop, positioned: .below, relativeTo: nil)

        // status label
        statusLabel = StatusPillLabel(labelWithString: "READY")
        statusLabel.font = Theme.font(12, .semibold)
        statusLabel.textColor = .systemGreen
        statusLabel.frame = NSRect(x: 16, y: size.height - initialTabExtra - 26, width: 250, height: 20)
        container.addSubview(statusLabel)

        targetLabel = NSTextField(labelWithString: ttyPath.map { "TTY \($0)" }
            ?? (selfMode ? "STARTING PI…" : "DRY RUN"))
        targetLabel.font = Theme.mono(10, .regular)
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
        let directoryButton = ThemedPopUpButton(
            frame: NSRect(x: 138, y: size.height - initialTabExtra - 28, width: 300, height: 24),
            pullsDown: true
        )
        directoryButton.symbolName = "folder.fill"
        directoryButton.symbolTint = NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.93, alpha: 1)
        directoryButton.titleFont = Theme.font(12, .semibold)
        directoryPopup = directoryButton
        directoryPopup.controlSize = .regular
        directoryPopup.title = "📁 \(initialDirectory.lastPathComponent)"
        directoryPopup.toolTip = initialDirectory.path
        directoryPopup.isHidden = !selfMode
        container.addSubview(directoryPopup)

        // pi RPC child PID (self/RPC mode only)
        let chip = ChipLabel(labelWithString: "")
        chip.symbolName = "cpu"
        pidLabel = chip
        pidLabel.font = Theme.mono(10, .medium)
        pidLabel.textColor = Theme.textSecondary
        pidLabel.alignment = .left
        pidLabel.lineBreakMode = .byTruncatingHead
        pidLabel.isSelectable = true
        pidLabel.isHidden = mode != .selfHost
        container.addSubview(pidLabel)

        // Model dropdown (RPC self mode only)
        let modelButton = ThemedPopUpButton(
            frame: NSRect(x: 446, y: size.height - initialTabExtra - 28, width: 184, height: 24),
            pullsDown: false
        )
        modelButton.symbolName = "square.stack.3d.up.fill"
        modelButton.symbolTint = NSColor(calibratedRed: 0.35, green: 0.40, blue: 0.85, alpha: 1)
        modelButton.titleFont = Theme.font(12, .medium)
        modelPopup = modelButton
        modelPopup.controlSize = .regular
        modelPopup.addItem(withTitle: "Model…")
        modelPopup.isEnabled = false
        modelPopup.isHidden = mode != .selfHost
        modelPopup.toolTip = "Model for this pi RPC session"
        container.addSubview(modelPopup)

        // Reasoning-effort dropdown. Pi owns the level list; the overlay only
        // mirrors it, so there is nothing to persist here.
        let thinkingChoice = ThemedPopUpButton(
            frame: NSRect(x: 446, y: size.height - initialTabExtra - 28, width: Theme.thinkingPopupWidth, height: 24),
            pullsDown: false
        )
        thinkingChoice.symbolName = "brain"
        thinkingChoice.symbolTint = Theme.thinkingTint
        thinkingChoice.titleFont = Theme.font(12, .medium)
        thinkingPopup = thinkingChoice
        thinkingPopup.controlSize = .regular
        thinkingPopup.addItem(withTitle: "Reasoning…")
        thinkingPopup.isEnabled = false
        thinkingPopup.isHidden = !(mode == .selfHost || mode == .tty)
        thinkingPopup.toolTip = "Reasoning effort for this model"
        container.addSubview(thinkingPopup)

        modelRefreshButton = IconButton(
            symbol: "arrow.clockwise",
            size: 13,
            tint: Theme.textSecondary,
            tooltip: "Refresh the available models"
        )
        modelRefreshButton.isHidden = mode != .selfHost
        container.addSubview(modelRefreshButton)

        // Saved sessions for this directory (RPC self mode only)
        sessionLabel = NSTextField(labelWithString: "Sessions")
        sessionLabel.font = Theme.font(12, .semibold)
        sessionLabel.textColor = Theme.text
        sessionLabel.alignment = .left
        sessionLabel.isHidden = mode != .selfHost
        container.addSubview(sessionLabel)

        let sessionsButton = ThemedPopUpButton(frame: .zero, pullsDown: false)
        sessionsButton.titleFont = Theme.font(12, .medium)
        sessionPopup = sessionsButton
        sessionPopup.controlSize = .regular
        sessionPopup.addItem(withTitle: "Sessions")
        sessionPopup.isEnabled = false
        sessionPopup.toolTip = "Saved pi sessions for this folder"
        sessionPopup.isHidden = mode != .selfHost
        container.addSubview(sessionPopup)

        // Start a fresh session (same as pi's /new) next to the sessions list.
        newSessionButton = IconButton(
            symbol: "plus",
            size: 15,
            tint: Theme.textSecondary,
            tooltip: "New session (like /new)"
        )
        newSessionButton.layer?.cornerRadius = Theme.fieldRadius
        newSessionButton.layer?.borderWidth = 1
        newSessionButton.layer?.borderColor = Theme.border.cgColor
        newSessionButton.baseFill = Theme.field
        newSessionButton.isHidden = mode != .selfHost
        newSessionButton.isEnabled = false
        container.addSubview(newSessionButton)

        // Tab strip (RPC self mode only)
        tabBar = NSView(frame: .zero)
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = Theme.tabStrip.cgColor
        tabBar.isHidden = mode != .selfHost
        container.addSubview(tabBar)

        tabSeparator = NSView(frame: .zero)
        tabSeparator.wantsLayer = true
        tabSeparator.layer?.backgroundColor = Theme.border.cgColor
        tabBar.addSubview(tabSeparator)

        // Profile switcher: profiles are the parent of tabs and appear first in
        // the tab strip. The menu is rebuilt whenever the profile list changes.
        let profileButton = ThemedPopUpButton(
            frame: NSRect(x: 4, y: 1, width: 140, height: 24),
            pullsDown: true
        )
        profileButton.symbolName = "person.fill"
        profileButton.symbolTint = NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.93, alpha: 1)
        profileButton.titleFont = Theme.font(12, .semibold)
        profilePopup = profileButton
        profilePopup.controlSize = .regular
        profilePopup.title = ProfileStore.defaultName
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

        tabContentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 34))
        tabScrollView.documentView = tabContentView

        newTabButton = IconButton(
            symbol: "plus",
            size: 16,
            tint: Theme.textSecondary,
            tooltip: "New tab (Ctrl+T)"
        )
        newTabButton.isHidden = mode != .selfHost
        tabBar.addSubview(newTabButton)

        // Top-right icon cluster. In self mode these live in the tab strip so
        // they stay reachable when the overlay is collapsed.
        terminalButton = IconButton(
            symbol: "terminal",
            size: 14,
            tint: Theme.textSecondary,
            tooltip: "Diagnostics — debug log, profiles.conf, agent directory"
        )
        panelButton = IconButton(
            symbol: "sidebar.right",
            size: 14,
            tint: Theme.textSecondary,
            tooltip: "Toggle the Response panel"
        )
        hideButton = IconButton(
            symbol: "eye.slash",
            size: 14,
            tint: Theme.textSecondary,
            tooltip: "Hide the overlay — reopen it from the menu-bar icon"
        )
        hideButton.setAccessibilityLabel("Hide overlay")
        compactButton = IconButton(
            symbol: "sidebar.right",
            size: 14,
            tint: Theme.textSecondary,
            tooltip: "Compact textbox mode — hide everything but the prompt",
            rotation: -90
        )
        compactButton.setAccessibilityLabel("Compact textbox mode")
        compactRestoreButton = IconButton(
            symbol: "arrow.up.left.and.arrow.down.right",
            size: 12,
            tint: NSColor.white,
            tooltip: "Restore the full overlay"
        )
        compactRestoreButton.hoverFill = NSColor.black.withAlphaComponent(0.85)
        compactRestoreButton.baseFill = NSColor.black.withAlphaComponent(0.55)
        compactRestoreButton.layer?.cornerRadius = 13
        compactRestoreButton.isHidden = true
        container.addSubview(compactRestoreButton)
        compactHideButton = IconButton(
            symbol: "eye.slash",
            size: 12,
            tint: NSColor.white,
            tooltip: "Hide the overlay — reopen it from the menu-bar icon"
        )
        compactHideButton.hoverFill = NSColor.black.withAlphaComponent(0.85)
        compactHideButton.baseFill = NSColor.black.withAlphaComponent(0.55)
        compactHideButton.layer?.cornerRadius = 13
        compactHideButton.isHidden = true
        container.addSubview(compactHideButton)
        compactContextLabel = PillCaption(labelWithString: "")
        compactContextLabel.symbolName = "person.fill"
        compactContextLabel.isHidden = true
        container.addSubview(compactContextLabel)
        compactPidLabel = NSTextField(labelWithString: "")
        compactPidLabel.font = Theme.mono(11, .medium)
        compactPidLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        compactPidLabel.alignment = .right
        compactPidLabel.lineBreakMode = .byTruncatingHead
        compactPidLabel.isHidden = true
        minimizeButton = IconButton(
            symbol: "chevron.down",
            size: 14,
            tint: Theme.textSecondary,
            tooltip: "Minimize to the tab strip (Cmd+M)"
        )
        closeButton = IconButton(
            symbol: "xmark",
            size: 14,
            tint: Theme.textSecondary,
            tooltip: "Close overlay"
        )
        for button in [terminalButton, panelButton, hideButton, compactButton, minimizeButton, closeButton] {
            container.addSubview(button)
        }

        // Speak / image / attach buttons live inside the dark input card.
        voiceButton = NSButton(title: "", target: nil, action: nil)
        voiceButton.isBordered = false
        voiceButton.wantsLayer = true
        voiceButton.layer?.cornerRadius = 10
        voiceButton.layer?.borderWidth = 1
        voiceButton.layer?.borderColor = Theme.inputBorder.cgColor
        voiceButton.layer?.backgroundColor = Theme.inputRaised.cgColor
        voiceButton.imagePosition = .imageOnly
        voiceButton.imageScaling = .scaleProportionallyDown
        voiceButton.frame = NSRect(x: 0, y: 0, width: 34, height: 34)
        voiceButton.toolTip = "Speak (Option+V)"

        imageButton = IconButton(
            symbol: "photo",
            size: 15,
            tint: Theme.inputText,
            tooltip: "Attach an image to the next prompt"
        )
        imageButton.hoverFill = Theme.inputRaised
        attachButton = IconButton(
            symbol: "paperclip",
            size: 15,
            tint: Theme.inputText,
            tooltip: "Insert a file path into the prompt"
        )
        attachButton.hoverFill = Theme.inputRaised

        sendButton = PillButton(title: "⌘ ↵   Send", target: nil, action: nil)
        sendButton.fillColor = Theme.inputRaised
        sendButton.textColor = Theme.inputText
        sendButton.font = Theme.font(12, .semibold)
        sendButton.toolTip = "Send the prompt (Return)"

        attachmentChip = PillButton(title: "", target: nil, action: nil)
        attachmentChip.fillColor = Theme.inputRaised
        attachmentChip.textColor = Theme.inputMuted
        attachmentChip.font = Theme.font(10, .medium)
        attachmentChip.toolTip = "Clear attached images"
        attachmentChip.isHidden = true

        // key tape
        keyTape = KeyTapeView(frame: NSRect(x: 10, y: 10, width: size.width - 20, height: 120))
        keyTape.wantsLayer = true
        keyTape.layer?.cornerRadius = Theme.inputRadius
        keyTape.layer?.masksToBounds = true
        keyTape.addSubview(voiceButton)
        keyTape.addSubview(imageButton)
        keyTape.addSubview(attachButton)
        keyTape.addSubview(sendButton)
        keyTape.addSubview(attachmentChip)
        keyTape.addSubview(compactPidLabel)
        container.addSubview(keyTape)

        // Collapsible final-response panel under the key tape.
        responseButton = NSButton(title: "▸  Response", target: nil, action: nil)
        responseButton.isBordered = false
        responseButton.font = Theme.font(12, .semibold)
        responseButton.contentTintColor = Theme.text
        responseButton.alignment = .left
        responseButton.isHidden = true
        container.addSubview(responseButton)

        responseDivider = NSView(frame: .zero)
        responseDivider.wantsLayer = true
        responseDivider.layer?.backgroundColor = Theme.border.cgColor
        responseDivider.isHidden = true
        container.addSubview(responseDivider)

        // Prompt history: pick a previous question to see the answer that
        // followed it. Sits between the textbox and the response panel.
        let historyButton = ThemedPopUpButton(frame: .zero, pullsDown: false)
        historyButton.titleFont = Theme.font(12, .regular)
        queryPopup = historyButton
        queryPopup.controlSize = .regular
        queryPopup.addItem(withTitle: "Latest answer")
        queryPopup.isHidden = true
        queryPopup.isEnabled = false
        queryPopup.toolTip = "Show the answer for a previous prompt in this session"
        container.addSubview(queryPopup)

        thinkingButton = IconButton(
            symbol: "lightbulb",
            size: 14,
            tint: Theme.textTertiary,
            tooltip: "Show thinking (reasoning)"
        )
        thinkingButton.isHidden = mode != .selfHost
        container.addSubview(thinkingButton)

        responseCopyButton = IconButton(
            symbol: "doc.on.doc",
            size: 13,
            tint: Theme.textSecondary,
            tooltip: "Copy the response"
        )
        responseDownloadButton = IconButton(
            symbol: "arrow.down.to.line",
            size: 13,
            tint: Theme.textSecondary,
            tooltip: "Save the response as Markdown"
        )
        responseExpandButton = IconButton(
            symbol: "arrow.up.left.and.arrow.down.right",
            size: 13,
            tint: Theme.textSecondary,
            tooltip: "Expand or collapse the response panel"
        )
        for button in [responseCopyButton, responseDownloadButton, responseExpandButton] {
            button.isHidden = true
            container.addSubview(button)
        }

        sessionIcon = NSImageView(frame: .zero)
        sessionIcon.image = Theme.symbol("bubble.left", size: 15, color: Theme.textSecondary)
        sessionIcon.imageScaling = .scaleProportionallyDown
        sessionIcon.isHidden = mode != .selfHost
        container.addSubview(sessionIcon)

        headerDivider = NSView(frame: .zero)
        headerDivider.wantsLayer = true
        headerDivider.layer?.backgroundColor = Theme.border.cgColor
        headerDivider.isHidden = mode != .selfHost
        container.addSubview(headerDivider)

        topDivider = NSView(frame: .zero)
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = Theme.border.cgColor
        container.addSubview(topDivider)

        commandPalette = CommandPaletteView(frame: .zero)
        commandPalettePanel = CommandPalettePanel()
        commandPalettePanel.contentView = commandPalette

        responseWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        responseWebView.wantsLayer = true
        responseWebView.layer?.cornerRadius = Theme.responseRadius
        responseWebView.layer?.borderWidth = 1
        responseWebView.layer?.borderColor = Theme.border.cgColor
        responseWebView.layer?.masksToBounds = true
        responseWebView.isHidden = true
        container.addSubview(responseWebView)

        // Context usage + token rate, along the bottom edge under the panel.
        footerView = FooterView(frame: .zero)
        footerView.toolTip = "Context usage and output token rate"
        container.addSubview(footerView)

        super.init()

        window.delegate = self
        keyTape.controller = self
        commandPalette.onAccept = { [weak self] command in
            self?.acceptCommand(command)
        }
        responseCopyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCopyChord = (mods.contains(.control) || mods.contains(.command))
                && !mods.contains(.shift)
                && !mods.contains(.option)
                && event.charactersIgnoringModifiers?.lowercased() == "c"
            guard isCopyChord,
                  let webView = self.responseWebViewIfFocused() else {
                return event
            }
            self.copySelectionFromResponse(webView)
            return nil
        }
        keyTape.onStatusChange = { [weak self] _ in self?.updateSendButton() }
        // native caret; no manual blink timer needed.
        voiceButton.target = self
        voiceButton.action = #selector(toggleVoice)
        voiceButton.sendAction(on: [.leftMouseDown])
        updateVoiceButton(listening: false)
        imageButton.target = self
        imageButton.action = #selector(attachImage)
        attachButton.target = self
        attachButton.action = #selector(attachFiles)
        sendButton.target = self
        sendButton.action = #selector(sendFromButton)
        attachmentChip.target = self
        attachmentChip.action = #selector(clearAttachments)
        terminalButton.target = self
        terminalButton.action = #selector(showDiagnosticsMenu(_:))
        compactButton.target = self
        compactButton.action = #selector(toggleCompact)
        compactRestoreButton.target = self
        compactRestoreButton.action = #selector(toggleCompact)
        compactHideButton.target = self
        compactHideButton.action = #selector(hideOverlay)
        panelButton.target = self
        panelButton.action = #selector(toggleResponse)
        responseCopyButton.target = self
        responseCopyButton.action = #selector(copyResponse)
        responseDownloadButton.target = self
        responseDownloadButton.action = #selector(downloadResponse)
        responseExpandButton.target = self
        responseExpandButton.action = #selector(toggleResponse)
        closeButton.target = self
        closeButton.action = #selector(closeApp)
        closeButton.sendAction(on: [.leftMouseDown])
        minimizeButton.target = self
        minimizeButton.action = #selector(toggleMinimize)
        minimizeButton.sendAction(on: [.leftMouseDown])
        updateMinimizeButton()
        hideButton.target = self
        hideButton.action = #selector(hideOverlay)
        hideButton.sendAction(on: [.leftMouseDown])
        responseButton.target = self
        responseButton.action = #selector(toggleResponse)
        responseButton.sendAction(on: [.leftMouseDown])
        queryPopup.target = self
        queryPopup.action = #selector(querySelected(_:))
        modelRefreshButton.target = self
        modelRefreshButton.action = #selector(refreshModels)
        thinkingPopup.target = self
        thinkingPopup.action = #selector(thinkingLevelSelected(_:))
        thinkingButton.target = self
        thinkingButton.action = #selector(toggleThinking)
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

        // tty mode is a prompt for a terminal that already runs pi, so the header
        // row and the response panel have nothing to show. Open as the capsule;
        // ⤢ restores the full window.
        if mode == .tty {
            enterCompact()
        }
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
                statusLabel.stringValue = tab.isRemote ? "CONNECTING…" : "STARTING PI"
                statusLabel.textColor = .systemOrange
            } else if tab.directory == nil {
                statusLabel.stringValue = "SELECT PROJECT"
                statusLabel.textColor = .systemOrange
            } else if tab.session == nil, tab.exitStatus != nil {
                statusLabel.stringValue = tab.isRemote ? "SSH/PI EXITED" : "PI EXITED"
                statusLabel.textColor = .systemRed
            } else if tab.session == nil {
                statusLabel.stringValue = "NO PI SESSION"
                statusLabel.textColor = .systemOrange
            } else if tab.isCompacting {
                // Held status: the summary is a model call, not a flash.
                statusLabel.stringValue = "COMPACTING"
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
        voiceButton.image = Theme.symbol(
            listening ? "waveform" : "mic.fill",
            size: 15,
            color: listening ? .systemRed : Theme.inputText
        )
        voiceButton.contentTintColor = listening ? .systemRed : Theme.inputText
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
            let location = TabLocationCodec.decode(entry.path)
            let url: URL
            if let host = location.host {
                // Remote folders are not checked locally. Tabs are stored with
                // the absolute path returned by the connect flow; skip a
                // hand-edited `~` entry rather than mis-resolving it locally.
                guard location.path.hasPrefix("/") else {
                    debugLog("profiles.conf: skipping remote entry without absolute path \(entry.path)")
                    missingTabPaths.append(entry.path)
                    continue
                }
                url = URL(fileURLWithPath: location.path)
                debugLog("profiles.conf: restoring remote \(host.display):\(location.path)")
            } else {
                guard let normalized = directoryStore.normalize(location.path) else {
                    debugLog("profiles.conf: skipping missing directory \(entry.path)")
                    missingTabPaths.append(entry.path)
                    continue
                }
                url = normalized
            }
            let key = TabLocationCodec.encode(host: location.host, path: url.path)
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let tab = makeBlankTab()
            tab.remoteHost = location.host
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
            guard tab.directory != nil else { return nil }
            return ProfileTab(
                path: tab.locationKey,
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
        profilePopup.title = activeProfileName
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

    /// Installs the background menu-bar icon in every mode. It mirrors the
    /// processing/completed state of every tab in every profile, and its menu is
    /// how a hidden overlay comes back.
    func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.toolTip = "pi-overlay-native"
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

    /// Menu-bar icon: a bold Greek pi. Idle is a template image so it follows
    /// the menu-bar appearance; processing/done tint the pi orange/green.
    private func statusImage(processing: Int, done: Int) -> NSImage? {
        let color: NSColor
        let template: Bool
        if processing > 0 {
            color = .systemOrange
            template = false
        } else if done > 0 {
            color = .systemGreen
            template = false
        } else {
            color = .black
            template = true
        }

        let image = NSImage(
            size: NSSize(width: 18, height: 18),
            flipped: false
        ) { rect in
            let font = NSFont.systemFont(ofSize: 15, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            let text = "π" as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(
                    x: (rect.width - textSize.width) / 2,
                    y: (rect.height - textSize.height) / 2
                ),
                withAttributes: attrs
            )
            return true
        }
        image.isTemplate = template
        return image
    }

    private func statusTooltip(processing: Int, done: Int) -> String {
        if processing > 0 { return "pi-overlay-native — \(processing) processing" }
        if done > 0 { return "pi-overlay-native — \(done) completed" }
        return "pi-overlay-native"
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
            title: "Quit pi-overlay-native",
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
                title: tab.displayName,
                action: #selector(statusTabSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = StatusTabRef(profile: profile, tabID: tab.id)
            item.attributedTitle = tabStatusTitle(tab)
            item.toolTip = tab.remoteHost.map { "\($0.display):\(tab.directory?.path ?? "")" }
                ?? tab.directory?.path
            menu.addItem(item)
        }
        return menu
    }

    private func tabStatusTitle(_ tab: RpcTab) -> NSAttributedString {
        let (mark, color) = statusMark(for: tab)
        let name = tab.displayName
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
        let selectedTab = mode == .selfHost ? activeRpcTab : nil
        let selectedDirectory: URL? = mode == .selfHost
            ? selectedTab?.directory
            : activeDirectory
        let remoteRecents = mode == .selfHost ? directoryStore.remoteRecents() : []
        let menu = NSMenu()

        // For a pull-down button the first item supplies the button title.
        let titleBase = selectedDirectory?.lastPathComponent ?? "Select project…"
        let title = selectedTab?.remoteHost != nil ? "☁ \(titleBase)" : titleBase
        let header = NSMenuItem(
            title: "📁 \(title)",
            action: nil,
            keyEquivalent: ""
        )
        header.toolTip = selectedTab?.remoteHost.map { "\($0.display):\(selectedDirectory?.path ?? "")" }
            ?? selectedDirectory?.path
            ?? "Choose a project directory"
        menu.addItem(header)

        for url in directoryStore.recents {
            let item = NSMenuItem(
                title: displayPath(url),
                action: #selector(directoryMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url.path
            item.state = selectedTab?.remoteHost == nil && url.path == selectedDirectory?.path
                ? .on
                : .off
            if hasSession(for: url.path) {
                item.toolTip = "pi session open"
            }
            menu.addItem(item)
        }

        if !directoryStore.recents.isEmpty {
            menu.addItem(.separator())
        }

        if !remoteRecents.isEmpty {
            let remoteHeader = NSMenuItem(title: "Remote", action: nil, keyEquivalent: "")
            remoteHeader.isEnabled = false
            menu.addItem(remoteHeader)

            for remote in remoteRecents {
                let key = TabLocationCodec.encode(host: remote.host, path: remote.path)
                let item = NSMenuItem(
                    title: "☁ \(remote.host.display):\(remote.path)",
                    action: #selector(remoteDirectoryMenuItemSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = key
                item.state = key == selectedTab?.locationKey ? .on : .off
                item.toolTip = hasSession(for: key)
                    ? "pi session open on \(remote.host.display)"
                    : "\(remote.host.display):\(remote.path)"
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let choose = NSMenuItem(
            title: "Choose Folder…   ⌃N",
            action: #selector(chooseDirectory),
            keyEquivalent: ""
        )
        choose.target = self
        menu.addItem(choose)

        if mode == .selfHost {
            let connect = NSMenuItem(
                title: "Connect to Remote Host…",
                action: #selector(connectToRemoteHost),
                keyEquivalent: ""
            )
            connect.target = self
            connect.toolTip = "Run pi --mode rpc on another machine over SSH"
            menu.addItem(connect)
        }

        if selectedDirectory != nil, selectedTab?.remoteHost == nil {
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
        directoryPopup.title = "📁 \(title)"
        directoryPopup.toolTip = header.toolTip
    }

    @objc private func directoryMenuItemSelected(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        switchSession(to: URL(fileURLWithPath: path))
    }

    @objc private func remoteDirectoryMenuItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let location = TabLocationCodec.decode(raw)
        guard let host = location.host, !location.path.isEmpty else { return }
        switchRemoteSession(host: host, path: location.path)
    }

    /// Asks for an SSH destination and a remote directory, validates them with
    /// one round trip, then opens (or focuses) a tab for that location.
    /// Step 1: ask for the SSH destination and prove it works. Step 2: browse
    /// the remote folders (the path field in the sheet still accepts any path).
    @objc func connectToRemoteHost() {
        guard mode == .selfHost else { return }
        if isMinimized { toggleMinimize() }

        let alert = NSAlert()
        alert.messageText = "Connect to a remote pi"
        alert.informativeText =
            "Runs `pi --mode rpc` on another machine over SSH. Your ~/.ssh/config, "
            + "keys and agent are used; no passwords are stored in the overlay."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let last = directoryStore.lastRemote
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 76))
        let hostLabel = NSTextField(labelWithString: "Host")
        hostLabel.frame = NSRect(x: 0, y: 54, width: 380, height: 16)
        hostLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let hostField = NSTextField(frame: NSRect(x: 0, y: 26, width: 380, height: 24))
        hostField.stringValue = last?.host.display ?? ""
        hostField.placeholderString = "user@host or ~/.ssh alias (e.g. 192.168.1.21)"
        accessory.addSubview(hostLabel)
        accessory.addSubview(hostField)
        alert.accessoryView = accessory

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.focusOverlay()
                return
            }

            let rawHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = RemoteHost.parse(rawHost) else {
                self.showAlert(title: "Invalid host", message: "Use `host`, `user@host` or `host:port`.")
                return
            }

            self.statusLabel.stringValue = "CONNECTING TO \(host.display.uppercased())…"
            self.statusLabel.textColor = .systemOrange

            DispatchQueue.global(qos: .userInitiated).async {
                // Resolve the remote home and check that ssh + pi work before
                // opening the browser sheet. `~` is expanded on the remote.
                let prepared = RemotePi.prepare(host: host, path: "~")
                DispatchQueue.main.async {
                    if prepared.error.isEmpty {
                        let lastPath = self.directoryStore.lastRemote.flatMap {
                            $0.host == host ? $0.path : nil
                        }
                        self.statusLabel.stringValue = "CHOOSE A REMOTE FOLDER"
                        self.statusLabel.textColor = .systemOrange
                        self.presentRemoteBrowser(host: host, startPath: lastPath ?? "~")
                    } else {
                        self.statusLabel.stringValue = "SSH FAILED"
                        self.statusLabel.textColor = .systemRed
                        self.showAlert(
                            title: "Could not connect to \(host.display)",
                            message: prepared.error
                        )
                    }
                }
            }
        }
    }

    private func presentRemoteBrowser(host: RemoteHost, startPath: String) {
        let browser = RemoteFolderBrowser(host: host, startPath: startPath)
        browser.onChoose = { [weak self] path in
            guard let self else { return }
            self.remoteBrowser = nil
            self.directoryStore.addRemoteRecent(host: host, path: path)
            self.switchRemoteSession(host: host, path: path)
        }
        browser.onCancel = { [weak self] in
            self?.remoteBrowser = nil
            self?.focusOverlay()
            self?.showIdleStatus()
        }
        remoteBrowser = browser
        browser.begin(for: window)
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
        let activeLocal = activeRpcTab?.remoteHost == nil ? activeRpcTab?.directory : nil
        panel.directoryURL = activeLocal ?? directoryStore.lastDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory())
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
        guard activeRpcTab?.remoteHost == nil else { return }
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
        let key = tab.locationKey

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

    // MARK: - Reasoning effort

    /// Rebuilds the reasoning-effort dropdown. Pi owns the level list: RPC answers
    /// `get_available_thinking_levels`, and in tty mode the levels arrive on the
    /// extension's `thinking` event because the overlay cannot read the model's
    /// `thinkingLevelMap` itself. A model that cannot reason reports only `off`, so
    /// the control stays visible but disabled instead of disappearing when the model
    /// changes — a control that vanishes reads as a bug.
    private func rebuildThinkingMenu() {
        let levels = isSelfMode ? (activeRpcTab?.thinkingLevels ?? []) : eventThinkingLevels
        let current = isSelfMode ? activeRpcTab?.thinkingLevel : eventThinkingLevel

        thinkingPopup.removeAllItems()
        guard !levels.isEmpty else {
            thinkingPopup.addItem(withTitle: "Reasoning…")
            thinkingPopup.isEnabled = false
            thinkingPopup.toolTip = "No reasoning levels reported for this model"
            return
        }

        var selected = 0
        for (index, level) in levels.enumerated() {
            thinkingPopup.addItem(withTitle: level)
            thinkingPopup.item(at: index)?.representedObject = level
            if level == current { selected = index }
        }
        thinkingPopup.selectItem(at: selected)
        // One level means there is nothing to choose, so it reads as a label.
        thinkingPopup.isEnabled = levels.count > 1
        thinkingPopup.toolTip = levels.count > 1
            ? "Reasoning effort for this model (pi's /thinking)"
            : "This model supports only \(levels.first ?? "off")"
    }

    @objc private func thinkingLevelSelected(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? String else { return }

        if isSelfMode {
            guard let tab = activeRpcTab, let session = tab.session, session.isRunning else {
                flashStatus("NO PI SESSION", tone: .bad)
                return
            }
            tab.thinkingLevel = level
            rebuildThinkingMenu()
            session.setThinkingLevel(level)
            flashStatus("REASONING \(level)", tone: .ok)
        } else {
            // tty mode has no command channel back into pi, so the level moves only
            // by typing pi's own slash command into the terminal.
            guard injectSlashCommand("/thinking \(level)") else {
                flashStatus("CANNOT SET REASONING", tone: .bad)
                return
            }
            eventThinkingLevel = level
            rebuildThinkingMenu()
            flashStatus("REASONING \(level)", tone: .ok)
        }
        focusOverlay()
    }

    /// Types a slash command into the attached terminal. Needs the overlay to share
    /// the controlling TTY, same requirement as the prompt path.
    private func injectSlashCommand(_ command: String) -> Bool {
        guard mode == .tty, let tty = ttyPath, tty == controllingTTY(), let injector else {
            return false
        }
        return injector.inject(command + "\r")
    }

    @objc private func modelSelected(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ModelRef,
              let tab = activeRpcTab,
              let session = tab.session,
              session.isRunning else { return }

        statusLabel.stringValue = "SWITCHING MODEL"
        statusLabel.textColor = .systemOrange
        session.setModel(provider: ref.provider, modelId: ref.modelId)
        // Levels are per model and pi clamps the current one to the new model, so
        // both numbers have to be re-read after a switch.
        session.requestState()
        session.requestThinkingLevels()
        focusOverlay()
    }

    // MARK: - Tabs

    /// Marker shown before the tab name plus the color it should be drawn in.
    private func tabTitleParts(_ tab: RpcTab) -> (marker: String, name: String, color: NSColor?) {
        let name = tab.displayName
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

        let font = Theme.font(12, .medium)
        let activeFont = Theme.font(12, .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var x: CGFloat = 0
        var activeOrigin: CGFloat = 0

        for (index, tab) in rpcTabs.enumerated() {
            let parts = tabTitleParts(tab)
            let title = tabTitle(tab)
            let width = min(
                240,
                max(112, (title as NSString).size(withAttributes: attrs).width + 56)
            )
            let isActive = tab.id == activeRpcTabID
            let button = NSButton(
                title: title,
                target: self,
                action: #selector(selectTabButton(_:))
            )
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.layer?.borderWidth = isActive ? 1 : 0
            button.layer?.borderColor = Theme.border.cgColor
            button.layer?.backgroundColor = (isActive
                ? Theme.field
                : Theme.fieldAlt).cgColor
            button.alignment = .center
            button.toolTip = tab.fullLocation.isEmpty ? "No project selected" : tab.fullLocation
            button.frame = NSRect(x: x, y: 1, width: width, height: 32)
            let titleColor = isActive ? Theme.text : Theme.textSecondary
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.tailIndent = -24
            let attributed = NSMutableAttributedString(
                string: title,
                attributes: [
                    .font: isActive ? activeFont : font,
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
            close.layer?.cornerRadius = 4
            close.font = Theme.font(12, .medium)
            close.contentTintColor = Theme.textTertiary
            close.toolTip = "Close tab (Ctrl+W)"
            close.frame = NSRect(x: x + width - 24, y: 7, width: 16, height: 20)
            tabContentView.addSubview(close)

            if isActive {
                activeOrigin = x
            }
            x += width + 6
        }

        tabContentWidth = max(1, x)
        tabContentView.frame = NSRect(x: 0, y: 0, width: tabContentWidth, height: 34)

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

        guard let tab = activeRpcTab, let directory = tab.directory else {
            sessionInfos = []
            rebuildSessionMenu()
            return
        }

        sessionLoadToken += 1
        let token = sessionLoadToken
        let host = tab.remoteHost
        DispatchQueue.global(qos: .utility).async {
            let infos: [PiSessionInfo]
            if let host {
                // Remote listing does one ssh round trip; keep it off the main
                // thread like the on-disk scan.
                infos = RemotePiSessionStore.list(host: host, path: directory.path)
            } else {
                infos = PiSessionStore.list(for: directory)
            }
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
            "session menu key=\(activeRpcTab?.locationKey ?? "blank") "
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
            } else if var open = current {
                let thinking = RpcSession.messageThinking(from: message)
                if !thinking.isEmpty {
                    open.thinking = open.thinking.isEmpty
                        ? thinking
                        : open.thinking + "\n\n" + thinking
                }
                if !text.isEmpty { open.answer = text }
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
        queryPopup.isHidden = isMinimized || isCompact || sessionQueries.isEmpty
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
            renderTabResponse(tab)
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
            clearAttachments()
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
        let locationName: String = {
            guard let remote = tab.remoteHost else { return directory?.lastPathComponent ?? "New Tab" }
            return "\(remote.display):\(directory?.lastPathComponent ?? "")"
        }()
        directoryPopup.title = tab.remoteHost == nil
            ? (directory.map { "📁 \($0.lastPathComponent)" } ?? "📁 Select project…")
            : "☁ \(directory?.lastPathComponent ?? "Select project…")"
        directoryPopup.toolTip = tab.remoteHost.map { "\($0.display):\(directory?.path ?? "")" }
            ?? directory?.path
            ?? "Choose a project directory"
        window.title = "pi rpc · \(locationName)"

        if let session = tab.session {
            pidLabel.stringValue = session.processLabel
            pidLabel.toolTip = session.isRemote
                ? "ssh client PID \(session.processIdentifier) → \(tab.remoteHost?.display ?? "")"
                : "pi RPC child process ID \(session.processIdentifier)"
        } else if tab.exitStatus != nil {
            pidLabel.stringValue = tab.isRemote ? "ssh —" : "pi —"
            compactPidLabel.stringValue = pidLabel.stringValue
            pidLabel.toolTip = nil
        } else {
            pidLabel.stringValue = ""
            pidLabel.toolTip = nil
        }

        rebuildModelMenu()
        rebuildThinkingMenu()
        refreshSessionRow()

        if tab.isLaunching {
            statusLabel.stringValue = tab.isRemote ? "CONNECTING…" : "STARTING PI"
            statusLabel.textColor = .systemOrange
        } else if tab.directory == nil {
            statusLabel.stringValue = "SELECT PROJECT"
            statusLabel.textColor = .systemOrange
        } else if tab.session == nil, tab.exitStatus != nil {
            statusLabel.stringValue = tab.isRemote ? "SSH/PI EXITED" : "PI EXITED"
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
        updateFooter()
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
        updateCommandPalette()

        debugLog("rpc tab active dir=\(directory?.path ?? "blank") host=\(tab.remoteHost?.display ?? "local")")
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

        let host = tab.remoteHost

        // Resume the session pinned to this tab (profiles.conf) or, for a
        // restored local tab without one, the newest session for the project.
        // Remote sessions are only resumed when pinned: the remote store is a
        // network round trip, so a fresh tab starts a new conversation and the
        // Sessions row lists the rest.
        let pinned: String?
        if host != nil {
            pinned = tab.sessionFile
        } else {
            pinned = tab.sessionFile.flatMap {
                FileManager.default.fileExists(atPath: $0) ? $0 : nil
            }
        }
        let resumePath: String?
        if let pinned {
            resumePath = pinned
        } else if resumeLatest, host == nil {
            resumePath = PiSessionStore.list(for: directory, limit: 1).first?.path
        } else {
            resumePath = nil
        }

        tab.session = nil
        tab.directory = directory
        tab.isLaunching = true
        tab.exitStatus = nil
        tab.status = .idle
        tab.sessionFile = resumePath
        tab.sessionName = nil
        tab.pendingSessionName = nil
        tab.assistantText = ""
        tab.streamingText = ""
        tab.thinkingText = ""
        tab.streamingThinking = ""
        tab.lastError = nil
        tab.latestAnswerText = ""
        tab.responseText = ""
        tab.responseExpanded = false
        tab.responseUserCollapsed = false
        tab.queries = []
        tab.selectedQueryID = nil
        activeDirectory = directory
        if host == nil {
            directoryStore.addRecent(directory)
        }
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
            statusLabel.stringValue = tab.reloadPending
                ? "RELOADING PI"
                : (host == nil ? "STARTING PI" : "CONNECTING…")
            statusLabel.textColor = .systemOrange
        }

        debugLog(
            "rpc start \(host.map { "host=\($0.display) " } ?? "")dir=\(directory.path) session="
                + "\((resumePath as NSString?)?.lastPathComponent ?? "new")"
        )

        do {
            let session = try RpcSession.launch(
                in: directory,
                host: host,
                sessionFile: resumePath
            )
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
            session.requestThinkingLevels()
            session.requestCommands()
            session.requestSessionStats()
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
            tab.reloadPending = false
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

    private func switchRemoteSession(host: RemoteHost, path: String) {
        guard mode == .selfHost else { return }
        guard path.hasPrefix("/"),
              !path.contains("\n"),
              !path.contains("\r") else {
            statusLabel.stringValue = "REMOTE PATH MUST BE ABSOLUTE"
            statusLabel.textColor = .systemRed
            return
        }
        switchSession(to: URL(fileURLWithPath: path), remoteHost: host)
    }

    private func switchSession(to url: URL, remoteHost: RemoteHost? = nil) {
        if remoteHost != nil, mode != .selfHost { return }

        let normalized: URL
        let key: String
        if let remoteHost {
            guard !url.path.isEmpty else { return }
            normalized = url
            key = TabLocationCodec.encode(host: remoteHost, path: normalized.path)
            directoryStore.addRemoteRecent(host: remoteHost, path: normalized.path)
        } else {
            guard let local = directoryStore.normalize(url.path) else {
                statusLabel.stringValue = "DIR MISSING"
                statusLabel.textColor = .systemRed
                return
            }
            normalized = local
            key = local.path
            directoryStore.addRecent(local)
        }

        switch mode {
        case .selfHost:
            if let existing = rpcTabs.first(where: { $0.locationKey == key }) {
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

            tab.remoteHost = remoteHost
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

    /// Markdown block used when a turn fails. The raw provider text is kept in
    /// a blockquote so it renders predictably even with punctuation/code.
    private static func errorBlock(title: String, message: String) -> String {
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body.isEmpty ? "Pi ended the request with an error." : body
        let quoted = text
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "**\(title)**\n\n\(quoted)"
    }

    /// Puts an error (or a retry notice) in the response panel. Errors are
    /// forced open even if the user collapsed the panel, and the last prompt
    /// in the history gets the same text as its answer.
    private func showAssistantFailure(
        _ message: String,
        title: String,
        tab: RpcTab,
        isActive: Bool,
        existingText: String = "",
        statusText: String = "PI ERROR",
        isFinal: Bool = true
    ) {
        let block = Self.errorBlock(title: title, message: message)
        let trimmed = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? block : trimmed + "\n\n---\n\n" + block

        tab.lastError = message.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.assistantText = display
        tab.latestAnswerText = display
        if !tab.queries.isEmpty {
            tab.queries[tab.queries.count - 1].answer = display
        }

        let latestID = tab.queries.last?.id
        if tab.selectedQueryID == nil || tab.selectedQueryID == latestID {
            tab.responseText = display
            tab.responseExpanded = true
            tab.responseUserCollapsed = false
            renderMarkdown(in: tab.webView, text: display)
        }

        if isActive {
            responseText = tab.responseText
            responseExpanded = tab.responseExpanded
            responseUserCollapsed = tab.responseUserCollapsed
            updateResponseButton()
            renderMarkdown()
            layoutViews()
            statusLabel.stringValue = statusText
            statusLabel.textColor = isFinal ? .systemRed : .systemOrange
        }

        debugLog(
            "rpc failure tab=\(tabTitle(tab)) status=\(statusText) final=\(isFinal) "
                + "error=\(tab.lastError?.prefix(200) ?? "")"
        )
        debugLog("rpc failure display=\(display.prefix(400))")
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
        case "thinking_level_changed":
            // pi clamps the level to the model, so the value that comes back is the
            // one to show even when the overlay asked for a different one.
            if let level = record["level"] as? String {
                tab.thinkingLevel = level
                if isActive { rebuildThinkingMenu() }
            }

        case "agent_start":
            tab.status = .processing
            tab.assistantText = ""
            tab.streamingText = ""
            tab.thinkingText = ""
            tab.streamingThinking = ""
            tab.lastError = nil
            tab.responseStartedAt = nil
            tab.tokensPerSecond = nil
            tab.streamedChars = 0
            tab.estimatedTokensPerSecond = nil
            if isActive && tab.showThinking {
                ensureThinkingPanelOpen(tab)
                scheduleLiveResponseRender()
            }

        case "agent_settled":
            tab.status = .done
            session.requestSessionStats()
            if tab.assistantText.isEmpty,
               let lastError = tab.lastError,
               !lastError.isEmpty {
                // Some failures only arrive as a retry/command error; make
                // sure the panel is not left blank.
                tab.assistantText = Self.errorBlock(title: "Request failed", message: lastError)
                tab.latestAnswerText = tab.assistantText
            }
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
                renderTabResponse(tab)
            }
            notifyTurnFinished(profile: profileName(for: tab), tab: tab)
            debugLog(
                "rpc final tab=\(tabTitle(tab)) chars=\(finalText.count) "
                    + "thinking=\(tab.thinkingText.count) show=\(tab.showThinking)"
            )

        case "message_start":
            if (record["message"] as? [String: Any])?["role"] as? String == "assistant" {
                tab.responseStartedAt = Date()
                tab.tokensPerSecond = nil
                tab.streamedChars = 0
                tab.estimatedTokensPerSecond = nil
            }

        case "message_update":
            if let usage = record["usage"] as? [String: Any] {
                applyUsage(usage, tab: tab, isActive: isActive)
            }
            if let update = record["assistantMessageEvent"] as? [String: Any] {
                let updateType = update["type"] as? String
                if updateType == "error",
                   (update["reason"] as? String) != "aborted" {
                    let message = (update["error"] as? String)
                        ?? (update["reason"] as? String)
                        ?? "The provider stream ended with an error."
                    showAssistantFailure(
                        message,
                        title: "Request failed",
                        tab: tab,
                        isActive: isActive,
                        statusText: "PI ERROR"
                    )
                } else if updateType == "thinking_delta",
                          let delta = update["delta"] as? String {
                    tab.streamingThinking += delta
                    noteStreamDelta(delta, tab: tab, isActive: isActive)
                    if isActive && tab.showThinking {
                        ensureThinkingPanelOpen(tab)
                        scheduleLiveResponseRender()
                    }
                } else if updateType == "thinking_end",
                          let content = update["content"] as? String {
                    tab.streamingThinking = content
                    if isActive && tab.showThinking {
                        ensureThinkingPanelOpen(tab)
                        scheduleLiveResponseRender()
                    }
                } else if updateType == "text_delta",
                          let delta = update["delta"] as? String {
                    tab.streamingText += delta
                    noteStreamDelta(delta, tab: tab, isActive: isActive)
                    if isActive && tab.showThinking {
                        scheduleLiveResponseRender()
                    }
                } else if updateType == "text_end",
                          let content = update["content"] as? String {
                    tab.streamingText = content
                    if isActive && tab.showThinking {
                        scheduleLiveResponseRender()
                    }
                }
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
                } else if role == "assistant" {
                    if let usage = message["usage"] as? [String: Any] {
                        applyUsage(usage, tab: tab, isActive: isActive)
                    }
                    let thinking = RpcSession.messageThinking(from: message)
                    if !thinking.isEmpty {
                        tab.thinkingText = thinking
                    } else if !tab.streamingThinking.isEmpty {
                        tab.thinkingText = tab.streamingThinking
                    }
                    tab.streamingThinking = tab.thinkingText
                    if !tab.thinkingText.isEmpty {
                        debugLog(
                            "rpc thinking tab=\(tabTitle(tab)) chars=\(tab.thinkingText.count)"
                        )
                    }

                    let stopReason = message["stopReason"] as? String ?? ""
                    let isAborted = stopReason == "aborted"
                    let errorMessage = (message["errorMessage"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !isAborted, let errorMessage, !errorMessage.isEmpty {
                        showAssistantFailure(
                            errorMessage,
                            title: "Request failed",
                            tab: tab,
                            isActive: isActive,
                            existingText: text
                        )
                    } else if stopReason == "error", text.isEmpty {
                        showAssistantFailure(
                            "Pi ended the request with an error and no details.",
                            title: "Request failed",
                            tab: tab,
                            isActive: isActive
                        )
                    } else if !text.isEmpty {
                        tab.assistantText = text
                        tab.latestAnswerText = text
                        if !tab.queries.isEmpty {
                            tab.queries[tab.queries.count - 1].answer = text
                            if !tab.thinkingText.isEmpty {
                                tab.queries[tab.queries.count - 1].thinking = tab.thinkingText
                            }
                        }
                        let latestID = tab.queries.last?.id
                        if tab.selectedQueryID == nil || tab.selectedQueryID == latestID {
                            tab.responseText = text
                            if !tab.responseExpanded && !tab.responseUserCollapsed {
                                tab.responseExpanded = true
                            }
                            renderTabResponse(tab)
                        }
                    }
                }
            }

        case "agent_end":
            // Safety net: if the stream skipped message_end but the final run
            // carries an error message, surface it instead of leaving a blank
            // response panel. Retrying runs are handled by auto_retry_*.
            if record["willRetry"] as? Bool != true,
               tab.assistantText.isEmpty,
               let messages = record["messages"] as? [[String: Any]] {
                for message in messages.reversed() where message["role"] as? String == "assistant" {
                    if let errorMessage = (message["errorMessage"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !errorMessage.isEmpty {
                        showAssistantFailure(
                            errorMessage,
                            title: "Request failed",
                            tab: tab,
                            isActive: isActive
                        )
                        break
                    }
                    if message["stopReason"] as? String == "error" {
                        showAssistantFailure(
                            "Pi ended the request with an error and no details.",
                            title: "Request failed",
                            tab: tab,
                            isActive: isActive
                        )
                        break
                    }
                }
            }

        case "auto_retry_start":
            let attempt = record["attempt"] as? Int ?? 1
            let maxAttempts = record["maxAttempts"] as? Int ?? attempt
            let message = record["errorMessage"] as? String ?? "Request failed"
            tab.lastError = message
            let title = "Request failed — retrying \(attempt)/\(maxAttempts)"
            if tab.assistantText.isEmpty && tab.streamingText.isEmpty {
                showAssistantFailure(
                    message,
                    title: title,
                    tab: tab,
                    isActive: isActive,
                    statusText: "RETRYING \(attempt)/\(maxAttempts)",
                    isFinal: false
                )
            } else if isActive {
                statusLabel.stringValue = "RETRYING \(attempt)/\(maxAttempts)"
                statusLabel.textColor = .systemOrange
            }

        case "auto_retry_end":
            if record["success"] as? Bool == false {
                let finalError = (record["finalError"] as? String)
                    ?? tab.lastError
                    ?? "Request failed after retries"
                showAssistantFailure(
                    finalError,
                    title: "Request failed",
                    tab: tab,
                    isActive: isActive,
                    statusText: "PI ERROR"
                )
            } else {
                tab.lastError = nil
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
                    showAssistantFailure(
                        error,
                        title: "Prompt failed",
                        tab: tab,
                        isActive: isActive,
                        statusText: "PROMPT ERROR"
                    )
                } else if command == "set_model", isActive {
                    statusLabel.stringValue = "MODEL ERROR"
                    statusLabel.textColor = .systemRed
                    rebuildModelMenu()
                } else if command == "get_available_models", isActive {
                    statusLabel.stringValue = "MODEL REFRESH ERROR"
                    statusLabel.textColor = .systemRed
                } else if command == "set_session_name" {
                    tab.pendingSessionName = nil
                    session.requestState()
                    if isActive {
                        statusLabel.stringValue = "NAME ERROR"
                        statusLabel.textColor = .systemRed
                    }
                }
                // Compaction failures are reported by `compaction_end`, which also covers
                // auto compaction; flashing here as well would double-print the status.
            } else {
                switch command {
                case "get_state":
                    if let model = data?["model"] as? [String: Any] {
                        tab.currentModel = model
                        if let window = intValue(model["contextWindow"]), window > 0 {
                            tab.contextWindow = window
                        }
                    }
                    if let level = data?["thinkingLevel"] as? String {
                        tab.thinkingLevel = level
                    }
                    // A get_state reply reflects the live flag, so a tab switch or a
                    // refresh while a summary is running still reads as COMPACTING.
                    if let compacting = data?["isCompacting"] as? Bool {
                        tab.isCompacting = compacting
                        if isActive { showIdleStatus() }
                    }
                    if let file = data?["sessionFile"] as? String {
                        if tab.sessionFile != file {
                            tab.sessionFile = file
                            saveOpenTabs()
                            // A fresh remote session file appears after the RPC
                            // child starts; rescan so it is in the Sessions row
                            // too, not only in the "current" label.
                            if isActive { refreshSessionRow() }
                        }
                    } else {
                        tab.sessionFile = nil
                    }
                    if let pending = tab.pendingSessionName {
                        if let returned = data?["sessionName"] as? String,
                           returned == pending {
                            tab.sessionName = returned
                            tab.pendingSessionName = nil
                        } else {
                            tab.sessionName = pending
                        }
                    } else {
                        tab.sessionName = data?["sessionName"] as? String
                    }
                    if isActive {
                        rebuildModelMenu()
                        rebuildThinkingMenu()
                        rebuildSessionMenu()
                    }
                    if tab.reloadPending {
                        tab.reloadPending = false
                        if isActive {
                            debugLog("pi reload confirmed tab=\(tabTitle(tab))")
                            flashStatus("PI RELOADED", tone: .ok)
                        }
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
                        // A compaction belongs to the conversation just left, so the
                        // footer's `↓` marker goes with it.
                        tab.compactedBefore = nil
                        tab.compactedAfter = nil
                        tab.isCompacting = false
                        tab.latestAnswerText = ""
                        tab.thinkingText = ""
                        tab.streamingThinking = ""
                        tab.lastError = nil
                        tab.pendingSessionName = nil
                        tab.reloadPending = false
                        tab.responseText = ""
                        tab.responseExpanded = false
                        tab.responseUserCollapsed = false
                        tab.queries = []
                        tab.selectedQueryID = nil
                        tab.status = .idle
                        session.requestState()
                        session.requestLastAssistantText()
                        session.requestEntries()
                        session.requestCommands()
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
                        // A compaction belongs to the conversation just left, so the
                        // footer's `↓` marker goes with it.
                        tab.compactedBefore = nil
                        tab.compactedAfter = nil
                        tab.isCompacting = false
                        tab.latestAnswerText = ""
                        tab.thinkingText = ""
                        tab.streamingThinking = ""
                        tab.lastError = nil
                        tab.responseText = ""
                        tab.responseExpanded = false
                        tab.responseUserCollapsed = false
                        tab.queries = []
                        tab.selectedQueryID = nil
                        tab.status = .idle
                        tab.sessionName = nil
                        tab.pendingSessionName = nil
                        tab.reloadPending = false
                        tab.sessionFile = nil
                        // pi starts a new session from the settings default model; the
                        // selection made in the conversation just left is not carried
                        // over. Re-apply it before the state refresh so the serial RPC
                        // loop applies it before the get_state reply is built and the
                        // menu and tab state reflect the session's actual model.
                        if let model = tab.currentModel,
                           let provider = model["provider"] as? String,
                           let modelId = model["id"] as? String {
                            session.setModel(provider: provider, modelId: modelId)
                        }
                        session.requestState()
                        session.requestLastAssistantText()
                        session.requestEntries()
                        session.requestCommands()
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
                            renderTabResponse(tab)
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
                        renderTabResponse(tab)
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
                            if statusLabel.stringValue == "REFRESHING MODELS" {
                                debugLog(
                                    "model refresh done tab=\(tabTitle(tab)) "
                                        + "models=\(models.count)"
                                )
                                flashStatus("MODELS REFRESHED", tone: .ok)
                            }
                        }
                    }

                case "get_available_thinking_levels":
                    if let levels = data?["levels"] as? [String] {
                        tab.thinkingLevels = levels
                        if isActive { rebuildThinkingMenu() }
                    }

                case "get_session_stats":
                    if let usage = data?["contextUsage"] as? [String: Any] {
                        // `tokens` is null straight after a compaction; keep the estimate the
                        // `compact` result seeded instead of dropping the meter to `—` for
                        // the next turn.
                        if let tokens = intValue(usage["tokens"]) { tab.contextTokens = tokens }
                        if let window = intValue(usage["contextWindow"]), window > 0 {
                            tab.contextWindow = window
                        }
                    }
                    if isActive { updateFooter() }

                case "set_session_name":
                    if let pending = tab.pendingSessionName {
                        tab.sessionName = pending
                    }
                    if isActive {
                        debugLog(
                            "session rename confirmed tab=\(tabTitle(tab)) "
                                + "name=\(tab.sessionName ?? "")"
                        )
                        flashStatus("SESSION NAMED", tone: .ok)
                        refreshSessionRow()
                    }

                case "get_commands":
                    let parsed = (data?["commands"] as? [[String: Any]] ?? [])
                        .compactMap(PiCommand.init(json:))
                    tab.commands = parsed.filter {
                        $0.source == "skill" || $0.name == "mcp"
                    }
                    debugLog(
                        "rpc commands tab=\(tabTitle(tab)) total=\(parsed.count) "
                            + "kept=\(tab.commands.count)"
                    )
                    if isActive {
                        updateCommandPalette()
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

        case "compaction_start":
            // Covers both `/compact` and pi's own threshold/overflow compaction, which
            // otherwise leave no trace in the overlay.
            tab.isCompacting = true
            if isActive {
                showIdleStatus()
                updateSendButton()
            }

        case "compaction_end":
            tab.isCompacting = false
            let reason = record["reason"] as? String
            let result = record["result"] as? [String: Any]
            debugLog(
                "compaction tab=\(tabTitle(tab)) reason=\(reason ?? "?") "
                    + "before=\(intValue(result?["tokensBefore"]) ?? -1) "
                    + "after=\(intValue(result?["estimatedTokensAfter"]) ?? -1) "
                    + "aborted=\(record["aborted"] as? Bool == true)"
            )
            guard isActive else { break }
            if let result {
                // `contextUsage.tokens` is null until the next assistant response, so the
                // meter is seeded from the post-compaction estimate instead of reading `—`
                // right after the work that just freed the window.
                let after = intValue(result["estimatedTokensAfter"])
                if let after, after > 0 { tab.contextTokens = after }
                tab.compactedBefore = intValue(result["tokensBefore"])
                tab.compactedAfter = after
                flashStatus(
                    compactionMessage(
                        before: tab.compactedBefore,
                        after: after,
                        reason: reason
                    ),
                    tone: .ok
                )
            } else if record["aborted"] as? Bool == true {
                flashStatus("COMPACT CANCELLED", tone: .warn)
            } else {
                flashStatus("COMPACT ERROR", tone: .bad)
            }
            updateFooter()
            // The send pill goes back to Send now that a prompt is allowed again.
            updateSendButton()

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
                showIdleStatus()
            }
            if tab.status != previousStatus {
                rebuildTabBar()
            }
        } else if tab.status != previousStatus {
            rebuildTabBar()
        }
        updateFooter()
        updateStatusItem()
    }

    private func handleRpcExit(tabID: UUID, session: RpcSession, status: Int32) {
        guard let tab = rpcTab(withID: tabID),
              tab.session === session else { return }

        tab.session = nil
        tab.status = .idle
        tab.exitStatus = status
        tab.reloadPending = false

        if tab.id == activeRpcTabID {
            keyTape.agentStatus = .idle
            keyTape.needsDisplay = true
            if tab.isRemote {
                statusLabel.stringValue = "SSH/PI EXITED (\(status))"
            } else {
                statusLabel.stringValue = "PI EXITED (\(status))"
            }
            statusLabel.textColor = .systemRed
            pidLabel.stringValue = tab.isRemote ? "ssh —" : "pi —"
            compactPidLabel.stringValue = pidLabel.stringValue
            pidLabel.toolTip = nil
            modelPopup.isEnabled = false
            modelPopup.toolTip = "pi exited"

            if status != 0 {
                let detail = session.recentStderr()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty {
                    showAlert(
                        title: tab.remoteHost.map { "\($0.display): pi exited (\(status))" }
                            ?? "pi exited (\(status))",
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
                if let until = mcpCaptureUntil, Date() < until {
                    mcpCaptureLines.append(message)
                }
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
        infoParts.append(
            "Session: "
                + (tab.remoteHost.map { "\($0.display):\(tab.directory?.path ?? "")" }
                    ?? tab.directory.map { displayPath($0) }
                    ?? "New Tab")
        )
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
            guard session.prompt(text, images: pendingImages) else {
                statusLabel.stringValue = "SEND ERROR"
                statusLabel.textColor = .systemRed
                return false
            }

            tab.status = .processing
            tab.rawText = ""
            tab.tape = []
            clearAttachments()
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
        if let responseCopyMonitor {
            NSEvent.removeMonitor(responseCopyMonitor)
            self.responseCopyMonitor = nil
        }
        commandPalettePanel.orderOut(nil)
        // Do not autosave the 96 pt compact frame for the next launch.
        if isCompact, let frame = compactRestoreFrame {
            isCompact = false
            window.setFrame(frame, display: false)
        }
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
        html, body { margin: 0; padding: 0; background: #fbfbfd; color: #18181b; }
        body { font: 13.5px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
        #content { padding: 16px 18px 20px; }
        h1, h2, h3, h4 { margin: 0.8em 0 0.4em; line-height: 1.25; color: #101014; letter-spacing: -0.01em; }
        h1 { font-size: 1.5em; }
        h2 { font-size: 1.28em; }
        h3 { font-size: 1.12em; }
        p { margin: 0.55em 0; line-height: 1.55; }
        ul, ol { margin: 0.55em 0; padding-left: 1.5em; }
        li { margin: 0.18em 0; line-height: 1.5; }
        table { border-collapse: collapse; width: 100%; margin: 0.7em 0; font-size: 12.5px; }
        th, td { border: 1px solid #e4e4ea; padding: 6px 8px; text-align: left; vertical-align: top; }
        th { background: #f4f4f7; font-weight: 600; }
        code { font-family: ui-monospace, Menlo, monospace; background: #f1f1f5; padding: 1.5px 5px; border-radius: 5px; }
        pre { background: #0e0e12; color: #f2f2f5; padding: 12px 14px; border-radius: 10px; overflow: auto; }
        pre code { background: none; padding: 0; color: inherit; }
        blockquote { margin: 0.7em 0; padding: 0.15em 0.9em; border-left: 3px solid #ddddE6; color: #5c5c66; }
        a { color: #6b4eff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        hr { border: none; border-top: 1px solid #e8e8ee; margin: 1em 0; }
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
            renderTabResponse(tab)
        } else {
            renderMarkdown(in: responseWebView, text: responseText)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = rpcTabs.first(where: { $0.webView === webView }) {
            renderTabResponse(tab)
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
                updateStatusItem()
                // Extension modes report completion through IPC, not RPC.
                if next == .done, mode != .selfHost {
                    notifyTurnFinished(profile: nil, tab: nil)
                }
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

        case "thinking":
            eventThinkingLevel = event["level"] as? String
            eventThinkingLevels = (event["levels"] as? [String]) ?? []
            rebuildThinkingMenu()

        case "usage":
            eventContextTokens = intValue(event["contextTokens"])
            eventContextWindow = intValue(event["contextWindow"])
            eventTokensPerSecond = doubleValue(event["tokensPerSecond"])
            eventEstimatedTokensPerSecond = doubleValue(event["estimatedTokensPerSecond"])

        case "compact":
            // tty mode cannot run compaction: the terminal did it. The event carries the
            // pre-compaction count only, so the meter waits for the next usage event.
            let before = intValue(event["tokensBefore"])
            if let before {
                flashStatus(compactionMessage(before: before, after: nil), tone: .ok)
            }
            updateFooter()

        default:
            break
        }

        updateFooter()
    }

    // MARK: Footer numbers

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    /// Context estimate and live token rate from a provider usage record.
    /// `totalTokens` is the same estimate pi uses for the context footer.
    /// Rough chars-per-token for the streamed estimate: good enough to move the
    /// footer, not good enough to bill for. Providers report usage only in the
    /// final chunk, so during a turn this is the only number that can move.
    private static let charsPerToken = 4.0

    private func noteStreamDelta(_ delta: String, tab: RpcTab, isActive: Bool) {
        guard tab.responseStartedAt != nil else { return }
        tab.streamedChars += delta.count
        guard let started = tab.responseStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 0.2 else { return }
        let rate = Double(tab.streamedChars) / Self.charsPerToken / elapsed
        // Only accept a move that changes the displayed digits, so a streamed
        // turn does not repaint the footer on every delta.
        guard String(format: "%.1f", rate)
            != String(format: "%.1f", tab.estimatedTokensPerSecond ?? -1) else { return }
        tab.estimatedTokensPerSecond = rate
        if isActive { updateFooter() }
    }

    private func applyUsage(_ usage: [String: Any], tab: RpcTab, isActive: Bool) {
        let input = intValue(usage["input"]) ?? 0
        let output = intValue(usage["output"]) ?? 0
        let cacheRead = intValue(usage["cacheRead"]) ?? 0
        let cacheWrite = intValue(usage["cacheWrite"]) ?? 0
        let total = intValue(usage["totalTokens"]) ?? (input + output + cacheRead + cacheWrite)
        if total > 0 { tab.contextTokens = total }
        if output > 0, let started = tab.responseStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 0.2 { tab.tokensPerSecond = Double(output) / elapsed }
        }
        if isActive { updateFooter() }
    }

    /// Per-tab numbers in RPC modes, controller-wide numbers in the tty modes.
    private func updateFooter() {
        let tab = activeRpcTab
        let tokens = tab?.contextTokens ?? eventContextTokens
        let window = tab?.contextWindow ?? eventContextWindow
        let streaming = tab?.status == .processing || keyTape.agentStatus == .processing
        // While a turn is running the provider's usage is usually still zero, so
        // the live number is the streamed estimate; the reported usage takes over
        // once the turn settles.
        let estimated = streaming
            ? (tab?.estimatedTokensPerSecond ?? eventEstimatedTokensPerSecond)
            : nil
        let rate = estimated ?? tab?.tokensPerSecond ?? eventTokensPerSecond
        let compactedFrom = tab?.compactedBefore
        let compactedTo = tab?.compactedAfter

        let signature = [
            tokens.map { String($0) } ?? "-",
            window.map { String($0) } ?? "-",
            rate.map { String(format: "%.1f", $0) } ?? "-",
            streaming ? "live" : "idle",
            estimated != nil ? "approx" : "exact",
            compactedFrom.map { String($0) } ?? "-",
            compactedTo.map { String($0) } ?? "-",
        ].joined(separator: "|")
        guard signature != footerSignature else { return }
        footerSignature = signature

        footerView.contextTokens = tokens
        footerView.contextWindow = window
        footerView.tokensPerSecond = rate
        footerView.isStreaming = streaming
        footerView.rateIsEstimated = estimated != nil
        footerView.compactedFrom = compactedFrom
        footerView.compactedTo = compactedTo

        var tip = "Context usage and output token rate"
        if let tokens, let window, window > 0 {
            tip += " — \(tokens) of \(window) tokens (\(Int((Double(tokens) / Double(window)) * 100))%)"
        }
        if let compactedFrom, let compactedTo, compactedFrom > compactedTo {
            tip += " · last compaction \(compactedFrom) → \(compactedTo) tokens"
        }
        if let rate {
            tip += " · \(String(format: "%.1f", rate)) tokens/s"
            tip += estimated != nil ? " (estimated from streamed characters)" : " reported by the provider"
        }
        footerView.toolTip = tip
        footerView.needsDisplay = true
    }

    private func updateResponseButton() {
        // In self mode keep the Response row available even before the first
        // answer so the thinking toggle can be armed ahead of a turn.
        let visible = !isMinimized && !isCompact && (isSelfMode || !responseText.isEmpty)
        responseButton.isHidden = !visible
        responseButton.title = responseExpanded ? "▾  Response" : "▸  Response"
        responseDivider.isHidden = !visible
        responseCopyButton.isHidden = !visible
        responseDownloadButton.isHidden = !visible
        responseExpandButton.isHidden = !visible
        thinkingButton.isHidden = !visible || mode != .selfHost
        responseCopyButton.isEnabled = visible && !responseText.isEmpty
        responseDownloadButton.isEnabled = visible && !responseText.isEmpty
        responseExpandButton.isEnabled = visible
        applyThinkingButtonState()
    }

    private func applyThinkingButtonState() {
        let on = mode == .selfHost && activeRpcTab?.showThinking == true
        thinkingButton.setSymbol(
            on ? "lightbulb.fill" : "lightbulb",
            size: 14,
            tint: on ? Theme.accent : Theme.textTertiary
        )
        thinkingButton.baseFill = on ? Theme.accentSoft : .clear
        thinkingButton.toolTip = on
            ? "Hide thinking (reasoning)"
            : "Show thinking (reasoning)"
        thinkingButton.setAccessibilityLabel(on ? "Hide thinking" : "Show thinking")
        thinkingButton.needsDisplay = true
    }

    @objc private func toggleThinking() {
        guard mode == .selfHost, let tab = activeRpcTab else { return }
        tab.showThinking.toggle()
        if tab.showThinking {
            // A deliberate toggle should reveal the panel even if the user
            // collapsed it earlier.
            responseUserCollapsed = false
            tab.responseUserCollapsed = false
            ensureThinkingPanelOpen(tab)
        }
        applyThinkingButtonState()
        updateResponseButton()
        renderMarkdown()
        layoutViews()
        focusOverlay()
    }

    /// Opens the response panel when thinking starts streaming, unless the
    /// user explicitly collapsed it.
    private func ensureThinkingPanelOpen(_ tab: RpcTab) {
        guard !responseExpanded, !responseUserCollapsed else { return }
        responseExpanded = true
        responseUserCollapsed = false
        tab.responseExpanded = true
        tab.responseUserCollapsed = false
        updateResponseButton()
        layoutViews()
    }

    private var liveRenderScheduled = false

    /// Coalesces the high-frequency thinking/text deltas into ~12 fps renders.
    private func scheduleLiveResponseRender() {
        guard !liveRenderScheduled else { return }
        liveRenderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.liveRenderScheduled = false
            self.renderMarkdown()
        }
    }

    /// Composes thinking + answer. While a turn is running it uses the live
    /// streaming fields, so the panel updates as reasoning arrives.
    private func displayText(for tab: RpcTab) -> String {
        let processing = tab.status == .processing
        let thinking: String
        if processing {
            thinking = tab.streamingThinking.isEmpty
                ? tab.thinkingText
                : tab.streamingThinking
        } else {
            thinking = thinkingText(for: tab)
        }
        let answer = processing
            ? (tab.streamingText.isEmpty ? tab.responseText : tab.streamingText)
            : tab.responseText

        guard tab.showThinking else {
            return tab.responseText
        }
        if thinking.isEmpty && !processing {
            return tab.responseText
        }

        var output = "### Thinking\n\n"
            + (thinking.isEmpty ? "_Waiting for reasoning…_" : thinking)
        if !answer.isEmpty {
            output += "\n\n---\n\n### Response\n\n" + answer
        } else if processing {
            output += "\n\n---\n\n### Response\n\n_Generating…_"
        }
        return output
    }

    /// Thinking for the current/latest turn, or the selected historical one.
    private func thinkingText(for tab: RpcTab) -> String {
        if let id = tab.selectedQueryID,
           let query = tab.queries.first(where: { $0.id == id }) {
            if id == tab.queries.last?.id, !tab.thinkingText.isEmpty {
                return tab.thinkingText
            }
            return query.thinking
        }
        if !tab.thinkingText.isEmpty { return tab.thinkingText }
        return tab.queries.last?.thinking ?? ""
    }

    private func renderTabResponse(_ tab: RpcTab) {
        renderMarkdown(in: tab.webView, text: displayText(for: tab))
    }

    private func updateMinimizeButton() {
        let symbol = isMinimized ? "chevron.up" : "chevron.down"
        let description = isMinimized ? "Restore overlay" : "Minimize overlay"
        minimizeButton.setSymbol(symbol, size: 14, tint: Theme.textSecondary)
        if minimizeButton.image == nil {
            minimizeButton.title = isMinimized ? "▴" : "▾"
        } else {
            minimizeButton.title = ""
        }
        minimizeButton.toolTip = isMinimized
            ? "Restore the overlay (Cmd+M)"
            : "Minimize to the tab strip (Cmd+M)"
        minimizeButton.setAccessibilityLabel(description)
    }

    // MARK: - Attachments and response actions

    /// The pill is Send while idle and Cancel while a turn is running. Cancel
    /// sends `abort` to the RPC session (or Escape to a TTY backend).
    /// The visible response WebView when WebKit (or one of its subviews) owns
    /// the first responder. Used to scope copy shortcuts to the response area.
    private func responseWebViewIfFocused() -> WKWebView? {
        let webView: WKWebView?
        if mode == .selfHost {
            guard let tab = activeRpcTab,
                  tab.responseExpanded,
                  !tab.webView.isHidden else { return nil }
            webView = tab.webView
        } else {
            guard responseExpanded, !responseWebView.isHidden else { return nil }
            webView = responseWebView
        }
        guard let webView else { return nil }
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current === webView { return webView }
            if let view = current as? NSView, view.isDescendant(of: webView) {
                return webView
            }
            responder = current.nextResponder
        }
        return nil
    }

    /// Copies the WebView selection, or the whole response when nothing is
    /// selected. This makes Ctrl+C and Cmd+C work after clicking into the
    /// rendered answer.
    private func copySelectionFromResponse(_ webView: WKWebView) {
        let script = "(window.getSelection && String(window.getSelection())) || ''"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let selection = (result as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            debugLog("response copy selection chars=\(selection.count)")
            if selection.isEmpty {
                self.copyResponse()
            } else {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(selection, forType: .string)
                self.flashStatus("COPIED", tone: .ok)
            }
        }
    }

    /// Handles `/name` and `/name <value>` without sending it to the TUI-only
    /// built-in command. With no argument, asks for a name.
    private func handleSessionNameCommand(_ text: String) -> Bool {
        guard mode == .selfHost else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/name" || trimmed.hasPrefix("/name ") else { return false }

        let name = String(trimmed.dropFirst("/name".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        keyTape.setText("")
        rawText = ""
        tape.removeAll()
        if name.isEmpty {
            promptForSessionName()
        } else {
            applySessionName(name)
        }
        return true
    }

    private func promptForSessionName() {
        guard mode == .selfHost, let tab = activeRpcTab else { return }
        if isMinimized { toggleMinimize() }

        let alert = NSAlert()
        alert.messageText = "Name this session"
        alert.informativeText = "The name appears in the Sessions list."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = tab.sessionName ?? ""
        field.placeholderString = "Session name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else {
                self?.focusOverlay()
                return
            }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                self.focusOverlay()
                return
            }
            self.applySessionName(name)
        }
    }

    private func handleReloadCommand(_ text: String) -> Bool {
        guard mode == .selfHost else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/reload" else { return false }
        keyTape.setText("")
        rawText = ""
        tape.removeAll()
        reloadActivePiProcess()
        return true
    }

    // MARK: - Compaction (/compact)

    /// `/compact` in self mode. In tty mode the line is typed into the terminal and
    /// pi's TUI handles it, so only the mirror path exists there.
    private func handleCompactCommand(_ text: String) -> Bool {
        guard mode == .selfHost else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/compact" || trimmed.hasPrefix("/compact ") else { return false }

        let instructions = String(trimmed.dropFirst("/compact".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        keyTape.setText("")
        rawText = ""
        tape.removeAll()
        compactActiveSession(instructions: instructions.isEmpty ? nil : instructions)
        return true
    }

    private func compactActiveSession(instructions: String?) {
        guard mode == .selfHost,
              let tab = activeRpcTab,
              let session = tab.session, session.isRunning else {
            flashStatus("NO PI SESSION", tone: .bad)
            return
        }
        guard !tab.isCompacting else {
            flashStatus("ALREADY COMPACTING", tone: .warn)
            return
        }
        // pi aborts the current turn before summarising, so a run in flight is dropped;
        // that is worth seeing in the log rather than silently cancelling.
        if tab.status == .processing {
            debugLog("compact aborts the running turn tab=\(tabTitle(tab))")
        }
        // Compaction makes its own model call, so the status reads as work in
        // progress for the whole summary, not as a 1.4s flash.
        tab.isCompacting = true
        showIdleStatus()
        updateSendButton()
        debugLog(
            "compact request tab=\(tabTitle(tab)) "
                + "instructions=\(instructions ?? "-")"
        )
        session.requestCompact(customInstructions: instructions)
    }

    private func compactionMessage(before: Int?, after: Int?, reason: String? = nil) -> String {
        // Auto compaction is worth naming: the user did not ask for it.
        let label = (reason == "threshold" || reason == "overflow") ? "AUTO COMPACTED" : "COMPACTED"
        if let before, let after {
            return "\(label) \(FooterView.tokenCount(before)) → \(FooterView.tokenCount(after))"
        }
        if let before { return "\(label) \(FooterView.tokenCount(before))" }
        return label
    }

    private func reloadActivePiProcess() {
        guard mode == .selfHost,
              let tab = activeRpcTab,
              let directory = tab.directory else {
            flashStatus("NO PI SESSION", tone: .bad)
            return
        }
        guard let session = tab.session, session.isRunning else {
            flashStatus("NO PI SESSION", tone: .bad)
            return
        }
        guard !session.isStreaming, tab.status != .processing, !tab.isCompacting else {
            flashStatus("BUSY — CANNOT RELOAD", tone: .warn)
            return
        }

        tab.reloadPending = true
        statusLabel.stringValue = "RELOADING PI"
        statusLabel.textColor = .systemOrange
        debugLog(
            "pi reload tab=\(tabTitle(tab)) "
                + "session=\((tab.sessionFile as NSString?)?.lastPathComponent ?? "new") "
                + "host=\(tab.remoteHost?.display ?? "local")"
        )
        startRpcSession(in: tab, directory: directory, resumeLatest: false)
    }

    private func applySessionName(_ name: String) {
        guard mode == .selfHost,
              let tab = activeRpcTab,
              let session = tab.session,
              session.isRunning else {
            flashStatus("NO PI SESSION", tone: .bad)
            return
        }
        tab.sessionName = name
        tab.pendingSessionName = name
        session.setSessionName(name)
        statusLabel.stringValue = "RENAMING SESSION"
        statusLabel.textColor = .systemOrange
        debugLog("session rename tab=\(tabTitle(tab)) name=\(name)")
        focusOverlay()
    }

    @objc private func refreshModels() {
        guard mode == .selfHost,
              let tab = activeRpcTab,
              let session = tab.session,
              session.isRunning else {
            flashStatus("NO PI SESSION", tone: .bad)
            return
        }
        session.requestModels()
        spinModelRefreshButton()
        statusLabel.stringValue = "REFRESHING MODELS"
        statusLabel.textColor = .systemOrange
        debugLog("model refresh requested tab=\(tabTitle(tab))")
    }

    private func spinModelRefreshButton() {
        guard let layer = modelRefreshButton.layer else { return }

        // Layer-backed NSViews use anchorPoint (0, 0), so a plain
        // `transform.rotation.z` animation orbits around the button corner.
        // Rotate around the button centre with explicit transform keyframes
        // instead, leaving AppKit's layer geometry untouched.
        let center = CGPoint(
            x: modelRefreshButton.bounds.midX,
            y: modelRefreshButton.bounds.midY
        )
        let steps = 12
        var values: [CATransform3D] = []
        for step in 0...steps {
            let angle = -CGFloat.pi * 2 * CGFloat(step) / CGFloat(steps)
            var transform = CATransform3DIdentity
            transform = CATransform3DTranslate(transform, center.x, center.y, 0)
            transform = CATransform3DRotate(transform, angle, 0, 0, 1)
            transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
            values.append(transform)
        }

        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = values
        animation.duration = 0.7
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "model-refresh-spin")
    }

    // MARK: - Slash commands (/skill, /mcp)

    /// Returns the first token after `/`, or nil when arguments have started.
    private func slashToken(from text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        let token = rest.prefix { $0 != " " && $0 != "\t" && $0 != "\n" }
        guard token.count == rest.count else { return nil }
        return String(token)
    }

    private func updateCommandPalette() {
        guard mode == .selfHost,
              !isMinimized,
              !isCompact,
              let tab = activeRpcTab,
              !tab.commands.isEmpty,
              let token = slashToken(from: keyTape.text) else {
            hideCommandPalette()
            return
        }

        let query = token.lowercased()
        var candidates: [PiCommand] = []

        if query.isEmpty || "skill".hasPrefix(query) || query.hasPrefix("skill") {
            let matchesWholeGroup = query.isEmpty || "skill".hasPrefix(query)
            candidates += tab.commands.filter { command in
                guard command.source == "skill" else { return false }
                if matchesWholeGroup { return true }
                return command.name.lowercased().hasPrefix(query)
            }
        }
        if "mcp".hasPrefix(query) {
            candidates += tab.commands.filter { $0.name == "mcp" }
        }
        if query.isEmpty || "name".hasPrefix(query) {
            candidates.append(.sessionName)
        }
        if query.isEmpty || "reload".hasPrefix(query) {
            candidates.append(.reload)
        }
        if query.isEmpty || "compact".hasPrefix(query) {
            candidates.append(.compact)
        }

        guard !candidates.isEmpty else {
            hideCommandPalette()
            return
        }

        commandPalette.setCommands(candidates)
        positionCommandPalette()
        commandPalettePanel.orderFrontRegardless()
    }

    private func hideCommandPalette() {
        commandPalettePanel.orderOut(nil)
    }

    private func positionCommandPalette() {
        guard window.contentView != nil else { return }
        let input = keyTape.convert(keyTape.bounds, to: nil)
        let screenRect = window.convertToScreen(input)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame

        var width = max(320, screenRect.width)
        if let visible { width = min(width, max(320, visible.width - 8)) }

        var height = commandPalette.preferredHeight
        var originY = screenRect.maxY + 8
        if let visible {
            let available = max(120, visible.maxY - originY - 8)
            height = min(height, available)
            if originY + height > visible.maxY {
                originY = visible.maxY - height
            }
        }

        var originX = screenRect.minX
        if let visible {
            originX = min(
                max(originX, visible.minX + 4),
                visible.maxX - width - 4
            )
        }

        commandPalettePanel.setFrame(
            NSRect(x: originX, y: originY, width: width, height: height),
            display: true
        )
        commandPalette.needsLayout = true
    }

    private func acceptCommand(_ command: PiCommand) {
        let token = slashToken(from: keyTape.text)?.lowercased()
        hideCommandPalette()

        if command.action == .setSessionName {
            // The handler in sendPrompt parses arguments or opens the name
            // sheet, and clears the prompt.
            if token != command.name.lowercased() {
                keyTape.setText("/" + command.name)
                rawText = keyTape.text
            }
            sendPrompt()
            return
        }
        if command.action == .reloadPi {
            keyTape.setText("/reload")
            rawText = keyTape.text
            sendPrompt()
            return
        }
        if command.action == .compactSession {
            // Run the RPC `compact` command rather than sending the typed text: in RPC
            // mode a prompt that starts with `/compact` goes to the model as text,
            // because slash commands are executed by the TUI, not by the prompt path.
            keyTape.setText("")
            rawText = ""
            tape.removeAll()
            compactActiveSession(instructions: nil)
            return
        }

        if token == command.name.lowercased() {
            // The user already typed the exact command; execute it.
            keyTape.setText("/" + command.name)
            rawText = keyTape.text
            sendPrompt()
        } else {
            // Insert the selected command and leave the caret after it.
            let newText = "/" + command.name + " "
            keyTape.setText(newText)
            rawText = newText
            updateCommandPalette()
            focusOverlay()
        }
    }

    /// `/mcp` reports server status through `notify` records in RPC mode.
    /// Collect them briefly and show a small sheet with the output.
    private func startMCPCapture() {
        mcpCaptureToken += 1
        let token = mcpCaptureToken
        mcpCaptureLines = []
        mcpCaptureUntil = Date().addingTimeInterval(3)
        debugLog("mcp capture start token=\(token)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            guard let self, self.mcpCaptureToken == token else { return }
            self.mcpCaptureToken = 0
            self.mcpCaptureUntil = nil
            let lines = self.mcpCaptureLines
            self.mcpCaptureLines = []
            debugLog("mcp capture end lines=\(lines.count)")
            guard !lines.isEmpty,
                  self.window.isVisible,
                  self.window.attachedSheet == nil else { return }
            self.showAlert(title: "MCP", message: lines.joined(separator: "\n"))
        }
    }

    @objc private func sendFromButton() {
        if isProcessingActive {
            cancelActiveTurn()
        } else {
            sendPrompt()
        }
    }

    private var isProcessingActive: Bool {
        if mode == .selfHost, let tab = activeRpcTab {
            if tab.status == .processing { return true }
            // Compaction is its own model call, so the pill has to read as busy while a
            // summary is being written; otherwise Return queues a prompt into the middle
            // of it and pi aborts the summary.
            if tab.isCompacting { return true }
            if let session = tab.session, session.isStreaming { return true }
        }
        return keyTape.agentStatus == .processing
    }

    private func updateSendButton() {
        let processing = isProcessingActive
        sendButton.title = processing ? "■   Cancel" : "⌘ ↵   Send"
        if processing {
            sendButton.fillColor = NSColor(calibratedRed: 0.23, green: 0.11, blue: 0.12, alpha: 1)
            sendButton.textColor = NSColor(calibratedRed: 1.0, green: 0.56, blue: 0.56, alpha: 1)
        } else if isCompact {
            // Matches the compact mockup's blue pill.
            sendButton.fillColor = NSColor(calibratedRed: 0.15, green: 0.39, blue: 0.92, alpha: 1)
            sendButton.textColor = .white
        } else {
            sendButton.fillColor = Theme.inputRaised
            sendButton.textColor = Theme.inputText
        }
        sendButton.toolTip = processing
            ? "Cancel the running turn (Esc)"
            : "Send the prompt (Return)"
        sendButton.needsDisplay = true
    }

    private func cancelActiveTurn() {
        switch mode {
        case .selfHost:
            guard let tab = activeRpcTab, let session = tab.session else { return }
            guard tab.status == .processing || session.isStreaming || tab.isCompacting else { return }
            // During a summary this is the only way out: pi's abort stops the
            // compaction and `compaction_end` reports it as aborted.
            session.abort()
            statusLabel.stringValue = "CANCELLING…"
            statusLabel.textColor = .systemOrange
        case .tty:
            guard let injector else { return }
            _ = injector.inject("\u{1b}")
        case .terminal, .selfTerminal:
            guard let terminalInjector else { return }
            _ = terminalInjector.sendKey(53)
        case .apple:
            guard let appleInjector else { return }
            _ = appleInjector.sendKey(53)
        case .dry:
            return
        }
        focusOverlay()
    }

    @objc private func attachImage() {
        guard mode == .selfHost else { return }
        if isMinimized { toggleMinimize() }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]
        panel.message = "Pick images to send with the next prompt."
        panel.prompt = "Attach"
        NSApp.activate(ignoringOtherApps: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let mime: String
                switch url.pathExtension.lowercased() {
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "webp": mime = "image/webp"
                default: continue
                }
                self.pendingImages.append([
                    "type": "image",
                    "data": data.base64EncodedString(),
                    "mimeType": mime,
                ])
                self.pendingImageNames.append(url.lastPathComponent)
            }
            self.updateAttachmentChip()
            self.focusOverlay()
        }
    }

    @objc private func attachFiles() {
        guard mode == .selfHost else { return }
        if isMinimized { toggleMinimize() }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Insert the selected file paths into the prompt."
        panel.prompt = "Insert"
        NSApp.activate(ignoringOtherApps: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let paths = panel.urls.map { url -> String in
                url.path.contains(" ") ? "\"\(url.path)\"" : url.path
            }
            guard !paths.isEmpty else { return }
            let addition = paths.joined(separator: " ")
            if self.keyTape.text.isEmpty {
                self.keyTape.insert(addition)
            } else {
                self.keyTape.insert(" " + addition)
            }
            self.rawText = self.keyTape.text
            self.focusOverlay()
        }
    }

    @objc private func clearAttachments() {
        pendingImages.removeAll()
        pendingImageNames.removeAll()
        updateAttachmentChip()
    }

    private func updateAttachmentChip() {
        let count = pendingImages.count
        attachmentChip.isHidden = count == 0
        if count == 0 {
            imageButton.setSymbol("photo", size: 15, tint: Theme.inputText)
            attachmentChip.title = ""
        } else {
            imageButton.setSymbol("photo.fill", size: 15, tint: Theme.accent)
            attachmentChip.title = count == 1 ? "1 image  ×" : "\(count) images  ×"
        }
        layoutViews()
    }

    @objc private func showDiagnosticsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let log = NSMenuItem(title: "Show debug log", action: #selector(openDebugLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        let profiles = NSMenuItem(title: "Open profiles.conf", action: #selector(openProfilesConf), keyEquivalent: "")
        profiles.target = self
        menu.addItem(profiles)
        let agent = NSMenuItem(title: "Open pi agent folder", action: #selector(openPiAgentFolder), keyEquivalent: "")
        agent.target = self
        menu.addItem(agent)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    @objc private func openDebugLog() {
        let url = URL(fileURLWithPath: "/tmp/pi-overlay-native.log")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openProfilesConf() {
        let url = profileStore.url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openPiAgentFolder() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent")
        )
    }

    @objc private func copyResponse() {
        let text: String
        if mode == .selfHost, let tab = activeRpcTab {
            text = displayText(for: tab)
        } else {
            text = responseText
        }
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        flashStatus("COPIED", tone: .ok)
    }

    @objc private func downloadResponse() {
        let text: String
        if mode == .selfHost, let tab = activeRpcTab {
            text = displayText(for: tab)
        } else {
            text = responseText
        }
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "response.md"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.message = "Save the current response."
        panel.prompt = "Save"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.flashStatus("SAVED", tone: .ok)
            } catch {
                self.flashStatus("SAVE ERROR", tone: .bad)
            }
        }
    }

    private enum FlashTone { case ok, warn, bad }

    /// Shows a short confirmation in the header pill, then restores the idle
    /// status for the active tab.
    private func flashStatus(_ text: String, tone: FlashTone) {
        statusLabel.stringValue = text
        switch tone {
        case .ok: statusLabel.textColor = .systemGreen
        case .warn: statusLabel.textColor = .systemOrange
        case .bad: statusLabel.textColor = .systemRed
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.showIdleStatus()
        }
    }

    /// Hides the window without closing it: the pi children, tabs and prompt
    /// keep running, and the menu-bar icon brings the overlay back.
    @objc func hideOverlay() {
        guard window.isVisible else { return }
        hideCommandPalette()
        window.orderOut(nil)
        debugLog("hidden; reopen from the menu-bar icon")
    }

    // MARK: - Notifications

    private static let clickNotificationName =
        NSNotification.Name("com.abmateen.pi-overlay.notification-click")

    /// The helper `.app` that owns the notification permission (see
    /// notifier.swift). macOS refuses UserNotifications for a process that was
    /// not launched as an app bundle, which is how the pi extension starts the
    /// overlay, so posting goes through this bundle instead.
    private var notificationHelperURL: URL? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["PI_OVERLAY_NOTIFIER"] {
            candidates.append(override)
        }
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/PiOverlayNotifier.app").path
        )
        candidates.append(
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("PiOverlayNotifier.app").path
        )

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Listens for the helper's click report; a click brings the overlay back
    /// on the tab that finished.
    func setupNotifications() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.clickNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo ?? [:]
            let profile = info["profile"] as? String ?? ""
            let tabID = (info["tab"] as? String).flatMap { UUID(uuidString: $0) }
            self.openFromNotification(profile: profile, tabID: tabID)
        }
        debugLog("notifications helper=\(notificationHelperURL?.path ?? "missing")")
    }

    /// Posts "prompt finished" when the overlay is hidden, carrying enough
    /// context to jump back to the tab that finished. The notification only
    /// names the tab; the answer itself stays in the overlay.
    private func notifyTurnFinished(profile: String?, tab: RpcTab?) {
        guard !window.isVisible else { return }

        let tabName = tab?.displayName ?? activeDirectory.lastPathComponent
        postNotification(
            title: tabName,
            body: "Update is available under the tab",
            profile: profile ?? "",
            tab: tab
        )
    }

    /// Which profile a tab belongs to, active or parked.
    private func profileName(for tab: RpcTab) -> String? {
        if rpcTabs.contains(where: { $0.id == tab.id }) { return activeProfileName }
        for (name, runtime) in profileRuntime
        where runtime.tabs.contains(where: { $0.id == tab.id }) {
            return name
        }
        return nil
    }

    private func postNotification(
        title: String,
        body: String,
        profile: String,
        tab: RpcTab?
    ) {
        guard let helper = notificationHelperURL else {
            debugLog("notification skipped: PiOverlayNotifier.app not installed")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", "-a", helper.path, "--args",
            "--post",
            "--title", title,
            "--body", body,
            "--profile", profile,
            "--tab", tab?.id.uuidString ?? "",
        ]
        do {
            try process.run()
            debugLog("notification posted title='\(title)' body='\(body)' tab=\(tab?.id.uuidString ?? "nil")")
        } catch {
            debugLog("notification helper failed: \(error)")
        }
    }

    /// Brings the overlay back on the tab that finished.
    private func openFromNotification(profile: String, tabID: UUID?) {
        debugLog("notification clicked profile=\(profile) tab=\(tabID?.uuidString ?? "nil")")

        if !profile.isEmpty, profile != activeProfileName {
            switchProfile(to: profile)
        }
        if let tabID, let tab = rpcTab(withID: tabID) {
            activateRpcTab(tab)
        }
        statusShowOverlay()
    }

    @objc func toggleMinimize() {
        if isCompact { exitCompact() }
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

    // MARK: - Compact textbox mode

    /// Toggle the capsule-only view: one rounded textbox on a transparent
    /// window, with a small restore control above its right end.
    @objc func toggleCompact() {
        if isCompact {
            exitCompact()
        } else {
            enterCompact()
        }
    }

    private static let compactHeight: CGFloat = 96

    private func setCompactChrome(_ compact: Bool) {
        guard let container = window.contentView else { return }
        container.layer?.backgroundColor = compact
            ? NSColor.clear.cgColor
            : Theme.card.cgColor
        container.layer?.borderWidth = compact ? 0 : 1
        container.layer?.borderColor = Theme.border.cgColor
    }

    private func enterCompact() {
        guard !isCompact else { return }
        hideCommandPalette()
        if isMinimized { toggleMinimize() }
        if speech.isListening { stopVoice() }

        compactRestoreFrame = window.frame
        expandedHeight = window.frame.height
        // Keep the 96 pt capsule out of the frame autosave: it is not a window
        // shape the user wants restored on the next launch.
        setFrameAutosave(false)
        isCompact = true
        setCompactChrome(true)

        // Compact capsules live at the bottom-centre of the screen, with a
        // little breathing room above the Dock / screen edge so they never
        // hide behind it. `visibleFrame` already excludes the Dock and menu bar.
        let height = Self.compactHeight
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bottomPadding: CGFloat = 28
        let maxWidth = max(420, visible.width - 48)
        let width = min(max(420, window.frame.width), maxWidth)
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + bottomPadding,
            width: width,
            height: height
        )
        window.minSize = NSSize(width: 420, height: height)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)
        window.setFrame(frame, display: true)
        debugLog(
            "compact frame=\(NSStringFromRect(frame)) "
                + "visible=\(NSStringFromRect(visible))"
        )

        layoutViews()
        updateMinimizeButton()
        updateSendButton()
        focusOverlay()
        debugLog("compact mode on")
    }

    private func exitCompact() {
        guard isCompact else { return }
        isCompact = false
        keyTape.isCompact = false
        setCompactChrome(false)
        window.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        window.minSize = baseMinSize

        if let frame = compactRestoreFrame {
            expandedHeight = frame.height
            window.setFrame(frame, display: true)
        }
        compactRestoreFrame = nil
        // Re-enable after the restore frame is in place: turning autosave back on
        // reapplies the saved frame, which is the expanded one we just set.
        setFrameAutosave(true)

        layoutViews()
        updateMinimizeButton()
        updateSendButton()
        focusOverlay()
        debugLog("compact mode off")
    }

    /// Frame autosave on/off around the capsule. Turning it off keeps the compact
    /// geometry out of the saved frame; turning it back on reapplies that saved
    /// (expanded) frame. Preview runs never touch the autosave at all.
    private func setFrameAutosave(_ active: Bool) {
        guard !isPreviewMode else { return }
        window.setFrameAutosaveName(active ? "PiOverlayWindow" : "")
    }

    private static func capsuleMask(size: NSSize) -> NSImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: size.height / 2,
            yRadius: size.height / 2
        ).fill()
        image.unlockFocus()
        return image
    }

    private func layoutCompact(width: CGFloat, height: CGFloat) {
        let capsuleHeight = min(72, max(56, height - 32))
        keyTape.frame = NSRect(x: 8, y: 0, width: width - 16, height: capsuleHeight)
        keyTape.isCompact = true
        keyTape.alphaValue = 1

        let micSize = min(40, capsuleHeight - 14)
        voiceButton.frame = NSRect(
            x: 13,
            y: (capsuleHeight - micSize) / 2,
            width: micSize,
            height: micSize
        )
        voiceButton.layer?.cornerRadius = micSize / 2
        voiceButton.isHidden = false

        let sendWidth: CGFloat = 104
        let sendHeight: CGFloat = 38
        let sendX = keyTape.bounds.width - 12 - sendWidth
        sendButton.frame = NSRect(
            x: sendX,
            y: (capsuleHeight - sendHeight) / 2,
            width: sendWidth,
            height: sendHeight
        )
        sendButton.isHidden = false

        let pidWidth: CGFloat = 84
        // The capsule's identity slot is the RPC child's pid in self mode, but
        // `pidLabel` is empty in tty mode — name the terminal it types into.
        compactPidLabel.stringValue = mode == .tty
            ? (ttyPath.map { "TTY " + ($0 as NSString).lastPathComponent } ?? "")
            : pidLabel.stringValue
        compactPidLabel.frame = NSRect(
            x: sendX - 8 - pidWidth,
            y: (capsuleHeight - 18) / 2,
            width: pidWidth,
            height: 18
        )
        compactPidLabel.isHidden = false
        compactBackdrop.frame = keyTape.frame
        compactBackdrop.layer?.cornerRadius = capsuleHeight / 2
        compactBackdrop.layer?.masksToBounds = true
        compactBackdrop.maskImage = Self.capsuleMask(size: keyTape.frame.size)
        compactBackdrop.isHidden = false
        keyTape.compactRightInset = 13 + sendWidth + 8 + pidWidth + 14
        keyTape.statusRightInset = keyTape.compactRightInset

        imageButton.isHidden = true
        attachButton.isHidden = true
        attachmentChip.isHidden = true

        let hiddenViews: [NSView] = [
            tabBar, statusLabel, targetLabel, terminalTitleLabel,
            directoryPopup, modelPopup, modelRefreshButton, thinkingPopup, pidLabel, sessionIcon, sessionLabel,
            sessionPopup, newSessionButton, headerDivider,
            responseButton, responseDivider, queryPopup, thinkingButton, responseWebView,
            responseCopyButton, responseDownloadButton, responseExpandButton,
            footerView, terminalButton, panelButton, hideButton, compactButton,
            minimizeButton, closeButton, topDivider,
        ]
        for view in hiddenViews { view.isHidden = true }
        for tab in rpcTabs { tab.webView.isHidden = true }

        compactRestoreButton.frame = NSRect(
            x: width - 44,
            y: capsuleHeight + 2,
            width: 26,
            height: 26
        )
        compactRestoreButton.isHidden = false
        compactHideButton.frame = NSRect(
            x: compactRestoreButton.frame.minX - 6 - 26,
            y: compactRestoreButton.frame.minY,
            width: 26,
            height: 26
        )
        compactHideButton.isHidden = false

        if mode == .selfHost {
            let tabName = activeRpcTab?.displayName ?? "New Tab"
            compactContextLabel.stringValue = "\(activeProfileName) · \(tabName)"
            compactContextLabel.isHidden = false
        } else {
            compactContextLabel.stringValue = ""
            compactContextLabel.isHidden = true
        }
        compactContextLabel.frame = NSRect(
            x: keyTape.frame.minX + 4,
            y: capsuleHeight + 4,
            width: max(
                80,
                compactHideButton.frame.minX - 8 - (keyTape.frame.minX + 4)
            ),
            height: 20
        )

        keyTape.needsDisplay = true
        keyTape.needsLayout = true
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

    private static let responsePanelHeight: CGFloat = 180

    /// Height the key tape keeps while the response panel is open. Extra
    /// window height from scaling the overlay goes to the response panel
    /// instead of stretching the textbox.
    private static let keyTapeBaseHeight: CGFloat = 150

    /// Height at which the key tape keeps its normal size with the response
    /// panel open. Growing to this once (instead of on every toggle) keeps the
    /// window size predictable and avoids drift between launches.
    private var comfortableHeight: CGFloat {
        (mode == .selfHost ? 430 : 360) + Self.responsePanelHeight
    }

    /// Height reserved under the header row for the saved-session list.
    private static let sessionRowHeight: CGFloat = 34
    private var sessionRowExtra: CGFloat { mode == .selfHost ? 44 : 0 }

    /// The user owns the window height. The only adjustment made here is to
    /// make room for the response panel when the window is too short for it.
    private func syncResponsePanelHeight() {
        guard responseExpanded, !isMinimized, !isCompact else { return }
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

        if isCompact {
            hideCommandPalette()
            layoutCompact(width: width, height: height)
            window.invalidateCursorRects(for: container)
            updateResponseButton()
            updateSendButton()
            return
        }

        compactRestoreButton.isHidden = true
        compactHideButton.isHidden = true
        compactPidLabel.isHidden = true
        compactContextLabel.isHidden = true
        compactBackdrop.isHidden = true
        keyTape.isCompact = false
        voiceButton.layer?.cornerRadius = 10

        let tabBarExtra: CGFloat = mode == .selfHost ? Theme.tabStripHeight : 0
        let headerBase = height - tabBarExtra
        // In RPC mode the collapsed window shows only the tab strip, so the
        // header contents go away. The window controls stay in the tab strip.
        let collapseHeader = isMinimized && mode == .selfHost

        let textY: CGFloat = Theme.footerHeight + 8
        let sessionRow = sessionRowExtra
        let responseVisible = responseExpanded && !isMinimized
        let headerRowHeight: CGFloat = 34
        let headerRowY = headerBase - 10 - headerRowHeight
        let sessionRowHeight: CGFloat = 34
        let sessionRowY = headerRowY - 10 - sessionRowHeight
        let inputTop = sessionRow > 0 ? sessionRowY - 12 : headerRowY - 12
        let responseRowHeight: CGFloat = 34

        var textHeight: CGFloat = 0
        if responseVisible {
            let available = max(0, inputTop - textY - responseRowHeight - 8)
            textHeight = max(Self.responsePanelHeight, available - Self.keyTapeBaseHeight)
        }
        let responseRowY = responseVisible ? textY + textHeight + 8 : textY
        let keyY = responseRowY + responseRowHeight + 8
        let keyHeight = max(96, inputTop - keyY)

        // MARK: Top bar (profile + tabs + window controls)

        tabBar.frame = NSRect(
            x: 0,
            y: height - Theme.tabStripHeight,
            width: width,
            height: Theme.tabStripHeight
        )
        tabBar.isHidden = mode != .selfHost
        tabSeparator.frame = NSRect(x: 0, y: 0, width: width, height: 1)

        let iconSize: CGFloat = 30
        let iconGap: CGFloat = 4
        let iconCount = 6
        let clusterWidth = CGFloat(iconCount) * iconSize + CGFloat(iconCount - 1) * iconGap
        var iconX = width - 14 - clusterWidth
        let iconY = height - Theme.tabStripHeight + (Theme.tabStripHeight - iconSize) / 2
        for button in [terminalButton, panelButton, hideButton, compactButton, minimizeButton, closeButton] {
            button.frame = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
            iconX += iconSize + iconGap
        }
        panelButton.isHidden = mode != .selfHost
        terminalButton.isHidden = false
        compactButton.isHidden = false
        topDivider.isHidden = mode != .selfHost
        topDivider.frame = NSRect(
            x: minimizeButton.frame.minX - 8,
            y: iconY + 6,
            width: 1,
            height: iconSize - 12
        )

        // These live inside tabBar, so their y coordinates are relative to it.
        let topControlY: CGFloat = 11
        profilePopup.frame = NSRect(x: 14, y: topControlY, width: 168, height: 34)
        profilePopup.isHidden = mode != .selfHost

        let rightmostPlusX = width - 14 - clusterWidth - 10 - 30
        let plusX = min(rightmostPlusX, 190 + tabContentWidth + 8)
        newTabButton.frame = NSRect(x: plusX, y: topControlY + 2, width: 30, height: 30)
        newTabButton.isHidden = mode != .selfHost
        tabScrollView.frame = NSRect(
            x: 190,
            y: topControlY,
            width: max(40, plusX - 8 - 190),
            height: 34
        )

        // MARK: Header row (status, folder, model, pid)

        statusLabel.frame = NSRect(x: 16, y: headerRowY + 3, width: 132, height: 28)
        let dividerX: CGFloat = 16 + 132 + 12
        headerDivider.frame = NSRect(x: dividerX, y: headerRowY + 6, width: 1, height: 22)
        let contentX: CGFloat = dividerX + 15
        let pidWidth: CGFloat = 100
        let pidX = width - 16 - pidWidth
        let refreshWidth: CGFloat = 30
        let refreshGap: CGFloat = 6
        let reasoningWidth: CGFloat = Theme.thinkingPopupWidth
        let reasoningGap: CGFloat = 8
        let available: CGFloat = max(180, pidX - 10 - contentX)
        let directoryWidth: CGFloat = max(
            150,
            min(available * 0.46, available - 140 - 8 - reasoningWidth - reasoningGap)
        )
        let modelNaturalWidth: CGFloat = available - directoryWidth - 8
            - refreshWidth - refreshGap - reasoningWidth - reasoningGap
        let modelWidth: CGFloat = max(120, modelNaturalWidth)
        // A narrow window cannot fit the reasoning control, so it drops out instead
        // of squeezing the model name down to a couple of characters.
        let showReasoning = modelNaturalWidth >= 120

        if isSelfMode {
            directoryPopup.frame = NSRect(
                x: contentX,
                y: headerRowY,
                width: directoryWidth,
                height: headerRowHeight
            )
            modelPopup.frame = NSRect(
                x: contentX + directoryWidth + 8,
                y: headerRowY,
                width: modelWidth,
                height: headerRowHeight
            )
            modelRefreshButton.frame = NSRect(
                x: modelPopup.frame.maxX + refreshGap,
                y: headerRowY + 2,
                width: refreshWidth,
                height: headerRowHeight - 4
            )
            if showReasoning {
                thinkingPopup.frame = NSRect(
                    x: modelRefreshButton.frame.maxX + reasoningGap,
                    y: headerRowY,
                    width: reasoningWidth,
                    height: headerRowHeight
                )
            }
            pidLabel.frame = NSRect(x: pidX, y: headerRowY + 8, width: pidWidth, height: 20)
        } else {
            targetLabel.frame = NSRect(x: contentX - 8, y: headerRowY + 10, width: 150, height: 18)
            let titleX: CGFloat = contentX + 142
            let titleMaxX = width - 14 - clusterWidth - 8 - reasoningWidth - reasoningGap
            terminalTitleLabel.frame = NSRect(
                x: titleX,
                y: headerRowY + 11,
                width: max(60, titleMaxX - titleX),
                height: 16
            )
            if showReasoning {
                thinkingPopup.frame = NSRect(
                    x: titleMaxX + reasoningGap,
                    y: headerRowY,
                    width: reasoningWidth,
                    height: headerRowHeight
                )
            }
        }
        targetLabel.isHidden = isSelfMode || collapseHeader
        terminalTitleLabel.isHidden = isSelfMode || collapseHeader
        directoryPopup.isHidden = !isSelfMode || collapseHeader
        modelPopup.isHidden = mode != .selfHost || collapseHeader
        thinkingPopup.isHidden = collapseHeader || !showReasoning
            || !(mode == .selfHost || mode == .tty)
        modelRefreshButton.isHidden = mode != .selfHost || collapseHeader
        pidLabel.isHidden = mode != .selfHost || collapseHeader
        headerDivider.isHidden = !isSelfMode || collapseHeader
        statusLabel.isHidden = collapseHeader
        closeButton.isHidden = false
        hideButton.isHidden = false
        minimizeButton.isHidden = false

        // The textbox is never visible while collapsed, but it stays in the
        // window (transparent, not hidden) so it remains first responder and
        // the Option/Ctrl/Cmd chords keep working.
        keyTape.alphaValue = isMinimized ? 0 : 1

        // MARK: Sessions row

        let showSessionRow = sessionRow > 0 && !collapseHeader
        sessionIcon.isHidden = !showSessionRow
        sessionLabel.isHidden = !showSessionRow
        sessionPopup.isHidden = !showSessionRow
        newSessionButton.isHidden = !showSessionRow
        if showSessionRow {
            sessionIcon.frame = NSRect(x: 18, y: sessionRowY + 9, width: 18, height: 18)
            sessionLabel.frame = NSRect(x: 42, y: sessionRowY + 9, width: 70, height: 18)
            let plusSize: CGFloat = 34
            newSessionButton.frame = NSRect(
                x: width - 16 - plusSize,
                y: sessionRowY,
                width: plusSize,
                height: plusSize
            )
            let popupX: CGFloat = 116
            sessionPopup.frame = NSRect(
                x: popupX,
                y: sessionRowY,
                width: max(120, newSessionButton.frame.minX - 8 - popupX),
                height: sessionRowHeight
            )
        }

        // MARK: Input card

        keyTape.frame = NSRect(x: 16, y: keyY, width: width - 32, height: keyHeight)

        let buttonSize: CGFloat = 34
        let bottomY = keyTape.bounds.height - buttonSize - 12
        voiceButton.frame = NSRect(x: 16, y: bottomY, width: buttonSize, height: buttonSize)
        imageButton.frame = NSRect(x: 58, y: bottomY, width: buttonSize, height: buttonSize)
        attachButton.frame = NSRect(x: 100, y: bottomY, width: buttonSize, height: buttonSize)
        imageButton.isHidden = mode != .selfHost
        attachButton.isHidden = mode != .selfHost

        let chipAttrs: [NSAttributedString.Key: Any] = [.font: Theme.font(10, .medium)]
        let chipWidth = pendingImages.isEmpty
            ? 0
            : (attachmentChip.title as NSString).size(withAttributes: chipAttrs).width + 24
        attachmentChip.frame = NSRect(x: 144, y: bottomY + 7, width: chipWidth, height: 20)
        attachmentChip.isHidden = pendingImages.isEmpty || mode != .selfHost

        let sendWidth: CGFloat = 108
        sendButton.frame = NSRect(
            x: keyTape.bounds.width - 16 - sendWidth,
            y: bottomY,
            width: sendWidth,
            height: buttonSize
        )
        keyTape.statusRightInset = 16 + sendWidth + 12
        keyTape.needsDisplay = true

        // MARK: Response row

        responseButton.frame = NSRect(x: 16, y: responseRowY + 4, width: 118, height: 26)
        responseDivider.frame = NSRect(x: 140, y: responseRowY + 8, width: 1, height: 18)

        let responseIcon: CGFloat = 28
        var responseIconX = width - 16 - responseIcon
        responseExpandButton.frame = NSRect(
            x: responseIconX,
            y: responseRowY + 3,
            width: responseIcon,
            height: responseIcon
        )
        responseIconX -= responseIcon + 4
        responseDownloadButton.frame = NSRect(
            x: responseIconX,
            y: responseRowY + 3,
            width: responseIcon,
            height: responseIcon
        )
        responseIconX -= responseIcon + 4
        responseCopyButton.frame = NSRect(
            x: responseIconX,
            y: responseRowY + 3,
            width: responseIcon,
            height: responseIcon
        )

        let thinkingWidth: CGFloat = 30
        let thinkingX = responseIconX - 12 - thinkingWidth
        thinkingButton.frame = NSRect(
            x: thinkingX,
            y: responseRowY + 3,
            width: thinkingWidth,
            height: 28
        )

        let queryX: CGFloat = 152
        let queryWidth = max(120, thinkingX - 8 - queryX)
        queryPopup.frame = NSRect(x: queryX, y: responseRowY, width: queryWidth, height: 34)
        queryPopup.isHidden = isMinimized || isCompact || sessionQueries.isEmpty

        if mode == .selfHost {
            responseWebView.isHidden = true
            for tab in rpcTabs {
                tab.webView.frame = NSRect(
                    x: 16,
                    y: textY,
                    width: width - 32,
                    height: textHeight
                )
                tab.webView.isHidden = isMinimized || !(tab.id == activeRpcTabID && responseExpanded)
            }
        } else {
            responseWebView.frame = NSRect(
                x: 16,
                y: textY,
                width: width - 32,
                height: textHeight
            )
            responseWebView.isHidden = isMinimized || !responseExpanded
        }

        // MARK: Footer (context usage + token rate)

        footerView.isHidden = isMinimized
        footerView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: Theme.footerHeight
        )

        window.invalidateCursorRects(for: container)
        updateResponseButton()
        updateSendButton()
        updateFooter()

        if commandPalettePanel.isVisible {
            if isMinimized {
                hideCommandPalette()
            } else {
                positionCommandPalette()
            }
        }
    }

    /// Dev-only: inject a prompt into the active tab (PI_OVERLAY_TEST_PROMPT).
    /// Dev-only: trigger the model refresh button (PI_OVERLAY_TEST_REFRESH).
    func refreshModelsForTesting() {
        refreshModels()
    }

    /// Dev-only: exercise the response copy path (PI_OVERLAY_TEST_COPY).
    func copyResponseForTesting() {
        let webView: WKWebView?
        if mode == .selfHost {
            webView = activeRpcTab?.webView
        } else {
            webView = responseWebView
        }
        guard let webView else { return }
        copySelectionFromResponse(webView)
    }

    func sendPromptForTesting(_ text: String) {
        if ProcessInfo.processInfo.environment["PI_OVERLAY_TEST_THINKING"] == "1",
           let tab = activeRpcTab {
            tab.showThinking = true
            applyThinkingButtonState()
            ensureThinkingPanelOpen(tab)
        }
        keyTape.setText(text)
        rawText = text
        sendPrompt()
    }

    /// Dev-only: render the window to a PNG so the theme can be checked
    /// without screen-recording permission. Triggered by PI_OVERLAY_PREVIEW.
    func renderPreview(to path: String) {
        let minimized = ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW_MIN"] == "1"
        isMinimized = minimized
        // A tty overlay is already compact by the time the preview runs; resizing
        // it to the full height would render the capsule inside a tall window.
        if !isCompact {
            window.setFrame(
                NSRect(
                    x: 0,
                    y: 0,
                    width: 900,
                    height: minimized ? Theme.tabStripHeight : 695
                ),
                display: true
            )
        }

        rpcTabs = []
        let tab = makeBlankTab()
        tab.directory = URL(fileURLWithPath: NSHomeDirectory() + "/code/pi-overlay-native")
        tab.currentModel = [
            "provider": "ollama-cloud",
            "id": "deepseek-v4.1-flash",
            "name": "DeepSeek V4.1 Flash",
        ]
        tab.models = [tab.currentModel!]
        tab.status = .done
        tab.latestAnswerText = """
        The power stage uses a two-phase buck with a 48 V input and a 0.9 V core rail.         Keep the inductor ripple below 30% and give the feedback divider a dedicated         kelvin return.
        """
        tab.responseText = tab.latestAnswerText
        tab.queries = [SessionQuery(
            id: "preview-1",
            prompt: "Lets discuss power supply in this session for our board",
            answer: tab.latestAnswerText
        )]
        tab.rawText = ""
        tab.contextTokens = 60124
        tab.contextWindow = 200000
        tab.tokensPerSecond = 14.2
        // Seed a compaction result so the footer's `↓` marker is exercised too.
        tab.compactedBefore = 118000
        tab.compactedAfter = 60124
        // Seed the streamed estimate too, otherwise the processing preview shows
        // the reported rate and never exercises the `≈` path.
        tab.estimatedTokensPerSecond = 11.3
        tab.thinkingLevel = "high"
        tab.thinkingLevels = ["off", "low", "medium", "high"]
        rpcTabs = [tab]
        activeRpcTabID = tab.id
        activeDirectory = tab.directory!

        let processing = ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW_PROCESSING"] == "1"
        tab.status = processing ? .processing : .done
        keyTape.setText("")
        keyTape.agentStatus = processing ? .processing : .done
        keyTape.needsDisplay = true

        statusLabel.stringValue = "READY"
        statusLabel.textColor = .systemGreen

        sessionInfos = [PiSessionInfo(
            path: "/preview/session.jsonl",
            name: "Lets discuss power supply in this session for our board",
            preview: nil,
            modified: Date()
        )]
        sessionQueries = tab.queries
        selectedQueryID = nil

        let profileMenu = NSMenu()
        let profileHeader = NSMenuItem(title: "localllm", action: nil, keyEquivalent: "")
        profileMenu.addItem(profileHeader)
        profilePopup.menu = profileMenu
        profilePopup.title = "localllm"
        activeProfileName = "localllm"
        responseText = tab.responseText
        responseExpanded = ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW_RESPONSE"] == "1"
        responseUserCollapsed = !responseExpanded
        directoryPopup.title = "📁 pi-overlay-native"
        directoryPopup.toolTip = tab.directory?.path
        pidLabel.stringValue = "pi 6288"
        if ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW_ERROR"] == "1" {
            showAssistantFailure(
                "Request timed out after 120s while waiting for the provider.",
                title: "Request failed",
                tab: tab,
                isActive: true
            )
        }
        if ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW_COMMANDS"] == "1" {
            tab.commands = [
                PiCommand(json: [
                    "name": "skill:ascii-diagram",
                    "description": "Render ASCII box-drawing diagrams to PNG.",
                    "source": "skill",
                ]),
                PiCommand(json: [
                    "name": "skill:explainer-video",
                    "description": "Write a script and storyboard for a short explainer.",
                    "source": "skill",
                ]),
                PiCommand(json: [
                    "name": "skill:wrapped-video",
                    "description": "Build a Spotify Wrapped style data video.",
                    "source": "skill",
                ]),
                PiCommand(json: [
                    "name": "mcp",
                    "description": "Manage MCP servers: sign in, reconnect, enable or disable.",
                    "source": "extension",
                ]),
            ].compactMap { $0 }
            keyTape.setText("/")
            updateCommandPalette()
            commandPalette.layoutSubtreeIfNeeded()
            if let content = commandPalettePanel.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path + ".palette.png"))
                }
            }
        }
        if ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW_THINKING"] == "1" {
            tab.showThinking = true
            tab.thinkingText = "The user is asking about the power stage. I should cover the two-phase buck, inductor ripple and the feedback divider return."
            tab.queries[0].thinking = tab.thinkingText
            debugLog("preview thinking display=\(displayText(for: tab).prefix(300))")
            responseExpanded = true
            responseUserCollapsed = false
            tab.responseExpanded = true
            tab.responseUserCollapsed = false
            renderTabResponse(tab)
        }
        if ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW_COMPACT"] == "1" {
            enterCompact()
        } else if ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW_COMPACT_EXIT"] == "1" {
            enterCompact()
            exitCompact()
        }
        rebuildDirectoryMenu()
        rebuildModelMenu()
        rebuildThinkingMenu()
        rebuildSessionMenu()
        rebuildQueryMenu()
        rebuildTabBar()
        layoutViews()
        updateResponseButton()
        modelPopup.isEnabled = true
        sessionPopup.isEnabled = true
        newSessionButton.isEnabled = true

        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        debugLog("preview rendered to \(path) size=\(rep.pixelsWide)x\(rep.pixelsHigh)")
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
        if !isMinimized, !isCompact { expandedHeight = window.frame.height }
        layoutViews()
    }

    func windowDidMove(_ notification: Notification) {
        if commandPalettePanel.isVisible {
            positionCommandPalette()
        }
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

        if commandPalettePanel.isVisible,
           !mods.contains(.command),
           !mods.contains(.control),
           !mods.contains(.option) {
            switch event.keyCode {
            case 126:                       // up
                commandPalette.moveSelection(-1)
                return true
            case 125:                       // down
                commandPalette.moveSelection(1)
                return true
            case 48:                        // tab
                if let command = commandPalette.selectedCommand() {
                    acceptCommand(command)
                }
                return true
            case 36, 76:                    // return / keypad enter
                if mods.contains(.shift) {
                    hideCommandPalette()
                    return false
                }
                if let command = commandPalette.selectedCommand() {
                    acceptCommand(command)
                }
                return true
            case 53:                        // escape
                hideCommandPalette()
                return true
            default:
                break
            }
        }

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

        // Escape cancels the running turn (RPC abort, or Escape in a TTY).
        if event.keyCode == 53 {
            if isProcessingActive {
                cancelActiveTurn()
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
        updateCommandPalette()
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

        if isSelfMode, chunk == "/mcp" || chunk.hasPrefix("/mcp ") {
            startMCPCapture()
        }
        if handleSessionNameCommand(chunk) { return }
        if handleReloadCommand(chunk) { return }
        if handleCompactCommand(chunk) { return }

        // The command handlers above still run while compacting, but nothing else may
        // be sent: pi would abort the summary to take the prompt.
        if mode == .selfHost, let tab = activeRpcTab, tab.isCompacting {
            flashStatus("COMPACTING — CANNOT SEND", tone: .warn)
            return
        }

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
        if let prompt = ProcessInfo.processInfo.environment["PI_OVERLAY_TEST_PROMPT"],
           !prompt.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.controller.sendPromptForTesting(prompt)
            }
        }
        if ProcessInfo.processInfo.environment["PI_OVERLAY_TEST_REFRESH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.controller.refreshModelsForTesting()
            }
        }
        if ProcessInfo.processInfo.environment["PI_OVERLAY_TEST_COPY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.controller.copyResponseForTesting()
            }
        }
        controller.installStatusItem()
        controller.setupNotifications()

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
let app = NSApplication.shared
let controller = OverlayController(mode: mode, ttyPath: ttyPath, directory: directory)
if let preview = ProcessInfo.processInfo.environment["PI_OVERLAY_PREVIEW"], !preview.isEmpty {
    app.setActivationPolicy(.accessory)
    controller.renderPreview(to: preview)
    exit(0)
}
let appDelegate = AppDelegate(controller: controller)
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()