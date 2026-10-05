import SwiftUI
import WebKit
import ImageIO

struct NotebookPreviewView: View {
    @Environment(\.xherdrTheme) private var theme
    @Environment(\.xherdrTypography) private var typography
    let text: String
    let path: String
    let location: WorkspaceFileLocation
    let onOpenFile: (String) -> Void
    var style: MarkdownPreviewStyle = .theme
    var matches: [MarkdownFindMatch] = []
    var currentMatch: Int?
    var revealRequest = 0
    var onSearchText: ([String]) -> Void = { _ in }
    var onFindCommand: (String, Bool, Bool) -> Void = { _, _, _ in }
    @State private var notebook: NotebookDocument?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Notebook preview unavailable", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(error).textSelection(.enabled)
                    Text("Use Source view to inspect or correct the JSON.").foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let notebook {
                NotebookWebView(notebook: notebook, path: path, location: location,
                                theme: style == .document ? .markdownDocument : theme, typography: typography,
                                matches: matches, currentMatch: currentMatch, revealRequest: revealRequest,
                                onOpenFile: onOpenFile, onSearchText: onSearchText, onFindCommand: onFindCommand)
            } else {
                ProgressView("Preparing notebook…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.contentBackground)
        .task(id: text) {
            onSearchText([])
            // Coalesce raw-source edits, and never perform JSON parsing on the UI thread.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let source = text
            let result = await Task.detached(priority: .userInitiated) { Result { try NotebookDocument.parse(source) } }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): notebook = value; error = nil
            case .failure(let failure): notebook = nil; error = failure.localizedDescription
            }
        }
    }
}

/// Owns one restricted webview for a visible document, including all output and Markdown cells.
struct NotebookWebView: NSViewRepresentable {
    let notebook: NotebookDocument
    let path: String
    let location: WorkspaceFileLocation
    let theme: XherdrTheme
    let typography: XherdrTypography
    var matches: [MarkdownFindMatch]
    var currentMatch: Int?
    var revealRequest: Int
    let onOpenFile: (String) -> Void
    let onSearchText: ([String]) -> Void
    let onFindCommand: (String, Bool, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: NotebookResources.scheme)
        configuration.userContentController.add(context.coordinator, name: "notebook")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("Notebook saved output")
        context.coordinator.webView = view
        context.coordinator.update(self)
        view.loadHTMLString(NotebookResources.html(), baseURL: URL(string: "xherdr-notebook://app/"))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.resources.clear()
        coordinator.webView = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var owner: NotebookWebView
        let resources = NotebookResources()
        weak var webView: WKWebView?
        private var ready = false
        private var lastJSON: String?
        private var lastModelID: UUID?
        private var lastPalette: [String: String] = [:]
        private var lastFind = ""
        private var lastReveal = -1
        private(set) var revision = ""

        init(_ owner: NotebookWebView) { self.owner = owner }

        func update(_ owner: NotebookWebView) {
            self.owner = owner
            guard ready, let webView else { return }
            let palette = Self.palette(theme: owner.theme, typography: owner.typography)
            if owner.notebook.identity != lastModelID || palette != lastPalette {
                if owner.notebook.identity != lastModelID {
                    lastJSON = owner.notebook.previewJSON; lastModelID = owner.notebook.identity
                }
                guard let json = lastJSON else { return }
                lastPalette = palette
                revision = UUID().uuidString.lowercased()
                resources.replace(images: owner.notebook.images, location: owner.location, documentPath: owner.path, revision: revision)
                lastFind = ""
                webView.callAsyncJavaScript("window.notebook.render(JSON.parse(payload), token, palette)",
                                            arguments: ["payload": json, "token": revision, "palette": palette],
                                            in: nil, in: .page, completionHandler: { _ in })
            }
            updateFind()
        }

