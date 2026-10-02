import SwiftUI
import MarkdownView
import BeautifulMermaid

enum MarkdownDisplayMode: String, CaseIterable, Identifiable {
    case source = "Source"
    case preview = "Preview"
    case split = "Split"

    var id: Self { self }
    var icon: String {
        switch self {
        case .source: "chevron.left.forwardslash.chevron.right"
        case .preview: "eye"
        case .split: "rectangle.split.2x1"
        }
    }

    static func supports(_ path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains((path as NSString).pathExtension.lowercased())
    }
}

/// How the Markdown preview looks: in the theme's colors, or as a white page in GitHub's
/// README style whatever the theme. An xherdr preference, stored in UserDefaults.
enum MarkdownPreviewStyle: String, CaseIterable, Identifiable {
    case theme = "Theme"
    case document = "Document"

    static let storageKey = "MarkdownPreviewStyle"

    var id: Self { self }
}

/// Renders a Markdown document from the Space with MarkdownView, drawing ```mermaid blocks
/// natively with BeautifulMermaid. Images and links resolve against the Space, locally or over SSH.
struct MarkdownPreviewView: View {
    @Environment(\.xherdrTypography) private var typography
    let text: String
    let path: String
    let location: WorkspaceFileLocation
    let onOpenFile: (String) -> Void
    var highlight: MarkdownSearchHighlight?
    var focus: MarkdownFindFocus?

    @Environment(\.xherdrTheme) private var theme
    @AppStorage(MarkdownPreviewStyle.storageKey) private var style = MarkdownPreviewStyle.theme
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                switch style {
                case .theme: themed
                case .document: page
                }
            }
            .onChange(of: focus) { _, focus in
                guard let focus else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(MarkdownBlockAnchor(index: focus.block), anchor: .center)
                }
            }
        }
    }

    private var themed: some View {
        ScrollView {
            markdown(theme: theme)
                // Block spacing plus heading padding approximates GitHub's 16pt block margins.
                .markdownBlockSpacing(14)
                .padding(.top, 12, for: .h1, .h2, .h3)
                .padding(.top, 6, for: .h4, .h5, .h6)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(theme.contentBackground)
    }

    /// A white page on a canvas in the theme's panel color, with GitHub's README typography:
    /// 16 pt text (at the default interface size), 1.5 line height, 16 pt block margins,
    /// headings at 2/1.5/1.25 em with rules under h1 and h2, and a ~70 character measure.
    private var page: some View {
        let paper = XherdrTheme.markdownDocument
        let body = typography.body + 3
        let compact = width > 0 && width < 600
        return ScrollView {
            markdown(theme: paper)
                .markdownFontGroup(MarkdownDocumentFonts(size: body))
                .markdownBlockSpacing(16)
                .padding(.top, 8, for: .h1, .h2, .h3, .h4, .h5, .h6)
                .markdownHeadingDivider(.init(levels: [1, 2], color: XherdrTheme.color(0xD1D9E0, opacity: 0.7),
                                              spacing: body * 0.3))
                .markdownBlockQuoteStyle(.github)
                .markdownTableStyle(.github)
                .tint(paper.text, for: .inlineCodeBlock)
                .lineSpacing(body * 0.3)
                .frame(maxWidth: body * 47.5, alignment: .leading)
                .padding(.horizontal, compact ? 24 : 48)
                .padding(.vertical, compact ? 28 : 52)
                .frame(maxWidth: .infinity, alignment: .center)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(paper.contentBackground)
                        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.08), radius: theme.isDark ? 16 : 12,
                                y: theme.isDark ? 6 : 4)
                        .shadow(color: .black.opacity(theme.isDark ? 0 : 0.06), radius: 2, y: 1)
                }
                .environment(\.colorScheme, .light)
                .frame(maxWidth: body * 47.5 + 96)
                .padding(compact ? 12 : 32)
                .frame(maxWidth: .infinity)
        }
        .background(theme.sidebarBackground.overlay(Color.black.opacity(theme.isDark ? 0 : 0.05)))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    private func markdown(theme: XherdrTheme) -> some View {
        MarkdownView(MarkdownSpaceLinks.rewritingImages(in: text, documentPath: path))
            .markdownCodeBlockStyle(XherdrCodeBlockStyle(theme: theme))
            .markdownElementRenderer(.image(SpaceImageRenderer(location: location),
                                            urlScheme: MarkdownSpaceLinks.scheme))
            .markdownSearchHighlight(highlight)
            .environment(\.openURL, OpenURLAction { open($0) })
            .environment(\.xherdrTheme, theme)
            .foregroundStyle(theme.text)
            .tint(theme.accent)
            .textSelection(.enabled)
    }

    /// Opens Space files as document tabs, web links in the browser, and ignores anchors.
    private func open(_ url: URL) -> OpenURLAction.Result {
        if let scheme = url.scheme?.lowercased(), scheme != MarkdownSpaceLinks.scheme {
            return scheme == "file" ? .discarded : .systemAction
        }
        guard let target = MarkdownSpaceLinks.resolve(url.path.isEmpty ? url.relativeString : url.path,
                                                      documentPath: path) else { return .discarded }
        onOpenFile(target)
        return .handled
    }
}

