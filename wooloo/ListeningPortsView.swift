import AppKit
import SwiftUI

/// The listening ports of a Space, as small `HTTP` tags at the end of its sidebar row. Hovering
/// shows the port; clicking opens it in the browser, forwarding it to this Mac first when the
/// Space runs on an SSH machine. The tag's color says whether it is forwarded.
struct SpacePortTags: View {
    @ObservedObject private var forwards = PortForwards.shared
    @Environment(\.woolooTypography) private var typography

    let ports: [ListeningPort]
    /// The Space's machine; nil is this Mac.
    let machine: HerdrMachineProfile?

    /// Tags shown before the rest fold into `+N`.
    static let visibleTags = 3

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ports.prefix(Self.visibleTags)) { port in
                SpacePortTag(port: port, machine: machine, state: state(of: port))
            }
            if ports.count > Self.visibleTags {
                let rest = ports.dropFirst(Self.visibleTags)
                Menu {
                    ForEach(Array(rest)) { port in
                        Button("Open :\(String(port.port)) (\(port.process))") {
                            SpacePortActions.open(port, machine: machine)
                        }
                    }
                } label: {
                    Text("+\(rest.count)")
                        .font(.system(size: typography.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(rest.map { ":\(String($0.port))" }.joined(separator: " "))
            }
        }
        .fixedSize()
    }

    private func state(of port: ListeningPort) -> PortForwards.State? {
        machine.flatMap { forwards.state(PortForwards.key(machine: $0, port: port)) }
    }
}

private struct SpacePortTag: View {
    @Environment(\.woolooTheme) private var theme
    @Environment(\.woolooTypography) private var typography

    let port: ListeningPort
    let machine: HerdrMachineProfile?
    let state: PortForwards.State?

    private var color: Color {
        switch state {
        case .active: theme.success
        case .starting: theme.warning
        case .failed: theme.error
        case nil: .secondary
        }
    }

    private var forwardedPort: Int? {
        if case .active(let local) = state { return local }
        return nil
    }

    var body: some View {
        Button { SpacePortActions.open(port, machine: machine) } label: {
            Text("HTTP")
                .font(.system(size: typography.caption, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(state == nil ? 0.25 : 0.6), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .contextMenu {
            Button("Open in Browser", systemImage: "safari") { SpacePortActions.open(port, machine: machine) }
            if let url = SpacePortActions.url(port, machine: machine, forwardedPort: forwardedPort) {
                Button("Copy URL", systemImage: "doc.on.doc") { AppActions.copy(url.absoluteString) }
            }
            if let machine {
                Divider()
                PortForwardActions(port: port, machine: machine)
            }
        }
    }

    private var tooltip: String {
        let port = String(port.port)
        let process = self.port.process.isEmpty ? "" : " · \(self.port.process)"
        guard let machine else {
            return "localhost:\(port)\(process)\nClick to open in the browser"
        }
        switch state {
        case .active(let local):
            return "Port \(port) on \(machine.label) → localhost:\(String(local))\(process)\nForwarded · click to open"
        case .starting:
            return "Port \(port) on \(machine.label)\(process)\nForwarding…"
        case .failed(let reason):
            return "Port \(port) on \(machine.label)\(process)\nForward failed: \(reason)\nClick to try again"
        case nil:
            return "Port \(port) on \(machine.label)\(process)\nNot forwarded · click to forward to this Mac and open"
        }
    }
}

struct PortForwardActions: View {
    let port: ListeningPort
    let machine: HerdrMachineProfile
    @ObservedObject private var forwards = PortForwards.shared

    var body: some View {
        let key = PortForwards.key(machine: machine, port: port)
        switch forwards.state(key) {
        case .active(let local):
            Button("Copy localhost:\(String(local))", systemImage: "doc.on.doc") {
                AppActions.copy("localhost:\(local)")
            }
            Button("Stop Forwarding", systemImage: "xmark.circle") { forwards.stop(key) }
        case .starting:
            Button("Cancel Forwarding", systemImage: "xmark.circle") { forwards.stop(key) }
        case .failed, nil:
            Button("Forward Port to This Mac", systemImage: "arrow.left.arrow.right") {
                Task { _ = await forwards.forward(port, on: machine) }
            }
        }
    }
}

@MainActor
enum SpacePortActions {
    /// Where the browser reaches `port`: directly on this Mac, or through its forward.
    static func url(_ port: ListeningPort, machine: HerdrMachineProfile?, forwardedPort: Int?) -> URL? {
        if machine == nil { return URL(string: "http://\(port.bind.host):\(port.port)/") }
        return forwardedPort.flatMap { URL(string: "http://127.0.0.1:\($0)/") }
    }

    static func open(_ port: ListeningPort, machine: HerdrMachineProfile?) {
        guard let machine else {
            if let url = url(port, machine: nil, forwardedPort: nil) { NSWorkspace.shared.open(url) }
            return
        }
        Task {
            guard let local = await PortForwards.shared.forward(port, on: machine),
                  let url = url(port, machine: machine, forwardedPort: local) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
