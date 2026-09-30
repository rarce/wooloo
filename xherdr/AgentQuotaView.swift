import SwiftUI

/// The sidebar's QUOTAS section: how much of the Claude Code and Codex subscription limits have
/// been used, and when each window resets. They are read on the machine the explorer points at,
/// since that is where the agents run and are signed in. Collapsed, it shows each agent's most
/// used window. It reads them only while its window is active.
struct AgentQuotaSection: View {
    @Environment(\.controlActiveState) private var activeState
    @AppStorage("AgentQuotasCollapsed") private var collapsed = true
    @State private var acquired: AgentQuotaMonitor?

    let machine: HerdrMachineProfile?

    /// The machine to poll, or nil while nothing should be polled.
    private var wanted: HerdrMachineProfile?? {
        activeState == .inactive ? nil : .some(machine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SidebarSectionToggle(title: "QUOTAS", systemImage: "chart.bar.xaxis",
                                 help: "Claude and Codex Quotas", collapsed: $collapsed)
            AgentQuotaList(monitor: acquired ?? AgentQuotaMonitor.shared(for: machine), collapsed: collapsed)
        }
        .onAppear { update(wanted) }
        .onChange(of: wanted) { _, wanted in update(wanted) }
        .onDisappear { update(nil) }
    }

    private func update(_ wanted: HerdrMachineProfile??) {
        let next = wanted.map { AgentQuotaMonitor.shared(for: $0) }
        guard next !== acquired else { return }
        acquired?.release()
        next?.acquire()
        acquired = next
    }
}

private struct AgentQuotaList: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
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