        private func updateFind() {
            guard ready, let webView else { return }
            let ranges = owner.matches.enumerated().map { index, match in
                ["block": match.block, "lower": match.range.lowerBound, "upper": match.range.upperBound, "index": index]
            }
            let signature = "\(ranges)|\(owner.currentMatch ?? -1)"
            let reveal = owner.revealRequest != lastReveal
            guard signature != lastFind || reveal else { return }
            lastFind = signature; lastReveal = owner.revealRequest
            webView.callAsyncJavaScript("window.notebook.find(matches, current, reveal)",
                                        arguments: ["matches": ranges, "current": owner.currentMatch as Any? ?? NSNull(), "reveal": reveal],
                                        in: nil, in: .page, completionHandler: { _ in })
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            update(owner)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The app owns the initial HTML. Every user link is handled outside this webview.
            let initial = ["about:blank", "xherdr-notebook://app/"].contains(action.request.url?.absoluteString ?? "")
            decisionHandler(!ready && action.navigationType == .other && initial ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false; lastJSON = nil; lastModelID = nil; resources.clear()
            webView.loadHTMLString(NotebookResources.html(), baseURL: URL(string: "xherdr-notebook://app/"))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  body["revision"] as? String == revision, let kind = body["kind"] as? String else { return }
            switch kind {
            case "search":
                guard let text = body["text"] as? [String], text.count <= 50_000,
                      text.reduce(0, { $0 + $1.utf8.count }) <= NotebookDocument.maximumFileBytes * 2 else { return }
                owner.onSearchText(text)
            case "copy":
                guard let text = body["text"] as? String, text.count <= NotebookDocument.maximumTextCharacters else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            case "link":
                guard let target = body["target"] as? String, target.utf8.count <= 4_096 else { return }
                if let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                } else if let relative = NotebookResources.localPath(target, documentPath: owner.path) {
                    owner.onOpenFile(relative)
                }
            case "image":
                guard let id = body["id"] as? String, id.count <= 32, let target = body["target"] as? String else { return }
                let url = resources.registerImage(target)
                webView?.callAsyncJavaScript("window.notebook.image(id, url, token)",
                                            arguments: ["id": id, "url": url as Any? ?? NSNull(), "token": revision],
                                            in: nil, in: .page, completionHandler: { _ in })
            case "findCommand":
                owner.onFindCommand(body["key"] as? String ?? "", body["shift"] as? Bool ?? false, body["option"] as? Bool ?? false)
            case "escape": owner.onFindCommand("escape", false, false)
            default: break
            }
        }

        static func palette(theme: XherdrTheme, typography: XherdrTypography) -> [String: String] {
            func hex(_ value: UInt32) -> String { String(format: "#%06x", value) }
            var result = ["--background": hex(theme.background), "--panel": hex(theme.herdr.panel),
                          "--text": hex(theme.herdr.text), "--muted": hex(theme.herdr.subtext),
                          "--accent": hex(theme.herdr.accent), "--border": hex(theme.herdr.surface1),
                          "--error": hex(theme.herdr.red), "--green": hex(theme.herdr.green),
                          "--purple": hex(theme.herdr.mauve), "--yellow": hex(theme.herdr.yellow),
                          "--body-size": "\(typography.body + 1)px", "--code-size": "\(typography.code + 1)px",
                          "color-scheme": theme.isDark ? "dark" : "light"]
            for (index, value) in theme.ansi.enumerated() { result["--ansi-\(index)"] = hex(value) }
            return result
        }
    }
}

/// Only bundled assets and registered, bounded raster images can cross the webview boundary.
final class NotebookResources: NSObject, WKURLSchemeHandler {
    static let scheme = "xherdr-notebook"
    private enum Resource { case encoded(NotebookDocument.Image), file(String) }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.xherdr.notebook-resources", qos: .userInitiated)
    private var active = Set<ObjectIdentifier>()
    private var entries: [String: Resource] = [:]
    private var location: WorkspaceFileLocation?
    private var documentPath = ""
    private var revision = ""
    private var decodedBytes = 0
    private var countedImages = Set<String>()

    static var previewDirectory: URL? { Bundle.main.url(forResource: "NotebookAssets", withExtension: nil) }
    static var vendorDirectory: URL? { Bundle.main.url(forResource: "NotebookPreview", withExtension: nil) }

