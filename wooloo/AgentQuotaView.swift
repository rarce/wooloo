import SwiftUI

/// The sidebar's QUOTAS section: how much of the Claude Code and Codex subscription limits have
/// been used, and when each window resets. They are read on the machine the explorer points at,
/// since that is where the agents run and are signed in. Collapsed, it shows each agent's most
/// used window. It reads them only while its window is active, and only for a machine the user
/// agreed to in the consent dialog, since it reads the agents' sign-ins and sends their tokens
/// to Anthropic and OpenAI; the button and the context menu both open that dialog.
struct AgentQuotaSection: View {
    @Environment(\.controlActiveState) private var activeState
    @AppStorage("AgentQuotasCollapsed") private var collapsed = true
    @StateObject private var activation = AgentQuotaActivation()

    let machine: HerdrMachineProfile?

    private var windowActive: Bool { activeState != .inactive }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SidebarSectionToggle(title: "QUOTAS", systemImage: "chart.bar.xaxis",
                                 help: "Claude and Codex Quotas", collapsed: $collapsed)
            if activation.consent.allows(machine) {
                AgentQuotaList(monitor: activation.acquired ?? AgentQuotaMonitor.shared(for: machine),
                               collapsed: collapsed)
            } else {
                AgentQuotaOptIn(machine: machine, collapsed: collapsed, enable: activation.requestEnable)
            }
        }
        .contextMenu {
            if activation.consent.allows(machine) {
                Button("Turn Off Quotas", action: activation.turnOff)
            } else {
                Button("Turn On Quotas…", action: activation.requestEnable)
            }
        }
        .alert(activation.request.map { AgentQuotaConsent.title(for: $0.machine) } ?? "",
               isPresented: Binding(get: { activation.request != nil },
                                    // Each button, Cancel also for Escape, settles the request itself.
                                    set: { _ in }),
               presenting: activation.request) { request in
            Button("Turn On") { activation.accept(request) }
            Button("Cancel", role: .cancel) { activation.cancel() }
        } message: { request in
            Text(AgentQuotaConsent.explanation(for: request.machine))
        }
        .onAppear { activation.show(machine: machine, windowActive: windowActive) }
        .onChange(of: machine) { _, machine in activation.show(machine: machine, windowActive: windowActive) }
        .onChange(of: windowActive) { _, active in activation.show(machine: machine, windowActive: active) }
        .onDisappear { activation.disappear() }
    }
}

/// What turning quotas on does, shown until the user agrees to it in the consent dialog.
private struct AgentQuotaOptIn: View {
    @Environment(\.woolooTypography) private var typography
    let machine: HerdrMachineProfile?
    let collapsed: Bool
    let enable: () -> Void

    private var place: String { machine.map { "on \($0.label)" } ?? "on this Mac" }

    var body: some View {
        if collapsed {
            Text("Off")
                .font(.system(size: typography.secondary))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shows how much of your Claude Code and Codex plans you have used. It reads their sign-ins "
                     + place + " and sends the tokens to Anthropic's and OpenAI's unofficial usage endpoints, "
                     + "which can change at any time.")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn On Quotas…", action: enable)
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
        }
    }
}

private struct AgentQuotaList: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @ObservedObject var monitor: AgentQuotaMonitor
    let collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !collapsed, let machine = monitor.machine {
                HStack(spacing: 5) {
                    Image(systemName: "network")
                    Text(machine.label).lineLimit(1)
                }
                .font(.system(size: typography.secondary))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .help("Read on \(machine.label) — \(machine.target)")
            }
            details
        }
    }

    @ViewBuilder private var details: some View {
        if monitor.states.isEmpty {
            Text(monitor.loaded ? "No Claude Code or Codex sign-in on \(monitor.machine?.label ?? "this Mac")"
                                : "Reading…")
                .font(.system(size: typography.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(collapsed ? 1 : 2)
                .padding(.horizontal, 8)
        } else if collapsed {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 10) {
                    ForEach(AgentProvider.allCases) { provider in
                        if let state = monitor.states[provider] {
                            summary(provider, state: state, now: context.date)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        } else {
            // Once a minute, for the reset countdowns and the age of old readings.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(AgentProvider.allCases) { provider in
                        if let state = monitor.states[provider] {
                            providerView(provider, state: state, now: context.date)
                        }
                    }
                }
            }
        }
    }

    /// The agent's most used window, which is the one that blocks it first.
    private func summary(_ provider: AgentProvider, state: AgentQuotaMonitor.State, now: Date) -> some View {
        let window = state.quota?.windows.max { $0.usedFraction(at: now) < $1.usedFraction(at: now) }
        let detail = window.map { "\($0.label) \(value($0.usedFraction(at: now), resetsAt: $0.resetsAt, now: now))" }
        let host = monitor.machine.map { "on \($0.label)" }
        return SidebarMiniMeter(label: provider.title, fraction: window?.usedFraction(at: now))
            .help([[provider.title, detail, host].compactMap { $0 }.joined(separator: " "), state.failure]
                .compactMap { $0 }.joined(separator: " — "))
    }

    private func providerView(_ provider: AgentProvider, state: AgentQuotaMonitor.State, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(state.failure == nil ? theme.success : state.quota == nil ? theme.error : theme.warning)
                    .frame(width: 6, height: 6)
                Text(provider.title)
                    .font(.system(size: typography.body, weight: .medium))
                if let plan = state.quota?.plan {
                    Text(plan)
                        .font(.system(size: typography.secondary))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let quota = state.quota, state.failure != nil || quota.fromLog,
                   now.timeIntervalSince(quota.capturedAt) >= 60 {
                    Text("\(HostStats.uptimeText(now.timeIntervalSince(quota.capturedAt))) ago")
                        .font(.system(size: typography.secondary, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: typography.metric(20))
            .help(state.failure ?? (state.quota?.fromLog == true ? "Read from Codex's latest session log" : ""))

            if let quota = state.quota {
                ForEach(quota.windows) { window in
                    let used = window.usedFraction(at: now)
                    SidebarMeter(label: window.label, fraction: used,
                                 value: value(used, resetsAt: window.resetsAt, now: now), labelWidth: 64)
                }
            } else if let failure = state.failure {
                Text(failure)
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
    }

    /// `40% · 2h 13m`: the share used and the time left until the window resets.
    private func value(_ used: Double, resetsAt: Date?, now: Date) -> String {
        let percent = "\(Int((used * 100).rounded()))%"
        guard let resetsAt, resetsAt > now else { return percent }
        return "\(percent) · \(HostStats.uptimeText(resetsAt.timeIntervalSince(now)))"
    }
}
