import AppKit
import SwiftUI
import XCTest
@testable import wooloo

@MainActor
final class IntegratedWindowChromeTests: XCTestCase {
    private final class Delegate: NSObject, NSWindowDelegate {}

    private func makeWindow(state: ContentWindowModel, defaults: UserDefaults = .standard) -> (NSWindow, HerdrStore) {
        let store = HerdrStore()
        store.setDestinationEnabled(false)
        let host = NSHostingView(rootView: ContentView(herdr: store,
                                                       documents: WorkspaceDocumentStore(persistence: nil), window: state)
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, store)
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testHeaderSharesTheNativeControlRowAndKeepsDragSpaceWhenSidebarIsHidden() async throws {
        let state = ContentWindowModel()
        state.showsSidebar = false
        state.showsFilesSidebar = false
        let (window, store) = makeWindow(state: state)
        defer { window.close(); store.stop() }
        try await settle(window)
        let content = try XCTUnwrap(window.contentView)
        let regions = views(WindowDragView.self, in: content)
        let leading = try XCTUnwrap(regions.first)
        let rect = leading.convert(leading.bounds, to: nil)
        let controls = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            let button = try XCTUnwrap(window.standardWindowButton($0))
            return button.convert(button.bounds, to: nil)
        }
        XCTAssertLessThanOrEqual(abs(rect.maxY - window.frame.height), 1, "There must be no second titlebar row")
        XCTAssertLessThanOrEqual(rect.height, 44, "Native geometry must not expand the header to the window height")
        XCTAssertGreaterThanOrEqual(rect.maxX, try XCTUnwrap(controls.map(\.maxX).max()) + 10)
        XCTAssertTrue(controls.allSatisfy { $0.intersects(rect) }, "The native buttons share the custom header's row")
        XCTAssertTrue(regions.contains { $0.bounds.width == 44 }, "Overflow must leave a dedicated window drag target")
        XCTAssertTrue(views(TerminalPaneTabDropTargetView.self, in: content).allSatisfy {
            $0.convert($0.bounds, to: nil).minX >= rect.maxX
        }, "Pane detach targets cannot cover native window controls")
    }


    func testHeaderScalesWithTextAndKeepsNativeButtonsClearAtMinimumWindowWidth() async throws {
        let domain = "wooloo.chrome-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = ContentWindowModel(defaults: defaults)
        state.showsFilesSidebar = false
        let (window, store) = makeWindow(state: state, defaults: defaults)
        defer { window.close(); store.stop() }
        window.setContentSize(NSSize(width: 850, height: 600))
        for base in [11.0, 13.0, 17.0] {
            defaults.set(base, forKey: WoolooTypography.baseKey)
            try await settle(window)
            let content = try XCTUnwrap(window.contentView)
            let leading = try XCTUnwrap(views(WindowDragView.self, in: content).first)
            XCTAssertEqual(leading.bounds.height, WoolooTypography(base: base).metric(30), accuracy: 1)
            XCTAssertEqual(leading.bounds.width, 207, accuracy: 1)
        }
    }

    func testFillRestoresTheOriginalFrameAndNoneDoesNotMoveIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 850, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = window.frame
        WindowDragView.performDoubleClick(in: window, preference: "None")
        XCTAssertEqual(window.frame, original)
        WindowDragView.performDoubleClick(in: window, preference: "Fill")
        XCTAssertEqual(window.frame, try XCTUnwrap(window.screen).visibleFrame)
        WindowDragView.performDoubleClick(in: window, preference: "Fill")
        XCTAssertEqual(window.frame, original)
    }

    func testObserverKeepsDelegatesAndRestoresOnlyItsOwnWindow() async throws {
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let delegate = Delegate()
        first.delegate = delegate
        first.isMovableByWindowBackground = true
        second.isMovableByWindowBackground = true
        let observer = IntegratedWindowObserver.WindowView(chrome: IntegratedWindowChrome())
        first.contentView?.addSubview(observer)
        try await settle(first)
        XCTAssertTrue(first.delegate === delegate, "Document close guards must keep their delegate")
        XCTAssertFalse(first.isMovableByWindowBackground)
        XCTAssertTrue(second.isMovableByWindowBackground)
        observer.removeFromSuperview()
        XCTAssertTrue(first.isMovableByWindowBackground)
        XCTAssertTrue(first.delegate === delegate)
    }
}
