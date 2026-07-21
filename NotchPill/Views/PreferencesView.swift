import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var timer = TimerStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Form {
                    Section("Collapsed Preview") {
                        Toggle("Show collapsed preview", isOn: $settings.showCollapsedActivity)
                        Toggle("Media", isOn: $settings.showCollapsedMedia)
                            .disabled(!settings.showCollapsedActivity)
                        Toggle("Timer", isOn: $settings.showCollapsedTimer)
                            .disabled(!settings.showCollapsedActivity)
                        Toggle("Live clock", isOn: $settings.showCollapsedClock)
                            .disabled(!settings.showCollapsedActivity)
                        Toggle("App switch banner", isOn: $settings.showCollapsedAppSwitch)
                            .disabled(!settings.showCollapsedActivity)
                        Toggle("Next calendar event", isOn: $settings.showCalendar)
                            .disabled(!settings.showCollapsedActivity)
                        Toggle("File shelf count", isOn: $settings.showFileShelf)
                            .disabled(!settings.showCollapsedActivity)
                        Toggle("CPU & memory", isOn: $settings.showCollapsedSystemStats)
                            .disabled(!settings.showCollapsedActivity)
                        Toggle("Battery", isOn: $settings.showCollapsedBattery)
                            .disabled(!settings.showCollapsedActivity)
                    }

                    Section("Expanded Pill") {
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

                    Section("Timer") {
                        if let active = timer.active, active.isActive {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                HStack {
                                    Text(StatusFormatting.countdown(active.remaining(at: context.date)))
                                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                    Spacer()
                                    Button("Cancel") { timer.cancel() }
                                }
                            }
                        } else {
                            Text("Start a countdown to show it in the notch.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            ForEach([5, 10, 15, 25], id: \.self) { minutes in
                                Button("\(minutes)m") { timer.start(minutes: minutes) }
                            }
                        }
                    }

                    Section("General") {
                        Toggle("Launch at login", isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        ))
                    }
                }
                .formStyle(.grouped)
                .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 460, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("NotchPill")
                    .font(.system(size: 20, weight: .semibold))
                Text("Choose what appears in the collapsed and expanded notch")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