    static func html() -> String {
        guard let directory = previewDirectory, let text = try? String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8) else {
            return "<html><body>Notebook preview assets are unavailable.</body></html>"
        }
        return text.replacingOccurrences(of: "{{nonce}}", with: UUID().uuidString)
    }

    func replace(images: [String: NotebookDocument.Image], location: WorkspaceFileLocation, documentPath: String, revision: String) {
        lock.lock(); defer { lock.unlock() }
        entries = images.mapValues { .encoded($0) }
        self.location = location; self.documentPath = documentPath; self.revision = revision
        decodedBytes = 0
        countedImages.removeAll()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); active.removeAll(); location = nil; revision = ""; decodedBytes = 0; countedImages.removeAll()
    }

    static func localPath(_ target: String, documentPath: String) -> String? {
        guard !target.hasPrefix("//"), URL(string: target)?.scheme == nil else { return nil }
        return MarkdownSpaceLinks.resolve(target, documentPath: documentPath)
    }

    func registerImage(_ target: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard entries.count < 10_000 else { return nil }
        let resource: Resource
        if target.hasPrefix("data:image/"), let comma = target.firstIndex(of: ","), target[..<comma].hasSuffix(";base64") {
            let mime = String(target.dropFirst(5).prefix(while: { $0 != ";" }))
            guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime),
                  target.utf8.count <= NotebookDocument.maximumImageBytes * 4 / 3 + 4_096 else { return nil }
            resource = .encoded(.init(base64: String(target[target.index(after: comma)...]), mime: mime))
        } else {
            guard target.utf8.count <= 4_096, let path = Self.localPath(target, documentPath: documentPath) else { return nil }
            resource = .file(path)
        }
        let id = UUID().uuidString.lowercased(); entries[id] = resource
        return "\(Self.scheme)://\(revision)/image/\(id)"
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        lock.lock(); active.insert(key); lock.unlock()
        let url = task.request.url
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.data(for: url) }
            DispatchQueue.main.async {
                self.lock.lock(); let isActive = self.active.remove(key) != nil; self.lock.unlock()
                guard isActive else { return }
                switch result {
                case .success(let (data, mime)):
                    task.didReceive(URLResponse(url: url!, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                    task.didReceive(data); task.didFinish()
                case .failure(let error): task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); active.remove(ObjectIdentifier(task)); lock.unlock()
    }

    func data(for url: URL?) throws -> (Data, String) {
        guard let url, url.scheme == Self.scheme else { throw URLError(.badURL) }
        let components = url.path.split(separator: "/").map(String.init)
        if url.host == "app", components.count >= 2, ["preview", "vendor"].contains(components[0]) {
            let relative = components.dropFirst().joined(separator: "/")
            try WorkspaceFiles.validateRelativePath(relative)
            guard !relative.contains("\\"), let directory = components[0] == "preview" ? Self.previewDirectory : Self.vendorDirectory else { throw URLError(.fileDoesNotExist) }
            let file = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard file.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw URLError(.noPermissionsToReadFile) }
            let types = ["js": "application/javascript", "css": "text/css", "woff2": "font/woff2"]
            guard let mime = types[file.pathExtension] else { throw URLError(.unsupportedURL) }
            return (try Data(contentsOf: file), mime)
        }
        lock.lock()
        let token = revision, resource = components.count == 2 && components[0] == "image" && url.host == revision ? entries[components[1]] : nil
        let location = self.location
        lock.unlock()
        guard let resource else { throw URLError(.fileDoesNotExist) }
        let data: Data
        switch resource {
        case .encoded(let image):
            guard let decoded = Data(base64Encoded: image.base64, options: .ignoreUnknownCharacters) else { throw URLError(.cannotDecodeContentData) }
            data = decoded
        case .file(let path):
            guard let location else { throw URLError(.fileDoesNotExist) }
            data = try WorkspaceFiles.readData(path, at: location, limit: NotebookDocument.maximumImageBytes)
        }
        guard data.count <= NotebookDocument.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= NotebookDocument.maximumImagePixels / height else {
            throw URLError(.cannotDecodeContentData)
        }
        guard CGImageSourceGetCount(source) <= NotebookDocument.maximumImagePixels / (width * height) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        lock.lock(); defer { lock.unlock() }
        let additionalBytes = countedImages.contains(components[1]) ? 0 : data.count
        guard revision == token, decodedBytes + additionalBytes <= 64 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        decodedBytes += additionalBytes; countedImages.insert(components[1])
        let mime = ["public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif", "org.webmproject.webp": "image/webp"][type]!
        return (data, mime)
    }
}
