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
            // Only the explicit empty titlebar regions move the window; tabs keep their drags.
            window.isMovableByWindowBackground = false
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            scheduleMeasurement()
        }

        func uninstall() {
            NotificationCenter.default.removeObserver(self)
            observedWindow?.isMovableByWindowBackground = previousBackgroundDrag
            observedWindow = nil
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

/// Full-size content still occupies the native titlebar, whose automatic window drag is
/// independent of `isMovableByWindowBackground`. Keep tab gestures in the content view.
struct WindowInteractionRegion<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSView(context: Context) -> WindowInteractionView {
        let view = WindowInteractionView(rootView: AnyView(content.environment(\.self, context.environment)))
        view.sizingOptions = [.intrinsicContentSize]
        view.safeAreaRegions = []
        return view
    }

    func updateNSView(_ view: WindowInteractionView, context: Context) {
        view.rootView = AnyView(content.environment(\.self, context.environment))
    }
}

final class WindowInteractionView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
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
