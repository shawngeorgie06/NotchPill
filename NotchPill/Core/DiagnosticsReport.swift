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
            home: NSHomeDirectory())
        return build(facts)
    }
}
