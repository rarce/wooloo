import XCTest
@testable import wooloo

/// `HerdrConfigDocument` edits the user's own config.toml, so every edit must leave unrelated
/// tables, keys and comments as they were.
final class HerdrConfigDocumentTests: XCTestCase {
    func testReadsScalarsAndIgnoresComments() {
        let document = HerdrConfigDocument(text: """
        [ui] # appearance
        sound = true # on
        size = 14
        name = "a # b \\"q\\""

        [other]
        size = 99
        """)
        XCTAssertTrue(document.bool(section: "ui", key: "sound", default: false))
        XCTAssertEqual(document.integer(section: "ui", key: "size", default: 0), 14)
        XCTAssertEqual(document.string(section: "ui", key: "name", default: ""), "a # b \"q\"")
        XCTAssertEqual(document.integer(section: "other", key: "size", default: 0), 99)
        XCTAssertEqual(document.integer(section: "ui", key: "missing", default: 7), 7)
        XCTAssertEqual(document.string(section: "missing", key: "name", default: "fallback"), "fallback")
    }

    func testSettingAnExistingKeyKeepsItsCommentAndTheRestOfTheFile() {
        var document = HerdrConfigDocument(text: """
        # top comment
        [ui]
        theme = "old" # keep me
        other = 1

        [keys]
        prefix = "ctrl+b"

        """)
        document.setString("new", section: "ui", key: "theme")
        XCTAssertEqual(document.text, """
        # top comment
        [ui]
        theme = "new" # keep me
        other = 1

        [keys]
        prefix = "ctrl+b"

        """)
    }

    func testSettingAKeyInAMissingSectionAppendsTheSection() {
        var document = HerdrConfigDocument(text: "[keys]\nprefix = \"ctrl+b\"\n")
        document.setInteger(3, section: "ui", key: "size")
        XCTAssertEqual(document.text, "[keys]\nprefix = \"ctrl+b\"\n\n[ui]\nsize = 3\n")

        var empty = HerdrConfigDocument(text: "")
        empty.setBool(true, section: "ui", key: "sound")
        XCTAssertEqual(empty.text, "[ui]\nsound = true\n")
    }

    /// A parent table must come before its child tables, or TOML reads the key into the child.
    func testMissingParentSectionIsInsertedBeforeItsChildTable() {
        var document = HerdrConfigDocument(text: "[ui.sound]\nenabled = false\n")
        document.setBool(true, section: "ui", key: "compact")
        XCTAssertEqual(document.text, "[ui]\ncompact = true\n\n[ui.sound]\nenabled = false\n")
        XCTAssertFalse(document.bool(section: "ui.sound", key: "enabled", default: true))
    }

    /// TOML has no `\/` escape; writing one makes Herdr reject the whole file.
    func testStringsWithSlashesStayValidToml() {
        var document = HerdrConfigDocument(text: "")
        document.setString("/bin/zsh", section: "terminal", key: "shell")
        document.setBindings(["prefix+/"], key: "help")
        document.setBindings(["prefix+/", "cmd+/"], key: "settings")
        XCTAssertFalse(document.text.contains("\\/"), document.text)
        XCTAssertEqual(document.string(section: "terminal", key: "shell", default: ""), "/bin/zsh")
        XCTAssertEqual(document.bindings("help", default: []), ["prefix+/"])
        XCTAssertEqual(document.bindings("settings", default: []), ["prefix+/", "cmd+/"])
    }

    func testStringsWithQuotesAndBackslashesRoundTrip() {
        var document = HerdrConfigDocument(text: "")
        let value = "say \"hi\" \\ tab\there ñ"
        document.setString(value, section: "ui", key: "greeting")
        XCTAssertEqual(document.string(section: "ui", key: "greeting", default: ""), value)
    }

    func testBindingsReadEveryTomlForm() {
        let document = HerdrConfigDocument(text: """
        [keys]
        new_tab = [
          "prefix+c", # comment with "quotes" and ]
          'ctrl+t',
        ]
        zoom = 'prefix+z'
        split_vertical = "prefix+v" # comment
        """)
        XCTAssertEqual(document.bindings("new_tab", default: []), ["prefix+c", "ctrl+t"])
        XCTAssertEqual(document.bindings("zoom", default: []), ["prefix+z"])
        XCTAssertEqual(document.bindings("split_vertical", default: []), ["prefix+v"])
        XCTAssertEqual(document.bindings("missing", default: ["prefix+m"]), ["prefix+m"])
    }

    func testReplacingAMultilineArrayRemovesItsOldLines() {
        var document = HerdrConfigDocument(text: """
        [keys]
        new_tab = [
          "prefix+c",
          "ctrl+t",
        ]
        zoom = "prefix+z"
        """)
        document.setBindings(["cmd+t", "prefix+c"], key: "new_tab")
        XCTAssertEqual(document.text, "[keys]\nnew_tab = [\"cmd+t\",\"prefix+c\"]\nzoom = \"prefix+z\"\n")

        document.setBindings(["cmd+t"], key: "new_tab")
        XCTAssertEqual(document.bindings("new_tab", default: []), ["cmd+t"])
        XCTAssertTrue(document.text.contains("new_tab = \"cmd+t\""))
    }

    func testRemovingAKeyRemovesItsWholeArray() {
        var document = HerdrConfigDocument(text: """
        [keys]
        new_tab = [
          "prefix+c",
        ]
        zoom = "prefix+z"
        """)
        document.remove(section: "keys", key: "new_tab")
        XCTAssertEqual(document.text, "[keys]\nzoom = \"prefix+z\"")
        document.remove(section: "keys", key: "missing")
        XCTAssertEqual(document.text, "[keys]\nzoom = \"prefix+z\"")
    }
}
