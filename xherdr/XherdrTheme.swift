import AppKit
import SwiftUI
import CodeEditSourceEditor

/// One theme shared by xherdr's chrome, the editor, and the terminals. The id is a Herdr
/// built-in theme name, so selecting a theme writes `[theme] name` in Herdr's config.toml.
/// Chrome colors come from Herdr's palette (herdr src/app/state.rs, v0.9.1); terminal colors,
/// which Herdr leaves to the host terminal, come from each theme's published terminal palette
/// (iTerm2-Color-Schemes, Ghostty format).
struct XherdrTheme: Identifiable, Equatable {
    struct HerdrPalette: Equatable {
        let accent, panel, activeRow, selection, surface0, surface1, surfaceDim: UInt32
        let overlay0, overlay1, text, subtext, mauve, green, yellow, red, blue, teal, peach: UInt32
    }

    let id: String
    let name: String
    let isDark: Bool
    let herdr: HerdrPalette
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let selectionBackground: UInt32
    /// ANSI colors 0–15.
    let ansi: [UInt32]

    static let fallbackID = "catppuccin"

    static let all: [XherdrTheme] = [
        XherdrTheme(id: "catppuccin", name: "Catppuccin Mocha", isDark: true,
                    herdr: .init(accent: 0x89B4FA, panel: 0x181825, activeRow: 0x1E1E2E, selection: 0x313244, surface0: 0x313244, surface1: 0x45475A, surfaceDim: 0x1E1E2E, overlay0: 0x6C7086, overlay1: 0x7F849C, text: 0xCDD6F4, subtext: 0xA6ADC8, mauve: 0xCBA6F7, green: 0xA6E3A1, yellow: 0xF9E2AF, red: 0xF38BA8, blue: 0x89B4FA, teal: 0x94E2D5, peach: 0xFAB387),
                    background: 0x1E1E2E, foreground: 0xCDD6F4,
                    cursor: 0xF5E0DC, selectionBackground: 0xF5E0DC,
                    ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE, 0x585B70, 0xF7AEC2, 0xC2ECBF, 0xFCD682, 0xAECCFC, 0xF398DA, 0xB1EAE1, 0xA6ADC8]),
        XherdrTheme(id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
                    herdr: .init(accent: 0x1E66F5, panel: 0xEFF1F5, activeRow: 0xE6E9EF, selection: 0xBDD0F5, surface0: 0xCCD0DA, surface1: 0xBCC0CC, surfaceDim: 0xE6E9EF, overlay0: 0x9CA0B0, overlay1: 0x8C8FA1, text: 0x4C4F69, subtext: 0x6C6F85, mauve: 0x8839EF, green: 0x40A02B, yellow: 0xDF8E1D, red: 0xD20F39, blue: 0x1E66F5, teal: 0x179299, peach: 0xFE640B),
                    background: 0xEFF1F5, foreground: 0x4C4F69,
                    cursor: 0xDC8A78, selectionBackground: 0xDC8A78,
                    ansi: [0xBCC0CC, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0x5C5F77, 0xACB0BE, 0xE7103F, 0x46B02F, 0xE49931, 0x3878F6, 0xEF95D7, 0x19A1A8, 0x6C6F85]),
        XherdrTheme(id: "terminal", name: "Terminal", isDark: true,
                    herdr: .init(accent: 0x2472C8, panel: 0x1B1D20, activeRow: 0x666666, selection: 0x2B3036, surface0: 0x2B3036, surface1: 0x666666, surfaceDim: 0x666666, overlay0: 0xE5E5E5, overlay1: 0xE5E5E5, text: 0xE0E8ED, subtext: 0xE5E5E5, mauve: 0xE5E5E5, green: 0x0DBC79, yellow: 0xE5E510, red: 0xF14C4C, blue: 0x2472C8, teal: 0x11A8CD, peach: 0xE5E510),
                    background: 0x131517, foreground: 0xE0E8ED,
                    cursor: 0xE0E8ED, selectionBackground: 0x264F78,
                    ansi: [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5, 0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF]),
        XherdrTheme(id: "tokyo-night", name: "Tokyo Night", isDark: true,
                    herdr: .init(accent: 0x7AA2F7, panel: 0x1A1B26, activeRow: 0x232636, selection: 0x2D3650, surface0: 0x24283B, surface1: 0x414868, surfaceDim: 0x1A1B26, overlay0: 0x565F89, overlay1: 0x697196, text: 0xC0CAF5, subtext: 0xA9B1D6, mauve: 0xBB9AF7, green: 0x9ECE6A, yellow: 0xE0AF68, red: 0xF7768E, blue: 0x7AA2F7, teal: 0x7DCFFF, peach: 0xFF9E64),
                    background: 0x1A1B26, foreground: 0xC0CAF5,
                    cursor: 0xC0CAF5, selectionBackground: 0x283457,
                    ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6, 0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5]),
        XherdrTheme(id: "tokyo-night-day", name: "Tokyo Night Day", isDark: false,
                    herdr: .init(accent: 0x2E7DE9, panel: 0xE1E2E7, activeRow: 0xD2D3DA, selection: 0xB6CAE7, surface0: 0xC4C8DA, surface1: 0xA8AECB, surfaceDim: 0xD2D3DA, overlay0: 0x8990B3, overlay1: 0x68709A, text: 0x3760BF, subtext: 0x6172B0, mauve: 0x7847BD, green: 0x587539, yellow: 0x8C6C3E, red: 0xF52A65, blue: 0x2E7DE9, teal: 0x118C74, peach: 0xB15C00),
                    background: 0xE1E2E7, foreground: 0x3760BF,
                    cursor: 0x3760BF, selectionBackground: 0x99A7DF,
                    ansi: [0xE9E9ED, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0, 0xA1A6C5, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x3760BF]),
        XherdrTheme(id: "dracula", name: "Dracula", isDark: true,
                    herdr: .init(accent: 0xBD93F9, panel: 0x282A36, activeRow: 0x373C52, selection: 0x463F5D, surface0: 0x44475A, surface1: 0x6272A4, surfaceDim: 0x282A36, overlay0: 0x6272A4, overlay1: 0x828CB4, text: 0xF8F8F2, subtext: 0xD2D2DC, mauve: 0xFF79C6, green: 0x50FA7B, yellow: 0xF1FA8C, red: 0xFF5555, blue: 0x8BE9FD, teal: 0x8BE9FD, peach: 0xFFB86C),
                    background: 0x282A36, foreground: 0xF8F8F2,
                    cursor: 0xF8F8F2, selectionBackground: 0x44475A,
                    ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2, 0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]),
        XherdrTheme(id: "nord", name: "Nord", isDark: true,
                    herdr: .init(accent: 0x88C0D0, panel: 0x2E3440, activeRow: 0x434C5E, selection: 0x40505D, surface0: 0x3B4252, surface1: 0x434C5E, surfaceDim: 0x2E3440, overlay0: 0x4C566A, overlay1: 0x646E82, text: 0xECEFF4, subtext: 0xD8DEE9, mauve: 0xB48EAD, green: 0xA3BE8C, yellow: 0xEBCB8B, red: 0xBF616A, blue: 0x81A1C1, teal: 0x8FBCBB, peach: 0xD08770),
                    background: 0x2E3440, foreground: 0xD8DEE9,
                    cursor: 0xECEFF4, selectionBackground: 0xECEFF4,
                    ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0, 0x596377, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]),
        XherdrTheme(id: "gruvbox", name: "Gruvbox Dark", isDark: true,
                    herdr: .init(accent: 0xD79921, panel: 0x282828, activeRow: 0x323130, selection: 0x4B3F27, surface0: 0x3C3836, surface1: 0x504945, surfaceDim: 0x282828, overlay0: 0x928374, overlay1: 0xA89984, text: 0xEBDBB2, subtext: 0xD5C4A1, mauve: 0xD3869B, green: 0xB8BB26, yellow: 0xFABD2F, red: 0xFB4934, blue: 0x83A598, teal: 0x8EC07C, peach: 0xFE8019),
                    background: 0x282828, foreground: 0xEBDBB2,
                    cursor: 0xEBDBB2, selectionBackground: 0x665C54,
                    ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984, 0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]),
        XherdrTheme(id: "gruvbox-light", name: "Gruvbox Light", isDark: false,
                    herdr: .init(accent: 0x076678, panel: 0xFBF1C7, activeRow: 0xF2E5BC, selection: 0xEBDBB2, surface0: 0xEBDBB2, surface1: 0xD5C4A1, surfaceDim: 0xF2E5BC, overlay0: 0x928374, overlay1: 0x7C6F64, text: 0x3C3836, subtext: 0x504945, mauve: 0x8F3F71, green: 0x79740E, yellow: 0xB57614, red: 0x9D0006, blue: 0x076678, teal: 0x427B58, peach: 0xAF3A03),
                    background: 0xFBF1C7, foreground: 0x3C3836,
                    cursor: 0x3C3836, selectionBackground: 0x3C3836,
                    ansi: [0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64, 0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836]),
        XherdrTheme(id: "one-dark", name: "One Dark", isDark: true,
                    herdr: .init(accent: 0x61AFEF, panel: 0x282C34, activeRow: 0x313640, selection: 0x334659, surface0: 0x2C313A, surface1: 0x3E4451, surfaceDim: 0x282C34, overlay0: 0x5C6370, overlay1: 0x737A87, text: 0xABB2BF, subtext: 0x969CA8, mauve: 0xC678DD, green: 0x98C379, yellow: 0xE5C07B, red: 0xE06C75, blue: 0x61AFEF, teal: 0x56B6C2, peach: 0xD19A66),
                    background: 0x21252B, foreground: 0xABB2BF,
                    cursor: 0xABB2BF, selectionBackground: 0x323844,
                    ansi: [0x21252B, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF, 0x767676, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF]),
        XherdrTheme(id: "one-light", name: "One Light", isDark: false,
                    herdr: .init(accent: 0x4078F2, panel: 0xFAFAFA, activeRow: 0xD8DBE2, selection: 0xCDDBF8, surface0: 0xF0F0F1, surface1: 0xE5E5E6, surfaceDim: 0xF5F5F6, overlay0: 0xA0A1A7, overlay1: 0x686B77, text: 0x383A42, subtext: 0x686B77, mauve: 0xA626A4, green: 0x50A14F, yellow: 0xC18401, red: 0xE45649, blue: 0x4078F2, teal: 0x0184BC, peach: 0x986801),
                    background: 0xF9F9F9, foreground: 0x2A2C33,
                    cursor: 0xBBBBBB, selectionBackground: 0xEDEDED,
                    ansi: [0x000000, 0xDE3E35, 0x3F953A, 0xD2B67C, 0x2F5AF3, 0x950095, 0x3F953A, 0xBBBBBB, 0x000000, 0xDE3E35, 0x3F953A, 0xD2B67C, 0x2F5AF3, 0xA00095, 0x3F953A, 0xFFFFFF]),
        XherdrTheme(id: "solarized", name: "Solarized Dark", isDark: true,
                    herdr: .init(accent: 0x268BD2, panel: 0x002B36, activeRow: 0x164B57, selection: 0x083E55, surface0: 0x073642, surface1: 0x586E75, surfaceDim: 0x002B36, overlay0: 0x586E75, overlay1: 0x657B83, text: 0x93A1A1, subtext: 0x839496, mauve: 0xD33682, green: 0x859900, yellow: 0xB58900, red: 0xDC322F, blue: 0x268BD2, teal: 0x2AA198, peach: 0xCB4B16),
                    background: 0x002B36, foreground: 0x839496,
                    cursor: 0x839496, selectionBackground: 0x073642,
                    ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5, 0x335E69, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]),
        XherdrTheme(id: "solarized-light", name: "Solarized Light", isDark: false,
                    herdr: .init(accent: 0x268BD2, panel: 0xFDF6E3, activeRow: 0xEEE8D5, selection: 0xC9DCDF, surface0: 0xEEE8D5, surface1: 0x93A1A1, surfaceDim: 0xEEE8D5, overlay0: 0x93A1A1, overlay1: 0x586E75, text: 0x657B83, subtext: 0x839496, mauve: 0xD33682, green: 0x859900, yellow: 0xB58900, red: 0xDC322F, blue: 0x268BD2, teal: 0x2AA198, peach: 0xCB4B16),
                    background: 0xFDF6E3, foreground: 0x657B83,
                    cursor: 0x657B83, selectionBackground: 0xEEE8D5,
                    ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xBBB5A2, 0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]),
        XherdrTheme(id: "kanagawa", name: "Kanagawa", isDark: true,
                    herdr: .init(accent: 0x7E9CD8, panel: 0x1F1F28, activeRow: 0x363646, selection: 0x32384B, surface0: 0x2A2A37, surface1: 0x363646, surfaceDim: 0x1F1F28, overlay0: 0x727169, overlay1: 0x87867D, text: 0xDCD7BA, subtext: 0xC8C3AA, mauve: 0x957FB8, green: 0x76946A, yellow: 0xC0A36E, red: 0xC34043, blue: 0x7E9CD8, teal: 0x7FB4CA, peach: 0xFFA066),
                    background: 0x1F1F28, foreground: 0xDCD7BA,
                    cursor: 0xDCD7BA, selectionBackground: 0xDCD7BA,
                    ansi: [0x090618, 0xC34043, 0x76946A, 0xC0A36E, 0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093, 0x727169, 0xE82424, 0x98BB6C, 0xE6C384, 0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA]),
        XherdrTheme(id: "kanagawa-lotus", name: "Kanagawa Lotus", isDark: false,
                    herdr: .init(accent: 0x4D699B, panel: 0xF2ECBC, activeRow: 0xD5CEA3, selection: 0xDCD5AC, surface0: 0xDCD5AC, surface1: 0xC9CBD1, surfaceDim: 0xD5CEA3, overlay0: 0xA09CAC, overlay1: 0x8A8980, text: 0x545464, subtext: 0x43436C, mauve: 0x624C83, green: 0x6F894E, yellow: 0x77713F, red: 0xC84053, blue: 0x4D699B, teal: 0x4E8CA2, peach: 0xCC6D00),
                    background: 0xF2ECBC, foreground: 0x545464,
                    cursor: 0x43436C, selectionBackground: 0x545464,
                    ansi: [0x1F1F28, 0xC84053, 0x6F894E, 0x77713F, 0x4D699B, 0xB35B79, 0x597B75, 0x545464, 0x8A8980, 0xD7474B, 0x6E915F, 0x836F4A, 0x6693BF, 0x624C83, 0x5E857A, 0x43436C]),
        XherdrTheme(id: "rose-pine", name: "Rosé Pine", isDark: true,
                    herdr: .init(accent: 0xC4A7E7, panel: 0x191724, activeRow: 0x26233A, selection: 0x3B344B, surface0: 0x1F1D2E, surface1: 0x26233A, surfaceDim: 0x26233A, overlay0: 0x6E6A86, overlay1: 0x908CAA, text: 0xE0DEF4, subtext: 0xC8C5DC, mauve: 0xC4A7E7, green: 0x31748F, yellow: 0xF6C177, red: 0xEB6F92, blue: 0x31748F, teal: 0x9CCFD8, peach: 0xEA9A97),
                    background: 0x191724, foreground: 0xE0DEF4,
                    cursor: 0xE0DEF4, selectionBackground: 0x403D52,
                    ansi: [0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4, 0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4]),
        XherdrTheme(id: "rose-pine-dawn", name: "Rosé Pine Dawn", isDark: false,
                    herdr: .init(accent: 0x907AA9, panel: 0xFAF4ED, activeRow: 0xE3D9CF, selection: 0xF2E9E1, surface0: 0xF2E9E1, surface1: 0xFFFAF3, surfaceDim: 0xF2E9E1, overlay0: 0x9893A5, overlay1: 0x797593, text: 0x464261, subtext: 0x797593, mauve: 0x907AA9, green: 0x286983, yellow: 0xEA9D34, red: 0xB4637A, blue: 0x286983, teal: 0x56949F, peach: 0xD7827E),
                    background: 0xFAF4ED, foreground: 0x575279,
                    cursor: 0x575279, selectionBackground: 0xDFDAD9,
                    ansi: [0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279, 0x9893A5, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279]),
        XherdrTheme(id: "vesper", name: "Vesper", isDark: true,
                    herdr: .init(accent: 0xFFC799, panel: 0x1A1A1A, activeRow: 0x101010, selection: 0x232323, surface0: 0x232323, surface1: 0x282828, surfaceDim: 0x101010, overlay0: 0x5C5C5C, overlay1: 0x7E7E7E, text: 0xFFFFFF, subtext: 0xA0A0A0, mauve: 0xFFD1A8, green: 0x99FFE4, yellow: 0xFFC799, red: 0xFF8080, blue: 0xB0B0B0, teal: 0x66DDCC, peach: 0xFFC799),
                    background: 0x101010, foreground: 0xFFFFFF,
                    cursor: 0xACB1AB, selectionBackground: 0x988049,
                    ansi: [0x101010, 0xF5A191, 0x90B99F, 0xE6B99D, 0xACA1CF, 0xE29ECA, 0xEA83A5, 0xA0A0A0, 0x7E7E7E, 0xFF8080, 0x99FFE4, 0xFFC799, 0xB9AEDA, 0xECAAD6, 0xF591B2, 0xFFFFFF])
    ]

    static func named(_ name: String) -> XherdrTheme? {
        let id = canonicalName(name)
        return all.first { $0.id == id }
    }

    /// Herdr's accepted aliases (herdr src/config/theme.rs).
    static func canonicalName(_ name: String) -> String {
        let aliases = ["catppuccin-mocha": "catppuccin", "latte": "catppuccin-latte", "light": "catppuccin-latte",
                       "tokyonight": "tokyo-night", "tokyo-day": "tokyo-night-day", "tokyonight-day": "tokyo-night-day",
                       "gruvbox-dark": "gruvbox", "onedark": "one-dark", "onelight": "one-light",
                       "solarized-dark": "solarized", "lotus": "kanagawa-lotus", "rosepine": "rose-pine",
                       "rosepine-dawn": "rose-pine-dawn", "dawn": "rose-pine-dawn"]
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        return aliases[lowered] ?? lowered
    }

    /// The other half of a light/dark pair, used when auto switching without explicit names.
    var sibling: XherdrTheme? {
        let pairs = ["catppuccin": "catppuccin-latte", "tokyo-night": "tokyo-night-day", "gruvbox": "gruvbox-light",
                     "one-dark": "one-light", "solarized": "solarized-light", "kanagawa": "kanagawa-lotus",
                     "rose-pine": "rose-pine-dawn"]
        let other = pairs[id] ?? pairs.first { $0.value == id }?.key
        return other.flatMap(Self.named)
    }
}

