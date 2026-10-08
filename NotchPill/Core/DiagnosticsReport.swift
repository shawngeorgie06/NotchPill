import AppKit
import Foundation
import EventKit

/// The text you attach to a bug report.
///
/// Assembled from facts the app already knows, because "it doesn't work" plus a
/// version number is not enough to act on: nearly every problem so far turned
/// on whether Accessibility was granted, whether the agent hooks pointed at the
/// app that is actually installed, or which cards were switched on.
///
/// This is going into a public issue tracker, so it is built to be pasteable
/// without a second thought: home paths are collapsed to `~`, and the log it
/// carries never held prompt or task text in the first place.
enum DiagnosticsReport {
    /// Everything the report needs, injected so the whole thing can be built
    /// and checked without a running app.
    struct Facts: Sendable {
        var appVersion: String
        var systemVersion: String
        var accessibilityGranted: Bool
        var hooksInstalled: Bool
        var ghAvailable: Bool
        var enabledCards: [String]
        var notchScale: Double
        var logLines: String
        var home: String
        /// One line per attached display, plus where the pill decided the notch
        /// is. Every "it's in the wrong place" report needs this and none of
        /// them arrive with it: the pill is centred on a notch rect derived
        /// from the built-in screen, and on a multi-display desk that rect can
        /// be in a coordinate space the report otherwise never mentions.
        var displays: [String] = []
        var notchDescription: String = "unknown"
        var integrationStates: [String] = []
    }

    /// Replaces the user's home directory with `~`. Their account name is the
    /// one piece of personal data that would otherwise be all over the paths.
    nonisolated static func redact(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    nonisolated static func build(_ f: Facts) -> String {
        var out = """
        NotchPill diagnostics
        =====================
        App             \(f.appVersion)
        macOS           \(f.systemVersion)
        Accessibility   \(f.accessibilityGranted ? "granted" : "NOT granted")
        Agent hooks     \(f.hooksInstalled ? "installed" : "not installed")
        gh CLI          \(f.ghAvailable ? "found" : "not found (CI card is off)")
        Pill size       \(Int((f.notchScale * 100).rounded()))%
        Cards on        \(f.enabledCards.isEmpty ? "none" : f.enabledCards.joined(separator: ", "))
        """

        out += "\nNotch            \(f.notchDescription)"
        if !f.integrationStates.isEmpty {
            out += "\n\nIntegrations\n------------\n" + f.integrationStates.joined(separator: "\n")
        }
        if !f.displays.isEmpty {
            out += "\n\nDisplays\n--------\n" + f.displays.joined(separator: "\n")
        }

        out += "\n\nLog\n---\n"
        out += f.logLines.isEmpty ? "(empty — nothing recorded since launch)" : f.logLines
        return redact(out, home: f.home)
    }

    /// Gathers the live facts. Everything expensive here is a local check.
    @MainActor
    static func current() -> String {
        let settings = AppSettings.shared
        var cards: [String] = []
        if settings.showExpandedAgents { cards.append("agents") }
        if settings.showExpandedCommands { cards.append("commands") }
        if settings.showExpandedCI { cards.append("ci") }
        if settings.showExpandedRecentActivity { cards.append("recent activity") }
        if settings.showClaudeUsage { cards.append("Claude usage") }
        if settings.showCursorUsage { cards.append("Cursor usage") }
        if settings.showClipboard { cards.append("clipboard") }
        if settings.showTerminal { cards.append("terminal") }
        if settings.showExpandedMedia { cards.append("media") }
        if settings.showExpandedActiveApp { cards.append("activeApp") }
        if settings.showExpandedCalendar { cards.append("calendar") }
        if settings.showExpandedTimer { cards.append("timer") }
        if settings.showExpandedVolume { cards.append("volume") }
        if settings.showExpandedSystemStats { cards.append("systemStats") }
        if settings.showExpandedBattery { cards.append("battery") }
        if settings.showExpandedShelf { cards.append("shelf") }
        if settings.showExpandedClock { cards.append("clock") }

        let home = NSHomeDirectory()
        func status(_ key: String, enabled: Bool) -> String {
            guard enabled else { return "off" }
            guard let record = IntegrationHealthStore.shared.records[key] else { return "not checked" }
            switch record.state {
            case .notChecked: return "not checked"
            case .ready: return "ready"
            case .toolMissing: return "tool missing"
            case .permissionNeeded: return "permission needed"
            case .signedOut: return "signed out"
            case .retrying: return "retrying"
            }
        }
        let calendarEnabled = (settings.showCalendar && settings.showCollapsedActivity)
            || settings.showExpandedCalendar
        var integrations = [
            "Claude Code CLI  \(status("claude", enabled: settings.showClaudeUsage))",
            "Cursor usage     \(status("cursor", enabled: settings.showCursorUsage))",
            "Codex usage      \(status("codex", enabled: settings.showExpandedAgents))",
            "GitHub CLI       \(settings.showExpandedCI && !CIStatusProvider.hasGH ? "tool missing" : status("ci", enabled: settings.showExpandedCI))",
            "Dev Ready        \(status("devReady", enabled: settings.showDevReadyPings))",
        ]
        if calendarEnabled {
            let authorization = EKEventStore.authorizationStatus(for: .event)
            let calendarStatus = authorization == .fullAccess ? "ready"
                : (authorization == .notDetermined ? "not checked" : "permission needed")
            integrations.append("Calendar         \(calendarStatus)")
        } else {
            integrations.append("Calendar         off")
        }
        let facts = Facts(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "unknown",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            accessibilityGranted: AccessibilityAuthorization.isGranted,
            hooksInstalled: AgentHooks.isInstalled(),
            ghAvailable: CIStatusProvider.hasGH,
            enabledCards: cards,
            notchScale: settings.notchScale,
            logLines: LogStore.shared.formatted,
            home: home,
            displays: NSScreen.screens.enumerated().map { index, screen in
                let f = screen.frame
                let v = screen.visibleFrame
                return String(
                    format: "[%d]%@ frame %.0f,%.0f %.0f×%.0f · visible %.0f,%.0f %.0f×%.0f "
                        + "· scale %.1f · safeTop %.0f",
                    index,
                    screen == NSScreen.main ? " main" : "",
                    f.origin.x, f.origin.y, f.width, f.height,
                    v.origin.x, v.origin.y, v.width, v.height,
                    screen.backingScaleFactor, screen.safeAreaInsets.top)
            },
            notchDescription: {
                guard let geo = NotchGeometry.current(mode: AppSettings.shared.resolvedDisplayMode) else {
                    return "none found — overlay hidden (mode: \(AppSettings.shared.notchDisplayMode))"
                }
                let r = geo.notchRect
                let onMain = geo.screen == NSScreen.main
                // `source` is the line that matters when someone reports the
                // pill hanging detached from the notch: "assumed" means these
                // numbers are a 200pt guess rather than a reading, and the
                // pill's neck and shoulders are built on them.
                let note: String
                switch geo.source {
                case .measured:
                    note = " · measured"
                case .assumed:
                    note = " · ASSUMED (could not read the display — pill may not line up)"
                case .external:
                    note = " · EXTERNAL (no cutout on this display — placed under the menu bar)"
                }
                return String(format: "%.0f,%.0f %.0f×%.0f on %@display%@",
                              r.origin.x, r.origin.y, r.width, r.height,
                              onMain ? "main " : "secondary ", note)
            }(),
            integrationStates: integrations)
        return build(facts)
    }
}
