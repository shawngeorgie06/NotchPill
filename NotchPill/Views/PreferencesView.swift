import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Collapsed Preview") {
                Toggle("Show collapsed preview", isOn: $settings.showCollapsedActivity)
                Toggle("Media", isOn: $settings.showCollapsedMedia)
                    .disabled(!settings.showCollapsedActivity)
                Toggle("App switch banner", isOn: $settings.showCollapsedAppSwitch)
                    .disabled(!settings.showCollapsedActivity)
                Toggle("Next calendar event", isOn: $settings.showCalendar)
                    .disabled(!settings.showCollapsedActivity)
                Toggle("File shelf count", isOn: $settings.showFileShelf)
                    .disabled(!settings.showCollapsedActivity)
            }

            Section("Expanded Pill") {
                Toggle("Now playing", isOn: $settings.showExpandedMedia)
                Toggle("Active app", isOn: $settings.showExpandedActiveApp)
                Toggle("Volume", isOn: $settings.showExpandedVolume)
                Toggle("Clock", isOn: $settings.showExpandedClock)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