// MARK: - Colors

extension XherdrTheme {
    static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: opacity)
    }

    static func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    // Chrome
    var contentBackground: Color { Self.color(background) }
    var sidebarBackground: Color { Self.color(herdr.panel) }
    var barBackground: Color { Self.color(herdr.panel) }
    var rowSelected: Color { Self.color(herdr.surface0, opacity: 0.85) }
    var rowHover: Color { Self.color(herdr.surface1, opacity: 0.35) }
    var fieldBackground: Color { Self.color(herdr.surface0, opacity: 0.6) }
    var accent: Color { Self.color(herdr.accent) }
    var text: Color { Self.color(herdr.text) }
    var subtext: Color { Self.color(herdr.subtext) }
    var muted: Color { Self.color(herdr.overlay0) }
    var warning: Color { Self.color(herdr.peach) }
    var error: Color { Self.color(herdr.red) }
    var success: Color { Self.color(herdr.green) }
    var matchHighlight: Color { Self.color(herdr.yellow, opacity: 0.3) }
    var activeMatchHighlight: Color { Self.color(herdr.peach, opacity: 0.8) }

    /// Herdr agent states: working, blocked, done (finished, not yet seen), idle (seen).
    /// Colors follow Herdr's `status_color` (herdr src/client/shell.rs, v0.9.3).
    func agentStatus(_ status: String?) -> Color {
        switch status {
        case "working": return Self.color(herdr.yellow)
        case "blocked": return Self.color(herdr.red)
        case "done": return Self.color(herdr.teal)
        case "idle": return Self.color(herdr.green)
        default: return muted
        }
    }

    /// How Herdr's default `dots` indicators draw a state (`status_icon`, same file): a dot,
    /// a ring once a finished agent has been seen (`idle`), or a faint dot when unknown.
    enum AgentStatusMark: Equatable { case dot, ring, faint }

    static func agentStatusMark(_ status: String?) -> AgentStatusMark {
        switch status {
        case "working", "blocked", "done": return .dot
        case "idle": return .ring
        default: return .faint
        }
    }

    func vcs(_ kind: WorkspaceFileChange.Kind) -> Color {
        switch kind {
        case .modified: return Self.color(herdr.yellow)
        // New files are green whether staged or not, as in VS Code and Zed; gray is for ignored ones.
        case .untracked, .added: return Self.color(herdr.green)
        case .deleted: return Self.color(herdr.red)
        case .renamed: return Self.color(herdr.blue)
        case .conflicted: return Self.color(herdr.red)
        }
    }

    var diffAdded: Color { Self.color(herdr.green) }
    var diffRemoved: Color { Self.color(herdr.red) }
    var diffHunk: Color { Self.color(herdr.blue) }

    // Terminal
    var terminalBackground: NSColor { Self.nsColor(background) }
    var terminalForeground: NSColor { Self.nsColor(foreground) }

    // Editor
    var editorTheme: EditorTheme {
        EditorTheme(
            text: Self.nsColor(foreground),
            insertionPoint: Self.nsColor(cursor),
            invisibles: Self.nsColor(herdr.overlay0),
            background: Self.nsColor(background),
            lineHighlight: Self.nsColor(herdr.surfaceDim == background ? herdr.surface0 : herdr.surfaceDim, alpha: 0.6),
            selection: Self.nsColor(selectionBackground),
            keywords: Self.nsColor(herdr.mauve),
            commands: Self.nsColor(herdr.teal),
            types: Self.nsColor(herdr.yellow),
            attributes: Self.nsColor(herdr.peach),
            variables: Self.nsColor(foreground),
            values: Self.nsColor(herdr.peach),
            numbers: Self.nsColor(herdr.peach),
            strings: Self.nsColor(herdr.green),
            characters: Self.nsColor(herdr.peach),
            comments: Self.nsColor(herdr.overlay0)
        )
    }
}

