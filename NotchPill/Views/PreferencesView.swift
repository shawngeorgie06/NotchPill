import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var timer = TimerStore.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var destinations = DestinationStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    displaySection
                    collapsedSection
                    expandedSection
                    shelfSection
                    tokenSection
                    cardShareSection
                    audioSection
                    systemHUDSection
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
                Toggle("Active agent", isOn: $settings.showCollapsedAgents)
                Toggle("App switch banner", isOn: $settings.showCollapsedAppSwitch)
                Toggle("Next calendar event", isOn: $settings.showCalendar)
                Toggle("Dropped file count", isOn: $settings.showFileShelf)
                    .help("A count only. The files themselves live on the "
                          + "expanded pill's File shelf card.")
                Toggle("CPU & memory", isOn: $settings.showCollapsedSystemStats)
                Toggle("Battery", isOn: $settings.showCollapsedBattery)
            }
            .disabled(!settings.showCollapsedActivity)
            Text("Browser tabs beside the notch stay clickable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One slider per card that is currently switched on, labelled with the
    /// share of the row it actually gets — the percentage moves as you drag
    /// *other* sliders too, which is the only honest way to show a proportion.
    private var cardShareSection: some View {
        let kinds = enabledCardKinds
        let shares = AppSettings.shares(for: kinds.map(\.0), weights: settings.cardWeights)
        return SettingsPanel(title: "Card Widths",
                             subtitle: "How the expanded row is divided") {
            if kinds.isEmpty {
                Text("No cards enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(kinds, id: \.0) { kind, label in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(label)
                            Spacer()
                            Text("\(Int(((shares[kind] ?? 0) * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { settings.cardWeight(kind) },
                                set: { settings.setCardWeight(kind, $0) }),
                            in: AppSettings.cardWeightRange)
                    }
                }
                HStack {
                    Spacer()
                    // Not "equal" any more: cards have per-kind starting
                    // widths, so this restores those rather than a flat split.
                    Button("Reset widths") { settings.cardWeights = [:] }
                        .buttonStyle(.link)
                        .disabled(settings.cardWeights.isEmpty)
                }
            }
        }
    }

    private var shelfSection: some View {
        SettingsPanel(title: "Shelf", subtitle: "Folders available when filing a dropped file") {
            HStack {
                Text("Pinned folders")
                Spacer()
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        destinations.pin(url)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
            }
            if destinations.pinned.isEmpty {
                Text("No pinned folders — recent Finder folders will still appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(destinations.pinned, id: \.self) { url in
                        HStack(spacing: 7) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                destinations.unpin(url)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .help(url.path)
                    }
                    .onMove { offsets, destination in
                        destinations.movePinned(from: offsets, to: destination)
                    }
                }
                .frame(height: min(CGFloat(destinations.pinned.count) * 30 + 8, 140))
            }
        }
    }

    /// Only cards that can actually appear — a slider for something switched
    /// off would do nothing and read as broken.
    private var enabledCardKinds: [(String, String)] {
        var out: [(String, String)] = []
        if settings.showExpandedAgents { out.append(("agents", "Live agents")) }
        if settings.showClaudeUsage { out.append(("claudeQuota", "Claude usage limits")) }
        if settings.showCursorUsage { out.append(("cursorQuota", "Cursor usage limits")) }
        if settings.showExpandedCI { out.append(("ci", "CI status")) }
        if settings.showExpandedRecentActivity { out.append(("recentAlerts", "Recent activity")) }
        if settings.showExpandedMedia { out.append(("media", "Now playing")) }
        if settings.showExpandedActiveApp { out.append(("activeApp", "Active app")) }
        if settings.showExpandedCalendar { out.append(("calendar", "Calendar")) }
        if settings.showExpandedTimer { out.append(("timer", "Timer")) }
        if settings.showExpandedVolume { out.append(("volume", "Volume")) }
        if settings.showExpandedSystemStats { out.append(("systemStats", "CPU & memory")) }
        if settings.showExpandedBattery { out.append(("battery", "Battery")) }
        if settings.showExpandedShelf { out.append(("shelf", "File shelf")) }
        if settings.showClipboard { out.append(("clipboard", "Clipboard")) }
        if settings.showExpandedClock { out.append(("clock", "Clock")) }
        return out
    }

    private var sizeSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Size")
                Spacer()
                Text("\(Int((settings.notchScale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                // Getting back to the default by dragging is fiddly, and this is
                // the one setting where overshooting is very visible.
                Button("Reset") { settings.notchScale = 1.0 }
                    .buttonStyle(.link)
                    .disabled(settings.notchScale == 1.0)
            }
            Slider(value: $settings.notchScale,
                   in: AppSettings.notchScaleRange,
                   step: 0.05)
            Text("Scales the whole expanded pill. The hover area follows the physical notch and does not change.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Separate from the pill's Size slider on purpose: that one scales the
    /// hover cards, while this only raises the ceiling a dictated caption may
    /// grow into. How much you want to read before pasting is personal, and it
    /// is the one thing that trades screen space for not having to trust an
    /// ellipsis.
    private var captionSizeSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Caption size")
                Spacer()
                Text("\(Int((settings.captionScale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Reset") { settings.captionScale = 1.0 }
                    .buttonStyle(.link)
                    .disabled(settings.captionScale == 1.0)
            }
            Slider(value: $settings.captionScale,
                   in: AppSettings.captionScaleRange,
                   step: 0.1)
            Text("How large a dictated caption may grow before it truncates. "
                 + "Wider and taller shows more of what you said; the peek never "
                 + "exceeds your screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var displaySection: some View {
        SettingsPanel(title: "Display", subtitle: "Which screen the pill appears on") {
            Picker("Show the pill on", selection: $settings.notchDisplayMode) {
                Text("Built-in display only")
                    .tag(NotchGeometry.DisplayMode.builtInOnly.rawValue)
                Text("Built-in, or an external display when it is unavailable")
                    .tag(NotchGeometry.DisplayMode.builtInThenExternal.rawValue)
                Text("Whichever display has the menu bar")
                    .tag(NotchGeometry.DisplayMode.mainDisplay.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text("An external display has no notch, so the pill is placed at the "
                 + "top centre under the menu bar. With the lid closed there is no "
                 + "built-in display at all, which is why the pill used to vanish "
                 + "while docked.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tokenSection: some View {
        SettingsPanel(title: "Token Usage",
                      subtitle: "Tokens used, on the Claude and Codex cards") {
            Toggle("Show tokens used", isOn: $settings.showTokenUsage)
            Picker("Count", selection: $settings.tokenUsagePeriod) {
                ForEach(TokenUsagePeriod.allCases, id: \.rawValue) { period in
                    Text(period.label).tag(period.rawValue)
                }
            }
            .pickerStyle(.menu)
            .disabled(!settings.showTokenUsage)
            Text("Counts prompt and generated tokens per model. Cache reads are "
                 + "excluded: they are re-counted on every request and outnumber "
                 + "the rest roughly thirty to one, which buries the real figure. "
                 + "Cursor is not included \u{2014} it meters requests, not tokens.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var expandedSection: some View {
        SettingsPanel(title: "Expanded Pill", subtitle: "Cards when you hover the notch") {
            sizeSlider
            Picker("Keep in focus", selection: $settings.pinnedActivityKind) {
                Text("Automatic").tag("")
                Text("Live agents").tag("agents")
                Text("Recent activity").tag("recentAlerts")
                Text("CI status").tag("ci")
                Text("Now playing").tag("media")
                Text("Timer").tag("timer")
            }
            .pickerStyle(.menu)
            Divider().padding(.vertical, 2)
            Toggle("Live agents", isOn: $settings.showExpandedAgents)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Claude usage limits", isOn: $settings.showClaudeUsage)
                Text("Reads the token Claude Code saved in your Keychain, so macOS "
                     + "will ask for permission the first time. Nothing is sent "
                     + "anywhere except Anthropic, and it stops working if you sign "
                     + "out of Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Cursor usage limits", isOn: $settings.showCursorUsage)
                Text("Reads the session token the Cursor app saved on this Mac. "
                     + "No prompt, nothing sent anywhere except Cursor, and it "
                     + "stops working if you sign out of Cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("CI status", isOn: $settings.showExpandedCI)
            Toggle("Recent activity", isOn: $settings.showExpandedRecentActivity)
            Toggle("Now playing", isOn: $settings.showExpandedMedia)
            Toggle("Timer", isOn: $settings.showExpandedTimer)
            Toggle("Active app", isOn: $settings.showExpandedActiveApp)
            Toggle("Next calendar event", isOn: $settings.showExpandedCalendar)
            Toggle("Volume", isOn: $settings.showExpandedVolume)
            Toggle("Clock", isOn: $settings.showExpandedClock)
            Toggle("CPU & memory", isOn: $settings.showExpandedSystemStats)
            Toggle("Battery", isOn: $settings.showExpandedBattery)
            Toggle("File shelf — drop files here", isOn: $settings.showExpandedShelf)
            Toggle("Clipboard — recent copies", isOn: $settings.showClipboard)
            Text("Kept in memory only and never written to disk. Passwords marked "
                 + "concealed by your password manager, and anything that looks "
                 + "like a key or token, are not remembered.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("The card that holds dropped files and files them into folders. "
                      + "Turn this on to use drag and drop.")
        }
    }

    private var timerSection: some View {
        SettingsPanel(title: "Focus & Timer", subtitle: "Keep a work block visible in the notch") {
            if let active = timer.active, active.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(active.isFocusSession ? "Focus session" : active.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(StatusFormatting.countdown(active.remaining(at: context.date)))
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(NotchDesign.accent)
                        }
                        Spacer()
                        Button(active.isFocusSession ? "End focus" : "Cancel") { timer.cancel() }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                Text("Pick a duration to start.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach([25, 50], id: \.self) { minutes in
                    Button("Focus \(minutes)m") { timer.startFocus(minutes: minutes) }
                        .buttonStyle(TimerPillButtonStyle())
                }
            }
            HStack(spacing: 8) {
                ForEach([5, 10, 15], id: \.self) { minutes in
                    Button("\(minutes)m") { timer.start(minutes: minutes) }
                        .buttonStyle(TimerPillButtonStyle())
                }
            }
        }
    }

    private var audioSection: some View {
        SettingsPanel(title: "Audio", subtitle: "Volume control from the notch") {
            Toggle("Change volume with the arrow keys", isOn: $settings.notchVolumeControl)
            Toggle("Allow changes while muted", isOn: $settings.volumeControlWhileMuted)
                .disabled(!settings.notchVolumeControl)
            Text(settings.volumeControlWhileMuted
                 ? "Pressing up while muted unmutes at the level you muted at; the arrows step normally after that."
                 : "While muted, the arrows leave the volume alone. Unmute from the menu bar or the mute key first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemHUDSection: some View {
        SettingsPanel(title: "System HUDs", subtitle: "Brief controls that appear below the notch") {
            Toggle("Volume", isOn: $settings.showVolumeHUD)
            Toggle("Brightness", isOn: $settings.showBrightnessHUD)
            Toggle("Microphone mute", isOn: $settings.showMicrophoneHUD)
            HStack {
                Text("Display duration")
                Spacer()
                Text(String(format: "%.1fs", settings.systemHUDDuration))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.systemHUDDuration,
                   in: AppSettings.systemHUDDurationRange,
                   step: 0.1)
            Text("Brightness is shown for the built-in display. Microphone mute is shown only when the current input device reports that state.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var devReadySection: some View {
        SettingsPanel(title: "Dev Ready Pings", subtitle: "Peek the notch when a terminal or IDE finishes") {
            Toggle("Show dev-ready notifications", isOn: $settings.showDevReadyPings)
            captionSizeSlider
            Toggle("Play a sound", isOn: $settings.devReadyPlaySound)
                .disabled(!settings.showDevReadyPings)
            HStack {
                Picker("Alert sound", selection: $settings.devReadySound) {
                    ForEach(DevReadySound.allCases) { sound in
                        Text(sound.label).tag(sound.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!settings.showDevReadyPings || !settings.devReadyPlaySound)
                Button("Preview") {
                    NSSound(named: settings.devReadySound)?.play()
                }
                .buttonStyle(.bordered)
                .disabled(!settings.showDevReadyPings || !settings.devReadyPlaySound)
            }
            Toggle("Reply to agents from the notch", isOn: $settings.agentReplyEnabled)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Come back to what I was doing after replying",
                       isOn: $settings.returnFocusAfterReply)
                    .disabled(!settings.agentReplyEnabled)
                Text("The agent's terminal has to come forward to receive the reply. "
                     + "With this on, focus returns to whatever you were looking at "
                     + "once the reply has been sent; with it off, you stay in the "
                     + "terminal to watch the answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Stay quiet while the Mac is locked", isOn: $settings.quietWhenLocked)
            Toggle("Remind me about what I missed", isOn: $settings.followUpReminders)
            Text("If a peek times out without you touching it, you get one reminder five minutes later — never a second. Dismissing a peek counts as dealing with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Ask before agents edit files", isOn: $settings.agentApprovalsEnabled)
            Text("Pauses Claude Code on Edit, Write and Bash and waits for Allow or Deny in the notch. Requires the agent hooks to be installed. If the notch is not answered within 30 seconds, the agent asks you itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
