import SwiftUI
import PDFKit

/// Binary PDF reads use the same Space boundaries and SSH transport as other files.
enum WorkspacePDF {
    static let maximumFileBytes = 50 * 1_024 * 1_024

    static func supports(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }

    struct Contents {
        let document: PDFDocument
        let version: String
    }

    /// Run on a worker, then hand the document to the main thread for exclusive UI use.
    static func read(_ path: String, at location: WorkspaceFileLocation) throws -> Contents {
        let data = try WorkspaceFiles.readData(path, at: location, limit: maximumFileBytes)
        guard let document = PDFDocument(data: data) else {
            throw WorkspaceFileError.message("This file is not a readable PDF")
        }
        try prepare(document)
        return Contents(document: document, version: WorkspaceFiles.gitBlobHash(data))
    }

    static func prepare(_ document: PDFDocument) throws {
        // Locked PDFs have no readable pages until the user supplies their password.
        guard !document.isLocked else { return }
        guard document.pageCount > 0 else { throw WorkspaceFileError.message("This PDF has no pages") }
        // PDFView normally allows filling forms. Disable it in this preview's in-memory copy;
        // neither this flag nor any other preview interaction is written to the original file.
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                annotation.isReadOnly = true
            }
        }
    }
}

/// Retained by the document tab, independently of the lifetime of its visible PDFView.
@MainActor
final class PDFPreviewModel: NSObject, ObservableObject, @preconcurrency PDFDocumentDelegate {
    enum Fit { case page, width, custom }
    static let maximumMatches = 10_000

    @Published private(set) var document: PDFDocument
    @Published private(set) var isLocked: Bool
    @Published private(set) var error: String?
    @Published private(set) var pageNumber = 1
    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var fit: Fit = .page
    @Published var showsFind = false
    @Published var query = ""
    @Published var caseSensitive = false
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var currentMatch: Int?
    @Published private(set) var isFinding = false
    @Published private(set) var findFocusRequest = 0
    @Published private(set) var isTruncated = false
    private weak var view: PDFView?
    private var destination: PDFDestination?
    private var searchTask: Task<Void, Never>?
    private var appliesScale = false
    private var attachesView = false
    private var resumesSearch = false
    private var revealsFirstMatch = true

    var pageCount: Int { document.pageCount }

    init(document: PDFDocument) {
        self.document = document
        isLocked = document.isLocked
        super.init()
        document.delegate = self
    }

    func replace(with next: PDFDocument) {
        capturePosition()
        let point = destination?.point
        stopSearch()
        document.delegate = nil
        document = next
        next.delegate = self
        isLocked = next.isLocked
        error = nil
        pageNumber = min(pageNumber, max(1, next.pageCount))
        destination = next.page(at: pageNumber - 1).map {
            PDFDestination(page: $0, at: point ?? CGPoint(x: $0.bounds(for: .cropBox).minX,
                                                        y: $0.bounds(for: .cropBox).maxY))
        }
        matches = []
        currentMatch = nil
        resumesSearch = showsFind
    }

    func unlock(password: String) {
        guard document.unlock(withPassword: password) else {
            error = "Incorrect PDF password"
            return
        }
        do {
            try WorkspacePDF.prepare(document)
            error = nil
            isLocked = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func attach(_ view: PDFView) {
        // Assigning a document posts page/scale notifications for its initial page. Those
        // notifications must not overwrite the destination we are about to restore.
        attachesView = true
        defer { attachesView = false }
        self.view = view
        view.document = document
        applyFit()
        if let destination { view.go(to: destination) }
        if showsFind, let currentMatch, matches.indices.contains(currentMatch) {
            view.setCurrentSelection(matches[currentMatch], animate: false)
        }
        if showsFind && resumesSearch {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, self.view === view else { return }
                self.search(revealFirstMatch: false)
            }
        }
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.view === view else { return }
            self.capturePosition()
        }
    }

    func detach(_ view: PDFView) {
        guard self.view === view else { return }
        capturePosition()
        resumesSearch = isFinding
        stopSearch()
        self.view = nil
    }

    func capturePosition() {
        guard !attachesView, let view, view.document === document else { return }
        destination = view.currentDestination
        if let page = view.currentPage {
            let number = document.index(for: page) + 1
            if pageNumber != number { pageNumber = number }
        }
        if scale != view.scaleFactor { scale = view.scaleFactor }
    }

    func scaleChanged() {
        guard !attachesView, let view else { return }
        if !appliesScale, !view.autoScales { fit = .custom }
        capturePosition()
    }