// MARK: - Store

/// Resolves the active theme from Herdr's config.toml, following `auto_switch` with the
/// macOS appearance the way Herdr follows its host terminal.
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var theme = XherdrTheme.named(XherdrTheme.fallbackID)!
    private var name = XherdrTheme.fallbackID
    private var autoSwitch = false
    private var lightName = ""
    private var darkName = ""
    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resolve() }
        }
    }

    func reload() {
        let text = (try? HerdrConfigFile.read(at: HerdrConfigFile.url)) ?? ""
        let document = HerdrConfigDocument(text: text)
        name = document.string(section: "theme", key: "name", default: XherdrTheme.fallbackID)
        autoSwitch = document.bool(section: "theme", key: "auto_switch", default: false)
        lightName = document.string(section: "theme", key: "light_name", default: "")
        darkName = document.string(section: "theme", key: "dark_name", default: "")
        resolve()
    }

    private func resolve() {
        let base = XherdrTheme.named(name) ?? XherdrTheme.named(XherdrTheme.fallbackID)!
        var next = base
        if autoSwitch {
            let systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            let explicit = systemDark ? darkName : lightName
            if let chosen = XherdrTheme.named(explicit) {
                next = chosen
            } else if base.isDark != systemDark, let sibling = base.sibling {
                next = sibling
            }
        }
        if next != theme { theme = next }
    }
}

private struct XherdrThemeKey: EnvironmentKey {
    static let defaultValue = XherdrTheme.named(XherdrTheme.fallbackID)!
}

extension EnvironmentValues {
    var xherdrTheme: XherdrTheme {
        get { self[XherdrThemeKey.self] }
        set { self[XherdrThemeKey.self] = newValue }
    }
}
