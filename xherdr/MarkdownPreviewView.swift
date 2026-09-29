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

/// Renders a Markdown document from the Space with MarkdownView, drawing ```mermaid blocks
/// natively with BeautifulMermaid. Images and links resolve against the Space, locally or over SSH.
struct MarkdownPreviewView: View {
    let text: String
    let path: String
    let location: WorkspaceFileLocation
    let onOpenFile: (String) -> Void

    @Environment(\.xherdrTheme) private var theme

    var body: some View {
        ScrollView {
            MarkdownView(MarkdownSpaceLinks.rewritingImages(in: text, documentPath: path))
                .markdownCodeBlockStyle(XherdrCodeBlockStyle(theme: theme))
                .markdownElementRenderer(.image(SpaceImageRenderer(location: location),
                                                urlScheme: MarkdownSpaceLinks.scheme))
                // Block spacing plus heading padding approximates GitHub's 16pt block margins.
                .markdownBlockSpacing(14)
                .padding(.top, 12, for: .h1, .h2, .h3)
                .padding(.top, 6, for: .h4, .h5, .h6)
                .environment(\.openURL, OpenURLAction { open($0) })
                .foregroundStyle(theme.text)
                .tint(theme.accent)
                .textSelection(.enabled)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(theme.contentBackground)
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
        var raw = target.removingPercentEncoding ?? target
        if let hash = raw.firstIndex(of: "#") { raw = String(raw[..<hash]) }
        if let query = raw.firstIndex(of: "?") { raw = String(raw[..<query]) }
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
        let pattern = try! NSRegularExpression(pattern: #"(!\[[^\]]*\]\()\s*<?([^)\s>]+)>?"#)
        var inFence = false
        return markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return line }
            guard !inFence, line.contains("![") else { return line }
            let ns = line as NSString
            var output = line
            for match in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                let source = ns.substring(with: match.range(at: 2))
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
                    .font(.system(size: 11))
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
        }
    }
}

private struct MermaidBlock: View {
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
                        .font(.system(size: 11))
                        .foregroundStyle(theme.warning)
                    Text(source)
                        .font(.system(size: 11, design: .monospaced))
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
        default: return isDark ? "atom-one-dark" : "atom-one-light"
        }
    }
}