    func go(to number: Int) {
        guard !isLocked, (1...max(1, pageCount)).contains(number), let page = document.page(at: number - 1) else { return }
        pageNumber = number
        destination = PDFDestination(page: page, at: CGPoint(x: page.bounds(for: .cropBox).minX,
                                                            y: page.bounds(for: .cropBox).maxY))
        view?.go(to: page)
    }

    func zoom(_ multiplier: CGFloat) {
        guard let view else { return }
        fit = .custom
        view.autoScales = false
        view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, view.scaleFactor * multiplier))
        capturePosition()
    }

    func setFit(_ fit: Fit) {
        self.fit = fit
        applyFit()
    }

    func applyFit() {
        guard let view, !isLocked else { return }
        appliesScale = true
        defer { appliesScale = false }
        switch fit {
        case .page, .width:
            view.autoScales = false
            guard let page = view.currentPage ?? document.page(at: 0) else { return }
            let bounds = page.bounds(for: .cropBox)
            let width = page.rotation % 180 == 0 ? bounds.width : bounds.height
            let height = page.rotation % 180 == 0 ? bounds.height : bounds.width
            guard width > 0, height > 0, view.bounds.width > 32, view.bounds.height > 32 else { return }
            let widthScale = (view.bounds.width - 32) / width
            let pageScale = min(widthScale, (view.bounds.height - 32) / height)
            view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, fit == .width ? widthScale : pageScale))
        case .custom:
            view.autoScales = false
            view.scaleFactor = scale
        }
    }

    func openFind() {
        let wasVisible = showsFind
        if !wasVisible, let selected = view?.currentSelection?.string, !selected.contains("\n") {
            query = selected
        }
        showsFind = true
        findFocusRequest += 1
        if !wasVisible { search() }
    }

    func closeFind() {
        showsFind = false
        stopSearch()
        matches = []
        currentMatch = nil
        view?.highlightedSelections = nil
        view?.window?.makeFirstResponder(view)
    }

    func search(revealFirstMatch: Bool = true) {
        stopSearch()
        resumesSearch = false
        revealsFirstMatch = revealFirstMatch
        matches = []
        currentMatch = nil
        isTruncated = false
        view?.highlightedSelections = nil
        guard showsFind, !isLocked, !query.isEmpty else { return }
        isFinding = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.document.beginFindString(self.query, withOptions: self.caseSensitive ? [] : .caseInsensitive)
        }
    }

    private func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        document.cancelFindString()
        isFinding = false
    }

    func didMatchString(_ instance: PDFSelection) {
        guard showsFind, isFinding else { return }
        guard matches.count < Self.maximumMatches else {
            isTruncated = true
            stopSearch()
            return
        }
        matches.append(instance)
        if currentMatch == nil {
            currentMatch = 0
            if revealsFirstMatch { revealMatch() }
        }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        isFinding = false
    }

    func moveMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = ((currentMatch ?? (delta > 0 ? -1 : 0)) + delta + matches.count) % matches.count
        revealMatch()
    }

    private func revealMatch() {
        guard let currentMatch, matches.indices.contains(currentMatch) else { return }
        let selection = matches[currentMatch]
        view?.setCurrentSelection(selection, animate: true)
        view?.go(to: selection)
    }
}

struct PDFPreviewView: View {
    @Environment(\.xherdrTheme) private var theme
    @Environment(\.xherdrTypography) private var typography
    @ObservedObject var model: PDFPreviewModel
    let focusRequest: UUID?
    let onFocus: () -> Void
    @State private var password = ""
    @State private var pageInput = "1"
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.isLocked {
                VStack(spacing: 12) {
                    Image(systemName: "lock.doc").font(.system(size: 32))
                    Text("This PDF is password protected")
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(unlock)
                    Button("Unlock", action: unlock).disabled(password.isEmpty)
                    if let error = model.error { Text(error).foregroundStyle(theme.warning) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                toolbar
                Divider()
                if model.showsFind {
                    findBar
                    Divider()
                }
                PDFNativeView(model: model, background: NSColor(theme.contentBackground),
                              focusRequest: focusRequest, onFocus: onFocus)
            }
        }
        .font(.system(size: typography.body))
        .onChange(of: model.query) { _, _ in model.search() }
        .onChange(of: model.caseSensitive) { _, _ in model.search() }
        .onChange(of: model.pageNumber) { _, value in pageInput = String(value) }
        .onChange(of: model.findFocusRequest) { _, _ in focusFind() }
        .onChange(of: model.showsFind) { _, value in
            if !value { findFocused = false }
        }
        .onAppear { pageInput = String(model.pageNumber) }
    }

