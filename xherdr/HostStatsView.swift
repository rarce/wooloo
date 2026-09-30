import SwiftUI

/// The sidebar's HOST section: the machine the explorer points at and its CPU, memory, disk
/// and uptime. It samples only while expanded and while its window is active.
struct HostStatsSection: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    @Environment(\.controlActiveState) private var activeState
    @StateObject private var monitor = HostStatsMonitor()
    @AppStorage("HostStatsCollapsed") private var collapsed = false

    let machine: HerdrMachineProfile?
    /// The selected Space's folder on that machine, for its volume's free space.
    let directory: String?

    private var wantedTarget: HostStatsMonitor.Target? {
        collapsed || activeState == .inactive ? nil : .init(machine: machine, directory: directory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                collapsed.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("HOST")
                        .font(.system(size: typography.secondary, weight: .semibold))
                        .tracking(0.7)
                    Image(systemName: "gauge.with.dots.needle.33percent")
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
            .help(collapsed ? "Show Host Stats" : "Hide Host Stats")

            header
            if !collapsed { details }
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

    @ViewBuilder private var details: some View {
        if let failure = monitor.failure, monitor.stats == nil {
            Text(failure)
                .font(.system(size: typography.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .padding(.horizontal, 8)
        } else if let stats = monitor.stats {
            VStack(alignment: .leading, spacing: 5) {
                meter("CPU", fraction: stats.cpuUsage,
                      value: stats.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                if !stats.sample.loadAverage.isEmpty {
                    Text("load " + stats.sample.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")
                         + (stats.sample.cpuCount.map { " · \($0) cores" } ?? ""))
                        .font(.system(size: typography.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 38)
                }
                if let used = stats.sample.memoryUsed, let total = stats.sample.memoryTotal {
                    meter("MEM", fraction: stats.memoryFraction,
                          value: "\(HostStats.bytesText(used)) / \(HostStats.bytesText(total))")
                }
                if let free = stats.sample.diskFree {
                    meter("DISK", fraction: stats.diskUsedFraction, value: "\(HostStats.bytesText(free)) free")
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

    private func meter(_ label: String, fraction: Double?, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.system(size: typography.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
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
                        .fill(color(for: fraction ?? 0))
                        .frame(width: geometry.size.width * (fraction ?? 0))
                }
            }
            .frame(height: 4)
            .padding(.leading, 38)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    private func color(for fraction: Double) -> Color {
        fraction >= 0.9 ? theme.error : fraction >= 0.75 ? theme.warning : theme.accent
    }
}
