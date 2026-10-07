import AppKit
import SwiftUI

/// wooloo's text scale. Every UI size derives from one base size so the hierarchy stays
/// consistent; code (editor, diffs, commit messages, search results) has its own size.
/// Stored in UserDefaults: it is an wooloo preference, not part of Herdr's config.toml.
struct WoolooTypography: Equatable {
    static let baseKey = "InterfaceTextSize"
    static let codeKey = "CodeTextSize"
    static let defaultBase = 13.0
    static let defaultCode = 12.0
    static let baseRange = 11.0...17.0
    static let codeRange = 10.0...20.0

    var base: CGFloat = defaultBase
    var code: CGFloat = defaultCode

    /// Badge glyphs and other marks that sit inside small shapes.
    var tiny: CGFloat { max(7, base - 4) }
    /// Section labels, metadata such as hashes, authors and dates, and hints.
    var caption: CGFloat { base - 2 }
    /// Supporting text next to a row's main label.
    var secondary: CGFloat { base - 1 }
    /// Rows, lists, tabs, and controls.
    var body: CGFloat { base }
    /// Emphasized labels and field titles.
    var emphasis: CGFloat { base + 1 }
    /// Group headings.
    var heading: CGFloat { base + 2 }
    /// Page titles.
    var title: CGFloat { base + 5 }

    var codeFont: NSFont { .monospacedSystemFont(ofSize: code, weight: .regular) }

    /// A row or bar height designed for 11 pt text, grown with the base size.
    func metric(_ value: CGFloat) -> CGFloat {
        (value + (base - 11) * 2).rounded()
    }
}

private struct WoolooTypographyKey: EnvironmentKey {
    static let defaultValue = WoolooTypography()
}

extension EnvironmentValues {
    var woolooTypography: WoolooTypography {
        get { self[WoolooTypographyKey.self] }
        set { self[WoolooTypographyKey.self] = newValue }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