enum MarkdownSpaceLinks {
    static let scheme = "xherdr-space"

    /// A Space-relative path for a link or image target, or nil for anchors and paths leaving the Space.
    static func resolve(_ target: String, documentPath: String) -> String? {
        // Fragment and query come off before decoding: an encoded `#` or `?` is part of the name.
        var raw = target
        if let hash = raw.firstIndex(of: "#") { raw = String(raw[..<hash]) }
        if let query = raw.firstIndex(of: "?") { raw = String(raw[..<query]) }
        raw = raw.removingPercentEncoding ?? raw
        guard !raw.isEmpty else { return nil }
        let base = raw.hasPrefix("/") ? [] : (documentPath as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        var parts = base
        for part in raw.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Points relative image sources at the Space scheme so SpaceImageRenderer can load them
    /// through WorkspaceFiles; fenced code is left untouched.
    static func rewritingImages(in markdown: String, documentPath: String) -> String {
        guard markdown.contains("![") else { return markdown }
        // A destination is either `<any text>`, which may hold spaces, or a run without spaces.
        let pattern = try! NSRegularExpression(pattern: #"(!\[[^\]]*\]\()\s*(?:<([^>\n]+)>|([^)\s]+))"#)
        var inFence = false
        return markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return line }
            guard !inFence, line.contains("![") else { return line }
            let ns = line as NSString
            var output = line
            for match in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                let group = match.range(at: 2).location != NSNotFound ? 2 : 3
                let source = ns.substring(with: match.range(at: group))
                guard !source.contains(":"), let resolved = resolve(source, documentPath: documentPath),
                      let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
                output = (output as NSString).replacingCharacters(
                    in: match.range, with: ns.substring(with: match.range(at: 1)) + "\(scheme):///\(encoded)")
            }
            return output
        }.joined(separator: "\n")
    }
}

// MARK: - Images

private struct SpaceImageRenderer: MarkdownImageRenderer {
    let location: WorkspaceFileLocation

    func makeBody(configuration: Configuration) -> some View {
        SpaceImage(location: location, path: String(configuration.url.path.drop(while: { $0 == "/" })),
                   alt: configuration.alternativeText)
    }
}

private struct SpaceImage: View {
    @Environment(\.xherdrTypography) private var typography
    let location: WorkspaceFileLocation
    let path: String
    let alt: String?

    @Environment(\.xherdrTheme) private var theme
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width)
            } else if failed {
                Label(alt?.isEmpty == false ? alt! : path, systemImage: "photo")
                    .font(.system(size: typography.body))
                    .foregroundStyle(theme.muted)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: location.identity + path) {
            let (location, path) = (location, path)
            let data = await Task.detached(priority: .utility) {
                try? WorkspaceFiles.readData(path, at: location, limit: 12_000_000)
            }.value
            if let data, let loaded = NSImage(data: data) { image = loaded } else { failed = true }
        }
    }
}

// MARK: - Code blocks

/// Highlighted code blocks, except ```mermaid fences, which render as native diagrams.
private struct XherdrCodeBlockStyle: MarkdownCodeBlockStyle {
    let theme: XherdrTheme

    func makeBody(configuration: Configuration) -> some View {
        if configuration.language?.lowercased() == "mermaid" {
            MermaidBlock(source: configuration.code, theme: theme)
        } else {
            DefaultCodeBlockStyle(highlighterTheme: CodeHighlighterTheme(themeName: theme.highlighterName))
                .makeBody(configuration: configuration)
                // The block fills with the background style; on the document page that is GitHub's code gray.
                .backgroundStyle(theme.id == XherdrTheme.markdownDocument.id
                                 ? AnyShapeStyle(XherdrTheme.color(0xF6F8FA)) : AnyShapeStyle(.background))
        }
    }
}

private struct MermaidBlock: View {
    @Environment(\.xherdrTypography) private var typography
    let source: String
    let theme: XherdrTheme

