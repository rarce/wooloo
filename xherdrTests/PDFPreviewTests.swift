import XCTest
import AppKit
import PDFKit
@testable import xherdr

enum PDFFixtures {
    /// Generate actual text PDFs with the system renderer, including Unicode text.
    static func data(pages: [String] = ["Alpha alpha banana", "alpha beta", "Last page"]) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(at: CGPoint(x: 48, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

@MainActor
final class PDFPreviewTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var location: WorkspaceFileLocation!

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        location = try sandbox.repository("repo")
    }

    override func tearDown() async throws { sandbox.tearDown() }

    private func write(_ data: Data, as path: String = "sample.pdf") throws {
        try data.write(to: URL(fileURLWithPath: location.absolutePath(path)))
    }

    private func settle(_ store: WorkspaceDocumentStore) async {
        for _ in 0..<300 where store.documents.contains(where: \.isLoading) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.documents.contains(where: \.isLoading))
    }

    private func settleSearch(_ model: PDFPreviewModel) async {
        for _ in 0..<300 where model.isFinding { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isFinding)
    }

    func testOpeningBinaryPDFKeepsOriginalBytesAndCannotSaveTextOverIt() async throws {
        let bytes = try PDFFixtures.data()
        try write(bytes, as: "sample.PDF")
        let store = WorkspaceDocumentStore()
        store.open(.file, path: "sample.PDF", at: location, preview: true)
        await settle(store)
        let document = try XCTUnwrap(store.documents.first)
        let pdf = try XCTUnwrap(document.pdf)
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertTrue(pdf.document.page(at: 0)?.string?.contains("Alpha alpha") == true)
        XCTAssertNil(document.error)
        XCTAssertEqual(document.version, WorkspaceFiles.gitBlobHash(bytes))
        XCTAssertTrue(document.isPDF)
        XCTAssertFalse(document.isEditable)
        XCTAssertFalse(document.supportsPreview, "PDFs have no text source/split mode")
        XCTAssertTrue(document.text.isEmpty)
        store.documents[0].text = "accidental text"
        XCTAssertFalse(store.documents[0].isDirty)
        store.save(document.id) { XCTFail("A PDF cannot be saved through the text writer") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: location.absolutePath("sample.PDF"))), bytes)
        XCTAssertTrue(store.close(document.id))
    }

    func testPDFReadRejectsMalformedFilesOversizeFilesAndPathsOutsideSpace() throws {
        try write(Data("plain text pretending to be a PDF".utf8))
        XCTAssertThrowsError(try WorkspacePDF.read("sample.pdf", at: location))
        try write(try PDFFixtures.data())
        XCTAssertThrowsError(try WorkspacePDF.read("../repo/sample.pdf", at: location))
        let outside = URL(fileURLWithPath: sandbox.path("outside.pdf"))
        try PDFFixtures.data().write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: location.absolutePath("link.pdf"),
                                                   withDestinationPath: outside.path)
        XCTAssertThrowsError(try WorkspacePDF.read("link.pdf", at: location))
        let large = URL(fileURLWithPath: location.absolutePath("large.pdf"))
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let file = try FileHandle(forWritingTo: large)
        try file.truncate(atOffset: UInt64(WorkspacePDF.maximumFileBytes + 1))
        try file.close()
        XCTAssertThrowsError(try WorkspacePDF.read("large.pdf", at: location))
    }

    func testFailedPDFLoadRecoversOnReloadAndDiffTabsStayTextual() async throws {
        try write(Data("broken".utf8))
        let store = WorkspaceDocumentStore()
        store.open(.file, path: "sample.pdf", at: location)
        await settle(store)
        XCTAssertNotNil(store.documents[0].error)
        let id = store.documents[0].id
        try write(try PDFFixtures.data())
        store.documents[0].isLoading = true
        store.load(id)
        await settle(store)
        XCTAssertNil(store.documents[0].error)
        XCTAssertNotNil(store.documents[0].pdf)

        store.open(.change, path: "sample.pdf", at: location)
        await settle(store)
        let diff = try XCTUnwrap(store.documents.first { $0.kind == .change })
        XCTAssertFalse(diff.isPDF)
        XCTAssertNil(diff.pdf)
    }

    func testPreviewReplacementAndSpaceSwitchingKeepPDFStateWithItsTab() async throws {
        try write(try PDFFixtures.data())
        let store = WorkspaceDocumentStore()
        store.showSpace("one")
        store.open(.file, path: "sample.pdf", at: location, preview: true)
        await settle(store)
        let pdf = try XCTUnwrap(store.documents[0].pdf)
        pdf.go(to: 2)
        store.keepOpen(store.documents[0].id)
        store.open(.file, path: "a.txt", at: location, preview: true)
        await settle(store)
        store.showSpace("two")
        store.open(.file, path: "sample.pdf", at: location, preview: true)
        await settle(store)
        store.showSpace("one")
        XCTAssertTrue(store.visibleDocuments.first?.pdf === pdf)
        XCTAssertEqual(pdf.pageNumber, 2)
        XCTAssertEqual(store.visibleDocuments.map(\.path), ["sample.pdf", "a.txt"])
    }

    func testNativeViewRestoresPageAndZoomAndReloadClampsToNewPageCount() throws {
        let contents = try XCTUnwrap(PDFDocument(data: PDFFixtures.data()))
        let model = PDFPreviewModel(document: contents)
        func view() -> PDFView {
            let view = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            view.displayMode = .singlePage
            view.minScaleFactor = 0.1
            view.maxScaleFactor = 10
            return view
        }
        let first = view()
        model.attach(first)
        model.go(to: 3)
        model.zoom(1.2)
        let scale = first.scaleFactor
        model.detach(first)
        let second = view()
        let coordinator = PDFNativeView.Coordinator(model: model)
        coordinator.observe(second)
        defer { coordinator.removeObservers() }
        model.attach(second)
        XCTAssertEqual(second.currentPage, contents.page(at: 2))
        XCTAssertEqual(second.scaleFactor, scale, accuracy: 0.001)
        let shorter = try XCTUnwrap(PDFDocument(data: PDFFixtures.data(pages: ["New first", "New second"])))
        model.replace(with: shorter)
        model.attach(second)
        XCTAssertEqual(model.pageNumber, 2)
        XCTAssertEqual(second.currentPage, shorter.page(at: 1))
        model.detach(second)
    }

    func testPDFSearchNavigatesNativeSelectionsAndCancelsPreviousQueries() async throws {
        let model = PDFPreviewModel(document: try XCTUnwrap(PDFDocument(data: PDFFixtures.data())))
        model.showsFind = true
        model.query = "alpha"
        model.search()
        await settleSearch(model)
        XCTAssertEqual(model.matches.count, 3)
        XCTAssertEqual(model.currentMatch, 0)
        model.moveMatch(-1)
        XCTAssertEqual(model.currentMatch, 2)
        XCTAssertEqual(model.matches[2].pages.first, model.document.page(at: 1))
        model.moveMatch(1)
        XCTAssertEqual(model.currentMatch, 0)
        model.caseSensitive = true
        model.search()
        await settleSearch(model)
        XCTAssertEqual(model.matches.count, 2)
        model.query = "banana"
        model.search()
        model.query = "missing"
        model.search()
        await settleSearch(model)
        XCTAssertTrue(model.matches.isEmpty)
        model.closeFind()
        XCTAssertNil(model.currentMatch)
        XCTAssertFalse(model.showsFind)
    }

    func testFitPageAndWidthUseViewportAndRotatedPageDimensions() throws {
        let document = try XCTUnwrap(PDFDocument(data: PDFFixtures.data()))
        let model = PDFPreviewModel(document: document)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        model.attach(view)
        model.setFit(.page)
        XCTAssertLessThanOrEqual(view.scaleFactor * 792, view.bounds.height)
        model.setFit(.width)
        XCTAssertEqual(view.scaleFactor * 612, view.bounds.width - 32, accuracy: 0.5)
        document.page(at: 0)?.rotation = 90
        model.setFit(.width)
        XCTAssertEqual(view.scaleFactor * 792, view.bounds.width - 32, accuracy: 0.5)
        model.detach(view)
    }

    func testOpenFindKeepsItsSelectedMatchAndPageAcrossViewRecreation() async throws {
        let model = PDFPreviewModel(document: try XCTUnwrap(PDFDocument(data: PDFFixtures.data())))
        let first = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        first.displayMode = .singlePage
        model.attach(first)
        model.showsFind = true
        model.query = "alpha"
        model.search()
        await settleSearch(model)
        model.moveMatch(-1)
        model.capturePosition()
        XCTAssertEqual(model.pageNumber, 2)
        model.detach(first)
        let second = PDFView(frame: first.frame)
        second.displayMode = .singlePage
        model.attach(second)
        model.openFind()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(model.currentMatch, 2)
        XCTAssertEqual(second.currentPage, model.document.page(at: 1))
        model.detach(second)
    }

    func testLockedPDFUnlocksWithoutChangingDiskAndFormsAreReadOnly() throws {
        let original = try XCTUnwrap(PDFDocument(data: PDFFixtures.data()))
        let field = PDFAnnotation(bounds: CGRect(x: 40, y: 600, width: 180, height: 24), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.widgetStringValue = "Saved value"
        original.page(at: 0)?.addAnnotation(field)
        let bytes = try XCTUnwrap(original.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner",
                                                                        PDFDocumentWriteOption.userPasswordOption: "secret"]))
        try write(bytes)
        let model = PDFPreviewModel(document: try WorkspacePDF.read("sample.pdf", at: location).document)
        XCTAssertTrue(model.isLocked)
        model.unlock(password: "wrong")
        XCTAssertTrue(model.isLocked)
        XCTAssertNotNil(model.error)
        model.unlock(password: "secret")
        XCTAssertFalse(model.isLocked)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.pageCount, 3)
        let widget = try XCTUnwrap(model.document.page(at: 0)?.annotations.first { $0.type == "Widget" })
        XCTAssertTrue(widget.isReadOnly)
        XCTAssertEqual(widget.widgetStringValue, "Saved value")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: location.absolutePath("sample.pdf"))), bytes)
    }
}
