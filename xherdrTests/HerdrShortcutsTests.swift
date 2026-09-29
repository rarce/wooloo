import AppKit
import XCTest
@testable import xherdr

/// Herdr's `[keys]` bindings applied to key events in the terminal.
final class HerdrShortcutsTests: XCTestCase {
    private let defaults = HerdrShortcutMap(document: HerdrConfigDocument(text: ""))

    private func key(_ characters: String, ignoringModifiers: String? = nil, code: UInt16 = 0,
                     _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoringModifiers ?? characters,
                         isARepeat: false, keyCode: code)!
    }

    private func action(_ match: HerdrShortcutMap.Match) -> String? {
        if case .action(let name) = match { return name }
        return nil
    }

    func testDefaultPrefixThenKeyRunsTheAction() {
        guard case .prefix = defaults.match(key("\u{2}", ignoringModifiers: "b", code: 11, .control), prefixPending: false) else {
            return XCTFail("ctrl+b should start the prefix")
        }
        XCTAssertEqual(action(defaults.match(key("c"), prefixPending: true)), "new_tab")
        XCTAssertEqual(action(defaults.match(key("-"), prefixPending: true)), "split_horizontal")
        XCTAssertEqual(action(defaults.match(key("N", ignoringModifiers: "N", .shift), prefixPending: true)), "new_workspace")
    }

    func testTabNumbersSwitchTabs() {
        XCTAssertEqual(action(defaults.match(key("3"), prefixPending: true)), "switch_tab_3")
        XCTAssertEqual(action(defaults.match(key("9"), prefixPending: true)), "switch_tab_9")
    }

    /// Shift+/ arrives as "?" with "/" ignoring modifiers; the "?" binding must match.
    func testShiftedPunctuationMatchesItsSymbol() {
        XCTAssertEqual(action(defaults.match(key("?", ignoringModifiers: "/", .shift), prefixPending: true)), "help")
    }

    func testPendingPrefixConsumesEscapeAndUnboundKeys() {
        guard case .consumed = defaults.match(key("\u{1b}", code: 53), prefixPending: true) else {
            return XCTFail("Escape should cancel the prefix")
        }
        guard case .consumed = defaults.match(key("q"), prefixPending: true) else {
            return XCTFail("An unbound key should cancel the prefix")
        }
    }

    func testKeysWithoutPrefixPassToTheTerminal() {
        guard case .pass = defaults.match(key("c"), prefixPending: false) else {
            return XCTFail("Plain keys belong to the pane")
        }
    }

    func testConfiguredPrefixAndDirectBindings() {
        let map = HerdrShortcutMap(document: HerdrConfigDocument(text: """
        [keys]
        prefix = "ctrl+a"
        zoom = ["cmd+shift+z", "prefix+z"]
        new_tab = "prefix+N"
        """))
        guard case .prefix = map.match(key("\u{1}", ignoringModifiers: "a", code: 0, .control), prefixPending: false) else {
            return XCTFail("ctrl+a should be the prefix")
        }
        guard case .pass = map.match(key("\u{2}", ignoringModifiers: "b", code: 11, .control), prefixPending: false) else {
            return XCTFail("ctrl+b is no longer the prefix")
        }
        XCTAssertEqual(action(map.match(key("z", ignoringModifiers: "Z", [.command, .shift]), prefixPending: false)), "zoom")
        XCTAssertEqual(action(map.match(key("z"), prefixPending: true)), "zoom")
        // An uppercase letter means Shift.
        XCTAssertEqual(action(map.match(key("N", ignoringModifiers: "N", .shift), prefixPending: true)), "new_tab")
        XCTAssertNil(action(map.match(key("c"), prefixPending: true)))
    }

    func testInvalidPrefixFallsBackToCtrlB() {
        let map = HerdrShortcutMap(document: HerdrConfigDocument(text: "[keys]\nprefix = \"hyper+x\"\n"))
        guard case .prefix = map.match(key("\u{2}", ignoringModifiers: "b", code: 11, .control), prefixPending: false) else {
            return XCTFail("An unreadable prefix should fall back to ctrl+b")
        }
    }

    func testDisplayLabelsUseMacSymbols() {
        XCTAssertEqual(defaults.displayLabel(for: "split_horizontal"), "⌃B -")
        XCTAssertEqual(defaults.displayLabel(for: "new_workspace"), "⌃B ⇧N")
        let map = HerdrShortcutMap(document: HerdrConfigDocument(text: "[keys]\nzoom = \"cmd+option+enter\"\n"))
        XCTAssertEqual(map.displayLabel(for: "zoom"), "⌥⌘↩")
        XCTAssertNil(map.displayLabel(for: "unknown"))
    }
}