    @State private var image: NSImage?
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Mermaid diagram could not be rendered: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: typography.body))
                        .foregroundStyle(theme.warning)
                    Text(source)
                        .font(.system(size: typography.code, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.fieldBackground, in: RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: "\(theme.id)|\(source)") {
            let diagramTheme = DiagramTheme(
                background: XherdrTheme.nsColor(theme.background),
                foreground: XherdrTheme.nsColor(theme.foreground),
                accent: XherdrTheme.nsColor(theme.herdr.accent),
                muted: XherdrTheme.nsColor(theme.herdr.subtext),
                surface: XherdrTheme.nsColor(theme.herdr.surface0),
                border: XherdrTheme.nsColor(theme.herdr.surface1)
            )
            do {
                guard let rendered = try await MermaidRenderer.renderImageAsync(source: source, theme: diagramTheme) else {
                    error = "unsupported diagram"
                    return
                }
                image = rendered
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension XherdrTheme {
    /// The closest highlight.js style bundled with Highlightr.
    var highlighterName: String {
        switch id {
        case "dracula": return "dracula"
        case "nord": return "nord"
        case "gruvbox": return "gruvbox-dark"
        case "gruvbox-light": return "gruvbox-light"
        case "solarized": return "solarized-dark"
        case "solarized-light": return "solarized-light"
        case "tokyo-night": return "tokyo-night-dark"
        case "tokyo-night-day": return "tokyo-night-light"
        case "one-dark": return "atom-one-dark"
        case "one-light": return "atom-one-light"
        case "rose-pine": return "rose-pine"
        case "rose-pine-dawn": return "rose-pine-dawn"
        case Self.markdownDocument.id: return "github"
        default: return isDark ? "atom-one-dark" : "atom-one-light"
        }
    }
}

// MARK: - Document style

extension XherdrTheme {
    /// The Markdown document page: GitHub's light Primer colors, used for the page, its code
    /// blocks, Mermaid diagrams and images whatever the app's theme. Not offered as an app theme.
    static let markdownDocument = XherdrTheme(
        id: "markdown-document", name: "Document", isDark: false,
        herdr: .init(accent: 0x0969DA, panel: 0xF6F8FA, activeRow: 0xF6F8FA, selection: 0xDDF4FF, surface0: 0xEFF2F5, surface1: 0xD1D9E0, surfaceDim: 0xF6F8FA, overlay0: 0x59636E, overlay1: 0x818B98, text: 0x1F2328, subtext: 0x59636E, mauve: 0x8250DF, green: 0x1A7F37, yellow: 0x9A6700, red: 0xD1242F, blue: 0x0969DA, teal: 0x1B7C83, peach: 0xBC4C00),
        background: 0xFFFFFF, foreground: 0x1F2328,
        cursor: 0x1F2328, selectionBackground: 0xDDF4FF,
        ansi: [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781, 0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F])
}

/// GitHub's README type scale: semibold headings at 2, 1.5, 1.25, 1, 0.875 and 0.85 em,
/// and code at 85 % of the body size.
private struct MarkdownDocumentFonts: MarkdownFontGroup {
    /// The body text size in points.
    let size: CGFloat

    private func heading(_ scale: CGFloat) -> NSFont { .systemFont(ofSize: (size * scale).rounded(), weight: .semibold) }

    var h1: any CustomCTFontConvertible { heading(2) }
    var h2: any CustomCTFontConvertible { heading(1.5) }
    var h3: any CustomCTFontConvertible { heading(1.25) }
    var h4: any CustomCTFontConvertible { heading(1) }
    var h5: any CustomCTFontConvertible { heading(0.875) }
    var h6: any CustomCTFontConvertible { heading(0.85) }
    var body: any CustomCTFontConvertible { NSFont.systemFont(ofSize: size) }
    var codeBlock: any CustomCTFontConvertible { NSFont.monospacedSystemFont(ofSize: (size * 0.85).rounded(), weight: .regular) }
    var blockQuote: any CustomCTFontConvertible { NSFont.systemFont(ofSize: size) }
    var tableHeader: any CustomCTFontConvertible { NSFont.systemFont(ofSize: size, weight: .semibold) }
    var tableBody: any CustomCTFontConvertible { NSFont.systemFont(ofSize: size) }
    var inlineMath: any CustomCTFontConvertible { NSFont.systemFont(ofSize: size) }
    var displayMath: any CustomCTFontConvertible { NSFont.systemFont(ofSize: size) }
}
