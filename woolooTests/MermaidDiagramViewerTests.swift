import AppKit
import BeautifulMermaid
import SwiftUI
import XCTest
@testable import wooloo

final class MermaidViewportTests: XCTestCase {
    func testFitIncludesExtremeDiagramsWithoutAMinimumZoomFloor() {
        for size in [CGSize(width: 100_000, height: 100), CGSize(width: 100, height: 100_000)] {
            var viewport = MermaidViewport(contentSize: size)
            viewport.resize(CGSize(width: 800, height: 600))
            XCTAssertLessThan(viewport.scale, 0.01)
            XCTAssertGreaterThanOrEqual(viewport.imageRect.minX, 24)
            XCTAssertGreaterThanOrEqual(viewport.imageRect.minY, 24)
            XCTAssertLessThanOrEqual(viewport.imageRect.maxX, 776)
            XCTAssertLessThanOrEqual(viewport.imageRect.maxY, 576)
        }
    }

    func testSmallDiagramIsCenteredAtActualSize() {
        var viewport = MermaidViewport(contentSize: CGSize(width: 100, height: 50))
        viewport.resize(CGSize(width: 800, height: 600))
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.imageRect, CGRect(x: 350, y: 275, width: 100, height: 50))
    }

    func testPinchKeepsThePointUnderThePointer() {
        var viewport = MermaidViewport(contentSize: CGSize(width: 2_000, height: 2_000))
        viewport.resize(CGSize(width: 800, height: 600))
        viewport.zoom(to: 1)
        let point = CGPoint(x: 280, y: 240)
        let before = viewport.imageRect
        let logical = CGPoint(x: (point.x - before.minX) / viewport.scale,
                              y: (point.y - before.minY) / viewport.scale)
        viewport.zoom(to: 2, anchor: point)
        XCTAssertEqual(viewport.imageRect.minX + logical.x * viewport.scale, point.x, accuracy: 0.001)
        XCTAssertEqual(viewport.imageRect.minY + logical.y * viewport.scale, point.y, accuracy: 0.001)
    }

    func testPanIsClampedAndFitResetsIt() {
        var viewport = MermaidViewport(contentSize: CGSize(width: 2_000, height: 1_000))
        viewport.resize(CGSize(width: 800, height: 600))
        viewport.zoom(to: 1)
        viewport.pan(CGSize(width: 1_000_000, height: -1_000_000))
        XCTAssertEqual(viewport.imageRect.minX, 24)
        XCTAssertEqual(viewport.imageRect.maxY, 576)
        viewport.fit()
        XCTAssertEqual(viewport.offset, .zero)
        XCTAssertTrue(viewport.isFitted)
    }

    func testResizeRefitsOnlyWhenFitModeIsActive() {
        var viewport = MermaidViewport(contentSize: CGSize(width: 2_000, height: 1_000))
        viewport.resize(CGSize(width: 800, height: 600))
        let fitted = viewport.scale
        viewport.resize(CGSize(width: 400, height: 300))
        XCTAssertLessThan(viewport.scale, fitted)
        viewport.zoom(to: 2)
        viewport.pan(CGSize(width: 70, height: -30))
        viewport.resize(CGSize(width: 900, height: 700))
        XCTAssertEqual(viewport.scale, 2)
        XCTAssertEqual(viewport.offset, CGSize(width: 70, height: -30))
    }

    func testZoomLimitsIgnoreInvalidValues() {
        var viewport = MermaidViewport(contentSize: CGSize(width: 2_000, height: 1_000))
        viewport.resize(CGSize(width: 800, height: 600))
        viewport.zoom(to: 100)
        XCTAssertEqual(viewport.scale, 8)
        viewport.zoom(to: .infinity)
        viewport.zoom(to: .nan)
        viewport.zoom(to: -1)
        XCTAssertEqual(viewport.scale, 8)
        viewport.zoom(to: 0.00001)
        XCTAssertEqual(viewport.scale, viewport.minimumScale)
    }
}

@MainActor
final class MermaidDiagramViewerTests: XCTestCase {
    func testRendererProducesVectorPDFAndRejectsInvalidSource() async throws {
        let image = try await MermaidVectorImage.render(source: "graph LR\nA[Start] --> B[Finish]", theme: .default)
        XCTAssertTrue(image.representations.contains { $0 is NSPDFImageRep })
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        do {
            _ = try await MermaidVectorImage.render(source: "not a mermaid diagram", theme: .default)
            XCTFail("Invalid Mermaid must fail rather than leave the previous image visible")
        } catch { }
    }

    func testCanceledRenderCannotPublishAnImage() async {
        let task = Task { try await MermaidVectorImage.render(source: "graph LR\nA --> B", theme: .default) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled render returned an image") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCanvasOwnsFocusAndEscapeAndRestoresPreviousResponder() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: window.contentLayoutRect)
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        container.addSubview(field)
        window.contentView = container
        window.makeFirstResponder(field)
        let canvas = MermaidCanvasView(frame: container.bounds)
        var closes = 0
        canvas.onClose = { closes += 1 }
        container.addSubview(canvas)
        XCTAssertTrue(window.firstResponder === canvas)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        canvas.keyDown(with: escape)
        XCTAssertEqual(closes, 1)
        canvas.removeFromSuperview()
        XCTAssertTrue(window.firstResponder === field)
    }
}
