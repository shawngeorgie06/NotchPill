import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var timer = TimerStore.shared
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    collapsedSection
                    expandedSection
                    timerSection
                    devReadySection
                    shortcutsSection
                    updatesSection
                    generalSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 500, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Sections

    private var collapsedSection: some View {
        SettingsPanel(title: "Collapsed Preview", subtitle: "Chips below the notch on hover") {
            Toggle("Show collapsed preview", isOn: $settings.showCollapsedActivity)
            settingsGroup {
                Toggle("Media", isOn: $settings.showCollapsedMedia)
                Toggle("Timer", isOn: $settings.showCollapsedTimer)
                Toggle("Live clock", isOn: $settings.showCollapsedClock)
                Toggle("App switch banner", isOn: $settings.showCollapsedAppSwitch)
                Toggle("Next calendar event", isOn: $settings.showCalendar)
                Toggle("File shelf count", isOn: $settings.showFileShelf)
                Toggle("CPU & memory", isOn: $settings.showCollapsedSystemStats)
                Toggle("Battery", isOn: $settings.showCollapsedBattery)
            }
            .disabled(!settings.showCollapsedActivity)
            Text("Browser tabs beside the notch stay clickable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var expandedSection: some View {
        SettingsPanel(title: "Expanded Pill", subtitle: "Cards when you hover the notch") {
            Toggle("Now playing", isOn: $settings.showExpandedMedia)
            Toggle("Timer", isOn: $settings.showExpandedTimer)
            Toggle("Active app", isOn: $settings.showExpandedActiveApp)
            Toggle("Next calendar event", isOn: $settings.showExpandedCalendar)
            Toggle("Volume", isOn: $settings.showExpandedVolume)
            Toggle("Clock", isOn: $settings.showExpandedClock)
            Toggle("CPU & memory", isOn: $settings.showExpandedSystemStats)
            Toggle("Battery", isOn: $settings.showExpandedBattery)
            Toggle("File shelf", isOn: $settings.showExpandedShelf)
        }
    }

    private var timerSection: some View {
        SettingsPanel(title: "Timer", subtitle: "Quick countdowns in the notch") {
            if let active = timer.active, active.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Text(StatusFormatting.countdown(active.remaining(at: context.date)))
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(NotchDesign.accent)
                        Spacer()
                        Button("Cancel") { timer.cancel() }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                Text("Pick a duration to start.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach([5, 10, 15, 25], id: \.self) { minutes in
                    Button("\(minutes)m") { timer.start(minutes: minutes) }
                        .buttonStyle(TimerPillButtonStyle())
                }
            }
        }
    }

    private var devReadySection: some View {
        SettingsPanel(title: "Dev Ready Pings", subtitle: "Peek the notch when a terminal or IDE finishes") {
            Toggle("Show dev-ready notifications", isOn: $settings.showDevReadyPings)
            Toggle("Play a sound", isOn: $settings.devReadyPlaySound)
                .disabled(!settings.showDevReadyPings)
            Toggle("Reply to agents from the notch", isOn: $settings.agentReplyEnabled)
            HStack {
                Text("Peek duration")
                Spacer()
                Text("\(Int(settings.devReadyDuration))s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.devReadyDuration, in: 4...20, step: 1)
                .disabled(!settings.showDevReadyPings)
            HStack(spacing: 8) {
                Button("Test Ping") {
                    NotificationCenter.default.post(name: .notchPillTestDevReady, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotchDesign.devReadyGreen)
                .disabled(!settings.showDevReadyPings)
                Button("Test Multiple") {
                    NotificationCenter.default.post(name: .notchPillTestMultipleDevReady, object: nil)
                }
                .buttonStyle(.bordered)
                .disabled(!settings.showDevReadyPings)
                Button("Copy Command") {
                    let cmd = "~/Projects/NotchPill/Scripts/notify-notchpill.sh \"Done\" \"Review output\" Cursor com.todesktop.230313mzl4w4u92 Composer"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                }
                .buttonStyle(.bordered)
            }
            Text("Run after an agent finishes, or add to your Cursor hook.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsSection: some View {
        SettingsPanel(title: "Keyboard Shortcuts", subtitle: "Hover the notch first — no click needed") {
            VStack(alignment: .leading, spacing: 10) {
                shortcutRow(keys: "Space", detail: "Play / pause")
                shortcutRow(keys: "←  →", detail: "Previous / next track")
                shortcutRow(keys: "↑  ↓", detail: "System volume")
            }
            Button("Open Accessibility Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(NotchDesign.accent)
            Text("Enable NotchPill under Privacy & Security → Accessibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var updatesSection: some View {
        SettingsPanel(title: "Updates", subtitle: "Install new versions without leaving the app") {
            Toggle("Check for updates automatically", isOn: $settings.autoCheckUpdates)
            if let update = updates.available {
                HStack(spacing: 10) {
                    Text("Version \(update.version) is available.")
                        .font(.callout)
                    Spacer()
                    Button("Update Now") { UpdateInstaller.install(update) }
                        .buttonStyle(.borderedProminent)
                        .tint(NotchDesign.accent)
                }
            } else {
                HStack(spacing: 10) {
                    Text(updates.isChecking
                         ? "Checking…"
                         : "You're on version \(updates.currentVersion).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updates.check(force: true) }
                        .buttonStyle(.bordered)
                        .disabled(updates.isChecking)
                }
            }
            if let error = updates.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var generalSection: some View {
        SettingsPanel(title: "General", subtitle: nil) {
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
            Button("Reset All Settings to Defaults") {
                settings.resetToDefaults()
            }
            .foregroundStyle(.red)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            NotchDesign.settingsHeader
            HStack(alignment: .bottom, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("NotchPill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Your notch, upgraded")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
            .padding(.top, 22)
        }
        .frame(height: 108)
    }

    private func shortcutRow(keys: String, detail: String) -> some View {
        HStack(spacing: 12) {
            KeyCap(label: keys)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(.leading, 8)
    }
}

// MARK: - Settings components

private struct SettingsPanel<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                }
        }
    }
}

private struct TimerPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? NotchDesign.accentMuted : NotchDesign.accent.opacity(0.2))
            }
            .foregroundStyle(NotchDesign.accent)
    }
}

private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    }
            }
    }
}
