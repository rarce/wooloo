import AppKit
import SwiftUI

/// Geometry comes from this window's real controls, including after a fullscreen transition.
/// This observer deliberately leaves the window delegate (and document close guard) alone.
@MainActor
final class IntegratedWindowChrome: ObservableObject {
    struct Metrics: Equatable {
        var controlsWidth: CGFloat = 90
        var minimumHeight: CGFloat = 28

        init(controlsWidth: CGFloat = 90, minimumHeight: CGFloat = 28) {
            self.controlsWidth = controlsWidth
            self.minimumHeight = minimumHeight
        }

        init(buttons: [CGRect], contentTop: CGFloat) {
            // Fullscreen may temporarily hide/move its controls to another native window.
            // Keep their usual space reserved when the system reveals them again.
            controlsWidth = max(90, buttons.map(\.maxX).max().map { ceil($0 + 12) } ?? 90)
            minimumHeight = buttons.map { contentTop - $0.minY + 6 }.max().map { ceil($0) } ?? 28
        }
    }

    @Published private(set) var metrics = Metrics()

    fileprivate func update(_ metrics: Metrics) {
        if self.metrics != metrics { self.metrics = metrics }
    }
}

struct IntegratedWindowObserver: NSViewRepresentable {
    let chrome: IntegratedWindowChrome

    func makeNSView(context: Context) -> WindowView { WindowView(chrome: chrome) }
    func updateNSView(_ view: WindowView, context: Context) { view.scheduleMeasurement() }
    static func dismantleNSView(_ view: WindowView, coordinator: ()) { view.uninstall() }

    final class WindowView: NSView {
        let chrome: IntegratedWindowChrome
        private weak var observedWindow: NSWindow?
        private var previousBackgroundDrag = false
        private var previousMovable = true
        private var mouseMonitor: Any?
        private var dragEndTimer: Timer?
        private var measurementPending = false

        init(chrome: IntegratedWindowChrome) {
            self.chrome = chrome
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            uninstall()
            guard let window else { return }
            observedWindow = window
            previousBackgroundDrag = window.isMovableByWindowBackground
            // WindowServer can start a titlebar drag before a local mouse-down monitor runs.
            // Publish the nonmovable policy before the click, then opt in only for our
            // explicit empty drag regions. Disabling background dragging alone is not enough.
            previousMovable = window.isMovable
            window.isMovable = false
            window.isMovableByWindowBackground = false
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleMouseEvent(event)
                }
                return event
            }
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            scheduleMeasurement()
        }

        func uninstall() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            finishMouseInteraction()
            NotificationCenter.default.removeObserver(self)
            observedWindow?.isMovable = previousMovable
            observedWindow?.isMovableByWindowBackground = previousBackgroundDrag
            observedWindow = nil
        }

        /// Keep automatic titlebar dragging disabled between events, including before the
        /// first click and after a tab drag. Only an explicit empty region opts into a drag.
        func handleMouseEvent(_ event: NSEvent) {
            guard let window = observedWindow, event.window === window else { return }
            if event.type == .leftMouseUp {
                finishMouseInteraction()
                return
            }
            guard event.type == .leftMouseDown else { return }
            finishMouseInteraction()
            guard previousMovable,
                  let frameView = window.contentView?.superview,
                  frameView.hitTest(frameView.convert(event.locationInWindow, from: nil)) is WindowDragView else { return }
            window.isMovable = true
            // A native window drag can consume mouse-up outside this window. Restore the
            // policy on physical release too, without monitoring or intercepting other apps.
            if NSEvent.pressedMouseButtons & 1 != 0 {
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    MainActor.assumeIsolated {
                        if NSEvent.pressedMouseButtons & 1 == 0 { self.finishMouseInteraction() }
                    }
                }
                dragEndTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        private func finishMouseInteraction() {
            dragEndTimer?.invalidate()
            dragEndTimer = nil
            observedWindow?.isMovable = false
        }

        @objc private func windowChanged(_ notification: Notification) { scheduleMeasurement() }

        func scheduleMeasurement() {
            guard !measurementPending else { return }
            measurementPending = true
            // Publishing while SwiftUI installs/layouts this view would invalidate that update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.measurementPending = false
                guard let window = self.observedWindow, let content = window.contentView else { return }
                let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> CGRect? in
                    guard let button = window.standardWindowButton(type), button.window === window,
                          !button.isHiddenOrHasHiddenAncestor else { return nil }
                    // Window coordinates are always bottom-up; NSHostingView is flipped.
                    return button.convert(button.bounds, to: nil)
                }
                self.chrome.update(.init(buttons: buttons, contentTop: content.convert(content.bounds, to: nil).maxY))
            }
        }
    }
}

/// A dedicated empty region: double click follows the system titlebar preference and never
/// creates a file. Buttons and tab drag/drop targets are sibling views, not children of this view.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    /// Weak window keys keep independent restore frames without retaining closed windows.
    private static let fillRestoreFrames = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let fallback = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 ? "Fill" : "Maximize"
            Self.performDoubleClick(in: window, preference: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? fallback)
        } else {
            window.performDrag(with: event)
        }
    }

    static func performDoubleClick(in window: NSWindow, preference: String) {
        switch preference {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        case "Fill":
            guard let screen = window.screen else { return }
            let target = screen.visibleFrame
            if window.frame.equalTo(target), let previous = fillRestoreFrames.object(forKey: window) {
                window.setFrame(previous.rectValue, display: true)
                fillRestoreFrames.removeObject(forKey: window)
            } else {
                fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
                window.setFrame(target, display: true)
            }
        default: window.performZoom(nil)
        }
    }
}
