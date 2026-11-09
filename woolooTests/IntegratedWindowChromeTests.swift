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

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testNativeTitlebarDraggingIsDisabledBeforeTheFirstClickForAllTabGroups() async throws {
        let drag = TabDragModel()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            HStack(spacing: 0) {
                WindowDragRegion().frame(width: 100)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array([TabDragGroup.terminal, .document, .search].enumerated()), id: \.offset) { index, group in
                            Button("Tab \(index)") {}
                                .buttonStyle(.plain)
                                .frame(width: 120, height: 30)
                                .contentShape(Rectangle())
                                .onMiddleClick {}
                                .tabReorder(group, id: "tab-\(index)", index: index, drag: drag) { _, _ in }
                        }
                    }
                }
                .frame(width: 360)
                WindowDragRegion()
            }
            .frame(height: 30)
            Spacer()
        }.ignoresSafeArea(.container, edges: .top)
            .background { IntegratedWindowObserver(chrome: IntegratedWindowChrome()) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.contentView = host
        try await settle(window)

        let observer = try XCTUnwrap(views(IntegratedWindowObserver.WindowView.self, in: host).first)
        let tabs = views(MiddleClickView.self, in: host)
        XCTAssertEqual(tabs.count, 3)
        for tab in tabs {
            let point = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
            XCTAssertGreaterThan(point.y, window.contentLayoutRect.maxY, "Exercise the native titlebar, not the content below it")
            let hit = try XCTUnwrap(host.hitTest(host.superview?.convert(point, from: nil) ?? point))
            XCTAssertFalse(window.isMovable, "WindowServer must see the disabled policy before mouse-down")
            observer.handleMouseEvent(try mouseEvent(.leftMouseDown, at: point, in: window))
            XCTAssertFalse(window.isMovable, "Native titlebar dragging must be disabled even when a SwiftUI ancestor allows it")
            observer.handleMouseEvent(try mouseEvent(.leftMouseUp, at: point, in: window))
            XCTAssertFalse(window.isMovable, "Release must keep the next titlebar gesture from moving the window")
            XCTAssertFalse(hit is WindowDragView)
        }
    }

    func testHeaderSharesTheNativeControlRowAndKeepsDragSpaceWhenSidebarIsHidden() async throws {
        let state = ContentWindowModel()
        state.showsSidebar = false
        state.showsFilesSidebar = false
        state.showsSearchTab = true
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
        let tab = try XCTUnwrap(views(MiddleClickView.self, in: content).first)
        let tabPoint = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: content.superview)
        let tabHit = try XCTUnwrap(content.hitTest(tabPoint))
        XCTAssertFalse(tabHit is WindowDragView)
        let observer = try XCTUnwrap(views(IntegratedWindowObserver.WindowView.self, in: content).first)
        let nativePoint = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
        observer.handleMouseEvent(try mouseEvent(.leftMouseDown, at: nativePoint, in: window))
        XCTAssertFalse(window.isMovable, "The real header must keep tab gestures out of native window dragging")
        observer.handleMouseEvent(try mouseEvent(.leftMouseUp, at: nativePoint, in: window))
        XCTAssertFalse(window.isMovable)

        let empty = try XCTUnwrap(regions.first { $0.bounds.width == 44 })
        let emptyPoint = empty.convert(NSPoint(x: empty.bounds.midX, y: empty.bounds.midY), to: nil)
        observer.handleMouseEvent(try mouseEvent(.leftMouseDown, at: emptyPoint, in: window))
        XCTAssertTrue(window.isMovable, "Explicit empty regions must still start native window drags")
        let other = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        observer.handleMouseEvent(try mouseEvent(.leftMouseUp, at: emptyPoint, in: other))
        XCTAssertTrue(window.isMovable, "Another window's release must not interrupt an explicit window drag")
        observer.handleMouseEvent(try mouseEvent(.leftMouseUp, at: emptyPoint, in: window))
        XCTAssertFalse(window.isMovable, "Empty-region release must disable automatic titlebar dragging again")
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

    func testObserverRestoresOriginallyImmovableWindowWhenMovedToAnotherWindow() async throws {
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        first.isMovable = false
        second.isMovable = true
        let observer = IntegratedWindowObserver.WindowView(chrome: IntegratedWindowChrome())
        let empty = WindowDragView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        first.contentView?.addSubview(empty)
        first.contentView?.addSubview(observer)
        try await settle(first)
        observer.handleMouseEvent(try mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 15), in: first))
        XCTAssertFalse(first.isMovable, "An explicit region cannot enable an originally immovable window")
        second.contentView?.addSubview(observer)
        try await settle(second)
        XCTAssertFalse(first.isMovable, "Detaching must preserve an originally immovable window")
        XCTAssertFalse(second.isMovable, "The new window must be protected before its first click")
        observer.removeFromSuperview()
        XCTAssertTrue(second.isMovable, "Detaching must restore the new window's original policy")
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
        first.isMovable = true
        second.isMovable = true
        first.isMovableByWindowBackground = true
        second.isMovableByWindowBackground = true
        let observer = IntegratedWindowObserver.WindowView(chrome: IntegratedWindowChrome())
        first.contentView?.addSubview(observer)
        try await settle(first)
        XCTAssertTrue(first.delegate === delegate, "Document close guards must keep their delegate")
        XCTAssertFalse(first.isMovable, "Disable server-side dragging before any mouse event")
        XCTAssertTrue(second.isMovable)
        XCTAssertFalse(first.isMovableByWindowBackground)
        XCTAssertTrue(second.isMovableByWindowBackground)
        let titlebar = NSPoint(x: first.frame.width / 2, y: first.frame.height - 10)
        observer.handleMouseEvent(try mouseEvent(.leftMouseDown, at: titlebar, in: second))
        XCTAssertFalse(first.isMovable)
        XCTAssertTrue(second.isMovable, "Another window's clicks must never change its policy")
        observer.handleMouseEvent(try mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100), in: first))
        XCTAssertFalse(first.isMovable)
        observer.handleMouseEvent(try mouseEvent(.leftMouseDown, at: titlebar, in: first))
        XCTAssertFalse(first.isMovable)
        observer.handleMouseEvent(try mouseEvent(.leftMouseUp, at: titlebar, in: first))
        XCTAssertFalse(first.isMovable)
        observer.removeFromSuperview()
        XCTAssertTrue(first.isMovable, "Dismantling during a gesture must restore the original policy")
        XCTAssertTrue(first.isMovableByWindowBackground)
        XCTAssertTrue(first.delegate === delegate)
    }
}