    private func unlock() {
        model.unlock(password: password)
        password = ""
    }

    private func focusFind() {
        // The field is inserted when Find opens. Request focus after SwiftUI registers it,
        // including when reopening the bar after its previous field was removed.
        findFocused = false
        DispatchQueue.main.async { findFocused = true }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.go(to: model.pageNumber - 1) } label: { Image(systemName: "chevron.up") }
                .help("Previous PDF Page").accessibilityLabel("Previous PDF Page")
                .disabled(model.pageNumber <= 1)
            Button { model.go(to: model.pageNumber + 1) } label: { Image(systemName: "chevron.down") }
                .help("Next PDF Page").accessibilityLabel("Next PDF Page")
                .disabled(model.pageNumber >= model.pageCount)
            TextField("Page", text: $pageInput)
                .textFieldStyle(.roundedBorder).frame(width: 48)
                .accessibilityLabel("PDF Page")
                .onSubmit {
                    if let number = Int(pageInput) { model.go(to: number) }
                    pageInput = String(model.pageNumber)
                }
            Text("of \(model.pageCount)").monospacedDigit()
            Spacer()
            Button { model.zoom(1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom Out").accessibilityLabel("Zoom Out")
            Text("\(Int(model.scale * 100))%").monospacedDigit().frame(minWidth: 40)
            Button { model.zoom(1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom In").accessibilityLabel("Zoom In")
            Button("Fit Page") { model.setFit(.page) }
            Button("Fit Width") { model.setFit(.width) }
            Button { model.openFind() } label: { Image(systemName: "magnifyingglass") }
                .help("Find in PDF (⌘F)").accessibilityLabel("Find in PDF")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 33)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            TextField("Find in PDF", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .onSubmit { model.moveMatch(1) }
                .onAppear { focusFind() }
            Toggle("Aa", isOn: $model.caseSensitive).toggleStyle(.button).help("Match Case")
            if model.isFinding { ProgressView().controlSize(.small) }
            Text(findCounter).monospacedDigit().frame(minWidth: 80)
            Button { model.moveMatch(-1) } label: { Image(systemName: "chevron.up") }
                .help("Previous Match (⇧⌘G)").accessibilityLabel("Previous PDF Match")
                .disabled(model.matches.isEmpty)
            Button { model.moveMatch(1) } label: { Image(systemName: "chevron.down") }
                .help("Next Match (⌘G)").accessibilityLabel("Next PDF Match")
                .disabled(model.matches.isEmpty)
            Button("Done") { model.closeFind() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onExitCommand { model.closeFind() }
    }

    private var findCounter: String {
        guard !model.query.isEmpty else { return "" }
        guard let current = model.currentMatch else { return model.isFinding ? "Searching…" : "No results" }
        return "\(current + 1) of \(model.matches.count)\(model.isTruncated ? "+" : "")"
    }
}

/// PDFKit owns scrolling and text selection. SwiftUI owns the toolbar and search field.
struct PDFNativeView: NSViewRepresentable {
    let model: PDFPreviewModel
    let background: NSColor
    let focusRequest: UUID?
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ResizingPDFView {
        let view = ResizingPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 10
        view.backgroundColor = background
        view.delegate = context.coordinator
        model.attach(view)
        context.coordinator.observe(view)
        view.onResize = { [weak model] in
            if let model, model.fit != .custom { model.applyFit() }
        }
        return view
    }

    func updateNSView(_ view: ResizingPDFView, context: Context) {
        view.backgroundColor = background
        if view.document !== model.document { model.attach(view) }
        if let focusRequest, context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                onFocus()
            }
        }
    }

    static func dismantleNSView(_ view: ResizingPDFView, coordinator: Coordinator) {
        coordinator.model.detach(view)
        coordinator.removeObservers()
        view.onResize = nil
        view.delegate = nil
        view.document = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PDFViewDelegate {
        let model: PDFPreviewModel
        var focusRequest: UUID?
        private var observers: [NSObjectProtocol] = []

        init(model: PDFPreviewModel) { self.model = model }

        func observe(_ view: PDFView) {
            observers = [
                NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.model.capturePosition()
                        if let model = self?.model, model.fit != .custom { model.applyFit() }
                    }
                },
                NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.scaleChanged() }
                }
            ]
            DispatchQueue.main.async { [weak self] in self?.model.capturePosition() }
        }

        func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

final class ResizingPDFView: PDFView {
    var onResize: (() -> Void)?
    private var lastSize = CGSize.zero

    override func layout() {
        super.layout()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onResize?()
        }
    }
}
