import Foundation

/// Presentation metadata for the compact expanded-deck picker.
struct NotchDeckPickerItem: Equatable, Identifiable {
    let kind: String
    let title: String
    let symbolName: String

    var id: String { kind }

    static func items(for kinds: [String]) -> [NotchDeckPickerItem] {
        kinds.compactMap(item(for:))
    }

    static func item(for kind: String) -> NotchDeckPickerItem? {
        guard let title = ExpandedActivity.allKinds.first(where: { $0.kind == kind })?.label,
              let symbolName = symbols[kind] else { return nil }
        return NotchDeckPickerItem(kind: kind, title: kind == "codexQuota" ? "Codex usage" : title,
                                   symbolName: symbolName)
    }

    /// A stable, short position string instead of one control per page.
    /// Clamping keeps the control meaningful while a live deck is reconciling.
    static func positionLabel(page: Int, count: Int) -> String? {
        guard count > 1 else { return nil }
        return "\(min(max(page, 0), count - 1) + 1) / \(count)"
    }

    private static let symbols: [String: String] = [
        "agents": "terminal",
        "commands": "hammer.fill",
        "shelf": "folder.fill",
        "clipboard": "doc.on.clipboard",
        "terminal": "terminal",
        "openCodeUsage": "number",
        "codexQuota": "sparkles",
        "claudeQuota": "hexagon.fill",
        "cursorQuota": "cursorarrow",
        "ci": "checkmark.seal",
        "recentAlerts": "bell",
        "media": "music.note",
        "activeApp": "macwindow",
        "calendar": "calendar",
        "timer": "timer",
        "volume": "speaker.wave.2.fill",
        "systemStats": "gauge.with.dots.needle.50percent",
        "battery": "battery.100",
        "clock": "clock.fill"
    ]
}
