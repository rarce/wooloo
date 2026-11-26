import SwiftUI

/// Shows usage and reset times for agents on the explorer's machine. Polls while the window is
/// active and that machine has quota consent. Collapsed, it shows each agent's most used window.
struct AgentQuotaSection: View {
    @Environment(\.controlActiveState) private var activeState
    @AppStorage("AgentQuotasCollapsed") private var collapsed = true
    @AppStorage("AgentQuotasInSelectedSpaceOnly") private var spaceOnly = false
    @StateObject private var activation: AgentQuotaActivation
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme

    let machine: HerdrMachineProfile?
    let spaceProviders: Set<AgentProvider>

    @MainActor
    init(machine: HerdrMachineProfile?, spaceProviders: Set<AgentProvider> = [],
         activation: AgentQuotaActivation? = nil) {
        self.machine = machine
        self.spaceProviders = spaceProviders
        _activation = StateObject(wrappedValue: activation ?? AgentQuotaActivation())
    }

    private var windowActive: Bool { activeState != .inactive }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                SidebarSectionToggle(title: "QUOTAS", systemImage: "chart.bar.xaxis",
                                     help: "Claude, Codex and Antigravity Quotas", collapsed: $collapsed)
                if activation.consent.allows(machine) {
                    Button { spaceOnly.toggle() } label: {
                        Image(systemName: spaceOnly ? "line.3.horizontal.decrease.circle.fill"
                                                   : "line.3.horizontal.decrease.circle")
                            .font(.system(size: typography.secondary))
                            .foregroundStyle(spaceOnly ? theme.accent : .secondary)
                            .frame(width: 23, height: typography.metric(22))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(spaceOnly ? "Show All Quotas" : "Show Quotas for Agents in This Space")
                    .accessibilityLabel("Quotas for Agents in This Space")
                    .accessibilityAddTraits(spaceOnly ? .isSelected : [])
                }
            }
            if activation.consent.allows(machine) {
                AgentQuotaList(monitor: activation.acquired ?? AgentQuotaMonitor.shared(for: machine),
                               collapsed: collapsed, spaceProviders: spaceOnly ? spaceProviders : nil)
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
                Text("Shows usage for Claude Code, Codex and Antigravity "
                     + place + ". Review how each quota is read before turning it on.")
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
    @State private var collapsedProviders: Set<AgentProvider> = []
    let collapsed: Bool
    let spaceProviders: Set<AgentProvider>?

    private var providers: [AgentProvider] {
        AgentProvider.allCases.filter { spaceProviders?.contains($0) ?? true }
    }

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
        if providers.isEmpty || providers.allSatisfy({ monitor.states[$0] == nil }) {
            Text(providers.isEmpty ? "No agents with quota support in this Space"
                 : !monitor.loaded ? "Reading…"
                 : spaceProviders != nil ? "No agent quotas available in this Space"
                 : "No agent quotas available on \(monitor.machine?.label ?? "this Mac")")
                .font(.system(size: typography.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(collapsed ? 1 : 2)
                .padding(.horizontal, 8)
        } else if collapsed {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        summaries(now: context.date)
                    }
                    VStack(spacing: 2) {
                        summaries(now: context.date)
                    }
                }
                .padding(.horizontal, 8)
            }
        } else {
            // Once a minute, for the reset countdowns and the age of old readings.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(providers) { provider in
                        if let state = monitor.states[provider] {
                            providerView(provider, state: state, now: context.date)
                        }
                    }
                }
            }
        }
    }

    private func summaries(now: Date) -> some View {
        ForEach(providers) { provider in
            if let state = monitor.states[provider] {
                summary(provider, state: state, now: now)
            }
        }
    }

    /// The agent's most used window, which is the one that blocks it first.
    private func summary(_ provider: AgentProvider, state: AgentQuotaMonitor.State, now: Date) -> some View {
        let window = state.quota?.windows.max { $0.usedFraction(at: now) < $1.usedFraction(at: now) }
        let detail = window.map { window in
            [window.group, window.label, value(window.usedFraction(at: now), resetsAt: window.resetsAt, now: now)]
                .compactMap { $0 }.joined(separator: " ")
        }
        let host = monitor.machine.map { "on \($0.label)" }
        return SidebarMiniMeter(label: provider.title, fraction: window?.usedFraction(at: now),
                                minimumBarWidth: typography.metric(12))
            .help([[provider.title, detail, host].compactMap { $0 }.joined(separator: " "), state.failure]
                .compactMap { $0 }.joined(separator: " — "))
    }

    private func providerView(_ provider: AgentProvider, state: AgentQuotaMonitor.State, now: Date) -> some View {
        let isCollapsed = collapsedProviders.contains(provider)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                if isCollapsed { collapsedProviders.remove(provider) }
                else { collapsedProviders.insert(provider) }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(state.failure == nil ? theme.success : state.quota == nil ? theme.error : theme.warning)
                        .frame(width: 6, height: 6)
                    if isCollapsed {
                        summary(provider, state: state, now: now)
                    } else {
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
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: typography.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: typography.metric(20))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .help(state.failure ?? (state.quota?.fromLog == true ? "Read from Codex's latest session log"
                                                                : isCollapsed ? "Show quota details" : "Hide quota details"))

            if !isCollapsed, let quota = state.quota {
                ForEach(Array(quota.windows.enumerated()), id: \.element.id) { index, window in
                    if let group = window.group, index == 0 || quota.windows[index - 1].group != group {
                        Text(group)
                            .font(.system(size: typography.secondary))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    let used = window.usedFraction(at: now)
                    SidebarMeter(label: window.label, fraction: used,
                                 value: value(used, resetsAt: window.resetsAt, now: now), labelWidth: 64)
                }
            } else if !isCollapsed, let failure = state.failure {
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
