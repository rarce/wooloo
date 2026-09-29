import AppKit
import SwiftUI

/// A small AppKit input surface for Herdr's rendered pane snapshot. Herdr still
/// owns the PTY; this view only displays its text and forwards keyboard input.
struct TerminalPaneView: NSViewRepresentable {
    static let terminalFont = NSFont(name: "FiraCodeNFM-Reg", size: 12)
        ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let cellWidth = ("M" as NSString).size(withAttributes: [.font: terminalFont]).width
    static let cellHeight = NSLayoutManager().defaultLineHeight(for: terminalFont)

    let text: String
    let paneID: String
    var surface: HerdrSurface? = nil
    var selectPane: ((String) -> Void)? = nil
    let sendText: (String, String) -> Void
    let sendPaste: (String, String) -> Void
    let sendKey: (String, String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(red: 0.075, green: 0.082, blue: 0.091, alpha: 1)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let view = HerdrTerminalTextView(frame: .zero)
        view.paneID = paneID
        view.sendText = sendText
        view.sendPaste = sendPaste
        view.sendKey = sendKey
        view.selectPane = selectPane
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.drawsBackground = false
        view.textColor = NSColor(red: 0.88, green: 0.91, blue: 0.93, alpha: 1)
        view.font = Self.terminalFont
        view.textContainerInset = NSSize(width: 10, height: 9)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = view
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let view = scrollView.documentView as? HerdrTerminalTextView else { return }
        view.paneID = paneID
        view.sendText = sendText
        view.sendPaste = sendPaste
        view.sendKey = sendKey
        view.selectPane = selectPane
        view.surface = surface
        if let surface {
            guard view.surfaceRevision != surface.revision || view.surfaceBootID != surface.bootID else { return }
            view.surfaceRevision = surface.revision
            view.surfaceBootID = surface.bootID
            view.textStorage?.setAttributedString(Self.render(surface))
            return
        }
        view.surfaceRevision = nil
        guard view.string != text else { return }
        let visible = scrollView.contentView.bounds
        let wasAtBottom = visible.maxY >= view.bounds.maxY - 20
        view.string = text
        if wasAtBottom {
            view.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    private static func render(_ surface: HerdrSurface) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let font = terminalFont
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for y in 0..<surface.height {
            for x in 0..<surface.width {
                let cell = surface.cells[y * surface.width + x]
                if cell.skip { continue }
                let isCursor = surface.cursor?.visible == true && surface.cursor?.x == x && surface.cursor?.y == y
                let foreground = color(cell.foreground, default: NSColor(red: 0.88, green: 0.91, blue: 0.93, alpha: 1))
                let background = color(cell.background, default: NSColor(red: 0.075, green: 0.082, blue: 0.091, alpha: 1))
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: cell.modifier & 1 != 0 ? boldFont : font,
                    .foregroundColor: isCursor ? background : foreground,
                    .backgroundColor: isCursor ? foreground : background
                ]
                if cell.modifier & 8 != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                output.append(NSAttributedString(string: cell.symbol.isEmpty ? " " : cell.symbol, attributes: attributes))
            }
            if y + 1 < surface.height { output.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        return output
    }

    private static func color(_ value: UInt32, default fallback: NSColor) -> NSColor {
        let kind = value >> 24
        if kind == 2 {
            return NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let palette: [UInt32] = [
            0x000000, 0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8,
            0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666, 0xf14c4c, 0x23d18b,
            0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff
        ]
        if kind == 0 {
            let index = Int(value & 255)
            if index == 0 { return fallback }
            if index < palette.count { return rgb(palette[index]) }
        }
        if kind == 1 {
            let index = Int(value & 255)
            if index < 16 { return rgb(palette[index + 1]) }
            if index < 232 {
                let n = index - 16
                let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
                return rgb((levels[n / 36] << 16) | (levels[(n / 6) % 6] << 8) | levels[n % 6])
            }
            let gray = UInt32(8 + (index - 232) * 10)
            return rgb((gray << 16) | (gray << 8) | gray)
        }
        return fallback
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

private final class HerdrTerminalTextView: NSTextView {
    var surfaceRevision: UInt64?
    var surfaceBootID: String?
    var surface: HerdrSurface?
    var selectPane: ((String) -> Void)?
    var paneID = ""
    var sendText: ((String, String) -> Void)?
    var sendPaste: ((String, String) -> Void)?
    var sendKey: ((String, String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let surface {
            let point = convert(event.locationInWindow, from: nil)
            let x = Int((point.x - textContainerInset.width) / TerminalPaneView.cellWidth)
            let y = Int((point.y - textContainerInset.height) / TerminalPaneView.cellHeight)
            if let id = surface.paneIDs.first(where: { id in
                guard let rect = surface.paneRects[id] else { return false }
                return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
            }) {
                selectPane?(id)
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            super.keyDown(with: event) // Copy, select all, and other Mac commands.
            return
        }

        let special: [UInt16: String] = [
            36: "enter", 76: "enter", 48: "tab", 53: "esc", 51: "backspace",
            117: "delete", 123: "left", 124: "right", 125: "down", 126: "up",
            115: "home", 119: "end", 116: "pageup", 121: "pagedown"
        ]
        if let key = special[event.keyCode] {
            let prefix = modifiers.contains(.shift) && key == "tab" ? "shift+" : ""
            sendKey?(prefix + key, paneID)
            return
        }
        if modifiers.contains(.control),
           let character = event.charactersIgnoringModifiers?.lowercased(),
           character.count == 1 {
            sendKey?("ctrl+\(character)", paneID)
            return
        }
        if modifiers.contains(.option),
           let character = event.charactersIgnoringModifiers?.lowercased(),
           character.count == 1 {
            sendKey?("alt+\(character)", paneID)
            return
        }
        interpretKeyEvents([event])
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let value = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        if !value.isEmpty { sendText?(value, paneID) }
    }

    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string), !value.isEmpty {
            sendPaste?(value, paneID)
        }
    }
}
