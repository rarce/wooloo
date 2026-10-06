import SwiftUI

/// Theme picker for Herdr's `[theme]` section with a color preview of each built-in theme.
struct ThemeSettingsView: View {
    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var theme
    @Binding var name: String
    @Binding var autoSwitch: Bool
    @Binding var lightName: String
    @Binding var darkName: String

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)]

    private var selectedID: String { XherdrTheme.canonicalName(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose a shared palette for the sidebar, tabs, editor, and terminals.")
                .font(.system(size: typography.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            section("Dark", themes: XherdrTheme.all.filter(\.isDark))
            section("Light", themes: XherdrTheme.all.filter { !$0.isDark })

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Follow macOS light/dark appearance", isOn: $autoSwitch)
                    .font(.system(size: typography.body, weight: .medium))
                Text("Herdr switches when the host terminal's appearance changes; xherdr follows macOS.")
                    .font(.system(size: typography.secondary))
                    .foregroundStyle(theme.subtext)
                if autoSwitch {
                    HStack(spacing: 18) {
                        picker("Light appearance", selection: $lightName, themes: XherdrTheme.all.filter { !$0.isDark })
                        picker("Dark appearance", selection: $darkName, themes: XherdrTheme.all.filter(\.isDark))
                    }
                }
            }
        }
    }

    private func section(_ title: String, themes: [XherdrTheme]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: typography.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(themes) { theme in
                    Button { name = theme.id } label: {
                        ThemeCard(theme: theme, isSelected: theme.id == selectedID)
                    }
                    .buttonStyle(.plain)
                    .help("Use \(theme.name) (\(theme.id))")
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(theme.id == selectedID ? [.isSelected] : [])
                }
            }
        }
    }

    private func picker(_ title: String, selection: Binding<String>, themes: [XherdrTheme]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: typography.secondary, weight: .medium))
            Picker(title, selection: Binding(
                get: { selection.wrappedValue.isEmpty ? "" : XherdrTheme.canonicalName(selection.wrappedValue) },
                set: { selection.wrappedValue = $0 }
            )) {
                Text("Automatic").tag("")
                Divider()
                ForEach(themes) { theme in Text(theme.name).tag(theme.id) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A small mock of the app in a theme's colors: title bar, sidebar, and terminal output.
struct ThemeCard: View {
    let theme: XherdrTheme
    let isSelected: Bool

    private func c(_ hex: UInt32, _ opacity: Double = 1) -> Color { XherdrTheme.color(hex, opacity: opacity) }

    @Environment(\.xherdrTypography) private var typography
    @Environment(\.xherdrTheme) private var interfaceTheme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Text(theme.name)
                    .font(.system(size: typography.secondary,
                                  weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? interfaceTheme.accent : interfaceTheme.subtext.opacity(0.5))
                    .font(.system(size: typography.body))
            }
        }
        .padding(10)
        .background(isSelected ? interfaceTheme.accent.opacity(0.1) : interfaceTheme.contentBackground,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isSelected ? interfaceTheme.accent : interfaceTheme.text.opacity(isHovered ? 0.3 : 0.12),
                    lineWidth: isSelected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([theme.herdr.red, theme.herdr.yellow, theme.herdr.green], id: \.self) { hex in
                    Circle().fill(c(hex)).frame(width: 5, height: 5)
                }
                Spacer(minLength: 6)
                RoundedRectangle(cornerRadius: 2).fill(c(theme.herdr.surface0)).frame(width: 30, height: 7)
                RoundedRectangle(cornerRadius: 2).fill(c(theme.herdr.accent, 0.35)).frame(width: 30, height: 7)
            }
            .padding(.horizontal, 6)
            .frame(height: 14)
            .background(c(theme.herdr.panel))

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarRow(active: true, dot: theme.herdr.yellow)
                    sidebarRow(active: false, dot: theme.herdr.green)
                    sidebarRow(active: false, dot: theme.herdr.blue)
                    Spacer(minLength: 0)
                }
                .padding(5)
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .background(c(theme.herdr.panel))

                VStack(alignment: .leading, spacing: 3) {
                    terminalLine([("❯ ", theme.herdr.accent), ("git status", theme.foreground)])
                    terminalLine([("modified: ", theme.ansi[3]), ("app.swift", theme.foreground)])
                    terminalLine([("+ added ", theme.ansi[2]), ("- removed", theme.ansi[1])])
                    Spacer(minLength: 0)
                    swatches(Array(theme.ansi[0..<8]))
                    swatches(Array(theme.ansi[8..<16]))
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(c(theme.background))
            }
        }
    }

    private func sidebarRow(active: Bool, dot: UInt32) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c(dot)).frame(width: 4, height: 4)
            RoundedRectangle(cornerRadius: 1).fill(c(theme.herdr.text, active ? 0.8 : 0.35)).frame(height: 3)
        }
        .padding(.horizontal, 3)
        .frame(height: 9)
        .background(active ? c(theme.herdr.surface0) : .clear, in: RoundedRectangle(cornerRadius: 2))
    }

    private func terminalLine(_ parts: [(String, UInt32)]) -> some View {
        parts.reduce(Text("")) { $0 + Text($1.0).foregroundColor(c($1.1)) }
            .font(.system(size: 8, design: .monospaced))
            .lineLimit(1)
    }

    private func swatches(_ colors: [UInt32]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, hex in
                RoundedRectangle(cornerRadius: 1.5).fill(c(hex)).frame(height: 7)
            }
        }
    }
}
