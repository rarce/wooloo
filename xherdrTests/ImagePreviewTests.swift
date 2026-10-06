import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import xherdr

enum ImageFixtures {
    static func data(type: UTType = .png, width: Int = 120, height: Int = 80,
                     orientation: Int = 1, frames: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.65, blue: 0.9, alpha: 0.7))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
final class ImagePreviewTests: XCTestCase {
    private var sandbox: WorkspaceGitSandbox!
    private var location: WorkspaceFileLocation!

    override func setUp() async throws {
        sandbox = try WorkspaceGitSandbox()
        location = try sandbox.repository("repo")
    }

    override func tearDown() async throws { sandbox.tearDown() }

    private func write(_ data: Data, as path: String = "sample.png") throws {
        try data.write(to: URL(fileURLWithPath: location.absolutePath(path)))
    }

    private func settle(_ store: WorkspaceDocumentStore) async {
        for _ in 0..<300 where store.documents.contains(where: \.isLoading) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.documents.contains(where: \.isLoading))
    }

    func testCommonImageFormatsDecodeWithDimensionsAndBinaryVersions() throws {
        for type: UTType in [.png, .jpeg, .gif, .tiff, .bmp, .heic] {
            let bytes = try ImageFixtures.data(type: type)
            let contents = try WorkspaceImage.decode(bytes)
            XCTAssertEqual(contents.size, CGSize(width: 120, height: 80), type.identifier)
            XCTAssertEqual(contents.image.width, 120, type.identifier)
            XCTAssertEqual(contents.image.height, 80, type.identifier)
            XCTAssertEqual(contents.byteCount, bytes.count)
            XCTAssertEqual(contents.version, WorkspaceFiles.gitBlobHash(bytes))
            XCTAssertFalse(contents.isDownsampled)
        }
        for ext in ["PNG", "JpG", "jpeg", "gif", "webp", "heic", "heif", "avif", "tiff", "tif", "bmp", "ico"] {
            XCTAssertTrue(WorkspaceImage.supports("folder/photo." + ext))
        }
        XCTAssertFalse(WorkspaceImage.supports("photo.png.txt"))
        XCTAssertFalse(WorkspaceImage.supports("drawing.svg"))
    }

    func testWebPAndAvailableAVIFDecodersReadActualEncodedImages() throws {
        let webP = try XCTUnwrap(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvC8ABEAdQvHqUu4CBiOh/AAA="))
        let decoded = try WorkspaceImage.decode(webP)
        XCTAssertEqual(decoded.size, CGSize(width: 12, height: 8))
        XCTAssertEqual(decoded.format, "WEBP")
        let writable = CGImageDestinationCopyTypeIdentifiers() as! [String]
        if writable.contains("public.avif"), let avif = UTType("public.avif") {
            let contents = try WorkspaceImage.decode(ImageFixtures.data(type: avif))
            XCTAssertEqual(contents.size, CGSize(width: 120, height: 80))
        }
        let icon = try WorkspaceImage.decode(ImageFixtures.data(type: .ico, width: 32, height: 32))
        XCTAssertEqual(icon.size, CGSize(width: 32, height: 32))
    }

    func testOrientationAndMultiFrameFilesUseAnUprightFirstFrame() throws {
        let rotated = try WorkspaceImage.decode(ImageFixtures.data(type: .jpeg, orientation: 6))
        XCTAssertEqual(rotated.size, CGSize(width: 80, height: 120))
        XCTAssertEqual(rotated.image.width, 80)
        XCTAssertEqual(rotated.image.height, 120)
        let gif = try WorkspaceImage.decode(ImageFixtures.data(type: .gif, frames: 2))
        XCTAssertEqual(gif.frameCount, 2)
        XCTAssertEqual(gif.size, CGSize(width: 120, height: 80))
    }

    func testLargeImagesHaveBoundedDecodedPreviewsAndKeepOriginalDimensions() throws {
        let contents = try WorkspaceImage.decode(ImageFixtures.data(width: 6000, height: 20))
        XCTAssertEqual(contents.size, CGSize(width: 6000, height: 20))
        XCTAssertLessThanOrEqual(contents.image.width, WorkspaceImage.maximumPreviewDimension)
        XCTAssertTrue(contents.isDownsampled)
    }

    func testImageReadRejectsCorruptOversizeAndOutsideSpaceFiles() throws {
        try write(Data("not an image".utf8))
        XCTAssertThrowsError(try WorkspaceImage.read("sample.png", at: location))
        let bytes = try ImageFixtures.data()
        try write(bytes)
        XCTAssertThrowsError(try WorkspaceImage.read("../repo/sample.png", at: location))
        let outside = URL(fileURLWithPath: sandbox.path("outside.png"))
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: location.absolutePath("link.png"), withDestinationPath: outside.path)
        XCTAssertThrowsError(try WorkspaceImage.read("link.png", at: location))
        let large = URL(fileURLWithPath: location.absolutePath("large.png"))
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let file = try FileHandle(forWritingTo: large)
        try file.truncate(atOffset: UInt64(WorkspaceImage.maximumFileBytes + 1))
        try file.close()
        XCTAssertThrowsError(try WorkspaceImage.read("large.png", at: location))
    }

    func testOpeningAnImageCreatesAReadOnlyTabAndNeverWritesTextOverIt() async throws {
        let bytes = try ImageFixtures.data()
        try write(bytes, as: "sample.PNG")
        let store = WorkspaceDocumentStore()
        store.open(.file, path: "sample.PNG", at: location, preview: true)
        await settle(store)
        let document = try XCTUnwrap(store.documents.first)
        XCTAssertNotNil(document.image)
        XCTAssertNil(document.error)
        XCTAssertTrue(document.isImage)
        XCTAssertTrue(document.isReadOnly)
        XCTAssertFalse(document.isEditable)
        XCTAssertFalse(document.supportsPreview)
        XCTAssertEqual(document.icon, "photo")
        store.documents[0].text = "accidental text"
        XCTAssertFalse(store.documents[0].isDirty)
        store.save(document.id) { XCTFail("An image must not be saved as text") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: location.absolutePath("sample.PNG"))), bytes)
        XCTAssertFalse(WorkspaceDocumentSnapshot(store.documents[0]).hasBackup)
        let draftID = store.newUntitled(at: location)
        let error = await store.saveUntitled(draftID, as: "new.jpg")
        XCTAssertNotNil(error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.absolutePath("new.jpg")))
    }

    func testReloadRecoversFromDecodeErrorsAndPreservesZoomOnSuccessOrFailure() async throws {
        try write(Data("broken".utf8))
        let store = WorkspaceDocumentStore()
        store.open(.file, path: "sample.png", at: location)
        await settle(store)
        XCTAssertNotNil(store.documents[0].error)
        let id = store.documents[0].id
        try write(ImageFixtures.data())
        store.documents[0].isLoading = true
        store.load(id)
        await settle(store)
        let image = try XCTUnwrap(store.documents[0].image)
        image.actualSize()
        image.zoom(2)
        try write(ImageFixtures.data(width: 200, height: 100))
        store.documents[0].isLoading = true
        store.load(id)
        await settle(store)
        XCTAssertTrue(store.documents[0].image === image)
        XCTAssertEqual(image.contents.size, CGSize(width: 200, height: 100))
        XCTAssertEqual(image.scale, 2)
        try write(Data("broken again".utf8))
        store.documents[0].isLoading = true
        store.load(id)
        await settle(store)
        XCTAssertNotNil(store.documents[0].error)
        XCTAssertTrue(store.documents[0].image === image)
        XCTAssertEqual(image.contents.size, CGSize(width: 200, height: 100))
        store.open(.change, path: "sample.png", at: location)
        await settle(store)
        let diff = try XCTUnwrap(store.documents.first { $0.kind == .change })
        XCTAssertFalse(diff.isImage)
        XCTAssertNil(diff.image)
    }

    func testNativePreviewFitsResizesAndRestoresZoomAndPanAcrossTabs() throws {
        let contents = try WorkspaceImage.decode(ImageFixtures.data(width: 1200, height: 800))
        let model = ImagePreviewModel(contents: contents)
        func view(_ size: CGSize) -> ImageScrollView {
            let view = ImageScrollView(frame: CGRect(origin: .zero, size: size))
            view.documentView = view.canvas
            view.layoutSubtreeIfNeeded()
            return view
        }
        let first = view(CGSize(width: 600, height: 400))
        model.attach(first)
        XCTAssertLessThanOrEqual(first.canvas.imageRect.width, first.contentView.bounds.width - 48)
        XCTAssertLessThanOrEqual(first.canvas.imageRect.height, first.contentView.bounds.height - 48)
        model.actualSize()
        XCTAssertEqual(first.canvas.imageRect.width, 1200)
        first.contentView.scroll(to: CGPoint(x: 400, y: 300))
        model.detach(first)
        // SwiftUI creates the next native view at zero size before laying it out.
        let next = view(.zero)
        next.onWillResize = { [weak model] in model?.capturePosition() }
        next.onResize = { [weak model] in model?.layout() }
        model.attach(next)
        next.setFrameSize(CGSize(width: 600, height: 400))
        next.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.scale, 1)
        XCTAssertEqual(next.contentView.bounds.origin.x, 400, accuracy: 1)
        XCTAssertEqual(next.contentView.bounds.origin.y, 300, accuracy: 1)
        model.zoom(2)
        XCTAssertEqual(next.canvas.imageRect.width, 2400)
        model.fitWindow()
        XCTAssertTrue(model.fitsWindow)
        next.setFrameSize(CGSize(width: 300, height: 200))
        next.layoutSubtreeIfNeeded()
        model.layout()
        XCTAssertLessThanOrEqual(next.canvas.imageRect.width, next.contentView.bounds.width - 48)
        model.detach(next)
    }
}
