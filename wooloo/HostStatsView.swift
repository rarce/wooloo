import SwiftUI

/// The sidebar's HOST section: the machine the explorer points at and its CPU, memory, disk
/// and uptime; collapsed, only CPU and memory. It samples only while its window is active.
struct HostStatsSection: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme
    @Environment(\.controlActiveState) private var activeState
    @StateObject private var monitor = HostStatsMonitor()
    @AppStorage("HostStatsCollapsed") private var collapsed = false

    let machine: HerdrMachineProfile?
    /// The selected Space's folder on that machine, for its volume's free space.
    let directory: String?

    private var wantedTarget: HostStatsMonitor.Target? {
        activeState == .inactive ? nil : .init(machine: machine, directory: directory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SidebarSectionToggle(title: "HOST", systemImage: "gauge.with.dots.needle.33percent",
                                 help: "Host Stats", collapsed: $collapsed)
            if collapsed {
                summary
            } else {
                header
                details
            }
        }
        .onAppear { update(wantedTarget) }
        .onChange(of: wantedTarget) { _, target in update(target) }
        .onDisappear { monitor.stop() }
    }

    private func update(_ target: HostStatsMonitor.Target?) {
        if let target { monitor.start(target) } else { monitor.stop() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(monitor.failure != nil ? theme.error : monitor.stats == nil ? Color.secondary : theme.success)
                .frame(width: 6, height: 6)
            Image(systemName: machine == nil ? "desktopcomputer" : "network")
                .font(.system(size: typography.secondary))
                .foregroundStyle(.secondary)
            Text(monitor.stats?.sample.hostname ?? machine?.label ?? "Local")
                .font(.system(size: typography.body, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let uptime = monitor.stats?.sample.uptime {
                Text("up \(HostStats.uptimeText(uptime))")
                    .font(.system(size: typography.secondary, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: typography.metric(22))
        .help(machine.map { "\($0.label) — \($0.target)" } ?? "This Mac")
    }

    @ViewBuilder private var summary: some View {
        if let stats = monitor.stats {
            HStack(spacing: 10) {
                SidebarMiniMeter(label: "CPU", fraction: stats.cpuUsage)
                SidebarMiniMeter(label: "MEM", fraction: stats.memoryFraction)
            }
            .padding(.horizontal, 8)
            .help([stats.sample.hostname, monitor.failure].compactMap { $0 }.joined(separator: " — "))
        } else {
            Text(monitor.failure ?? "Reading…")
                .font(.system(size: typography.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder private var details: some View {
        if let failure = monitor.failure, monitor.stats == nil {
            Text(failure)
                .font(.system(size: typography.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .padding(.horizontal, 8)
        } else if let stats = monitor.stats {
            VStack(alignment: .leading, spacing: 5) {
                SidebarMeter(label: "CPU", fraction: stats.cpuUsage,
                             value: (stats.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                                 + (stats.sample.cpuCount.map { " / \($0) cores" } ?? ""))
                if let used = stats.sample.memoryUsed, let total = stats.sample.memoryTotal {
                    SidebarMeter(label: "MEM", fraction: stats.memoryFraction,
                                 value: "\(HostStats.bytesText(used)) / \(HostStats.bytesText(total))")
                }
                if let free = stats.sample.diskFree {
                    SidebarMeter(label: "DISK", fraction: stats.diskUsedFraction,
                                 value: "\(HostStats.bytesText(free)) free")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        } else {
            Text("Reading…")
                .font(.system(size: typography.secondary))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
        }
    }
}

/// A sidebar section's collapsing title row, shared by HOST and QUOTAS.
struct SidebarSectionToggle: View {
    @Environment(\.woolooTypography) private var typography

    let title: String
    let systemImage: String
    /// What the section shows, for the tooltip: "Show …" / "Hide …".
    let help: String
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            collapsed.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: typography.secondary, weight: .semibold))
                    .tracking(0.7)
                Image(systemName: systemImage)
                    .font(.system(size: typography.secondary))
                Spacer(minLength: 0)
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: typography.caption, weight: .semibold))
                    .frame(width: 23)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(help)" : "Hide \(help)")
    }
}

/// A labelled usage bar in the sidebar, turning amber at 75% and red at 90%.
struct SidebarMeter: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme

    let label: String
    let fraction: Double?
    let value: String
    var labelWidth: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.system(size: typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: typography.secondary, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Self.color(for: fraction ?? 0, theme: theme))
                        .frame(width: geometry.size.width * (fraction ?? 0))
                }
            }
            .frame(height: 4)
            .padding(.leading, labelWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    static func color(for fraction: Double, theme: WoolooTheme) -> Color {
        fraction >= 0.9 ? theme.error : fraction >= 0.75 ? theme.warning : theme.accent
    }
}

/// A collapsed section's one-line bar: a label, a short bar filling the space it gets, and the
/// percentage.
struct SidebarMiniMeter: View {
    @Environment(\.woolooTypography) private var typography
    @Environment(\.woolooTheme) private var theme

    let label: String
    let fraction: Double?

    private var percent: String { fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "–" }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(SidebarMeter.color(for: fraction ?? 0, theme: theme))
                        .frame(width: geometry.size.width * (fraction ?? 0))
                }
            }
            .frame(height: 4)
            Text(percent)
                .font(.system(size: typography.secondary, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .frame(minHeight: typography.metric(18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fraction == nil ? label : "\(label) \(percent)%")
    }
}
