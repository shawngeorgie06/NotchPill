import AppKit
import Foundation

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
        var cardWeights: [String: Double]
        var logLines: String
        var home: String
        /// One line per attached display, plus where the pill decided the notch
        /// is. Every "it's in the wrong place" report needs this and none of
        /// them arrive with it: the pill is centred on a notch rect derived
        /// from the built-in screen, and on a multi-display desk that rect can
        /// be in a coordinate space the report otherwise never mentions.
        var displays: [String] = []
        var notchDescription: String = "unknown"
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

        if !f.cardWeights.isEmpty {
            let weights = f.cardWeights
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
                .joined(separator: " ")
            out += "\nCard widths     \(weights)"
        }

        out += "\nNotch            \(f.notchDescription)"
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
        if settings.showExpandedCI { cards.append("ci") }
        if settings.showExpandedMedia { cards.append("media") }
        if settings.showExpandedActiveApp { cards.append("activeApp") }
        if settings.showExpandedCalendar { cards.append("calendar") }
        if settings.showExpandedTimer { cards.append("timer") }
        if settings.showExpandedVolume { cards.append("volume") }
        if settings.showExpandedSystemStats { cards.append("systemStats") }
        if settings.showExpandedBattery { cards.append("battery") }
        if settings.showExpandedShelf { cards.append("shelf") }
        if settings.showExpandedClock { cards.append("clock") }

        let facts = Facts(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "unknown",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            accessibilityGranted: AccessibilityAuthorization.isGranted,
            hooksInstalled: AgentHooks.isInstalled(),
            ghAvailable: CIStatusProvider.hasGH,
            enabledCards: cards,
            notchScale: settings.notchScale,
            cardWeights: settings.cardWeights,
            logLines: LogStore.shared.formatted,
            home: NSHomeDirectory(),
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
                guard let geo = NotchGeometry.current() else {
                    return "none found — overlay hidden"
                }
                let r = geo.notchRect
                let onMain = geo.screen == NSScreen.main
                // `source` is the line that matters when someone reports the
                // pill hanging detached from the notch: "assumed" means these
                // numbers are a 200pt guess rather than a reading, and the
                // pill's neck and shoulders are built on them.
                let note = geo.source == .assumed
                    ? " · ASSUMED (could not read the display — pill may not line up)"
                    : " · measured"
                return String(format: "%.0f,%.0f %.0f×%.0f on %@display%@",
                              r.origin.x, r.origin.y, r.width, r.height,
                              onMain ? "main " : "secondary ", note)
            }())
        return build(facts)
    }
}
