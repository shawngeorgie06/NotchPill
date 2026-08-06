import AppKit
import SwiftUI

/// Live view of what the app has been doing.
///
/// The point is to answer "did it even try?" — the notch is a transient
/// overlay, so a peek that never appeared and a peek that appeared while you
/// were looking elsewhere are indistinguishable without this.
struct LogView: View {
    @ObservedObject private var log = LogStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showErrorsOnly = false
    @State private var copiedReport = false
    @State private var search = ""
    /// Nil means every category. A set rather than a single selection: chasing
    /// a jump means watching `focus` and `agents` together, and reading them in
    /// one interleaved timeline is the whole point.
    @State private var categories: Set<String> = []

    /// Categories actually present, so the filter never offers a dead option.
    private var availableCategories: [String] {
        Array(Set(log.entries.map(\.category))).sorted()
    }

    static func matches(_ entry: LogEntry, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return entry.message.lowercased().contains(query)
            || entry.category.lowercased().contains(query)
    }

    private var visible: [LogEntry] {
        log.entries.filter { entry in
            if showErrorsOnly, entry.level == .info { return false }
            if !categories.isEmpty, !categories.contains(entry.category) { return false }
            return Self.matches(entry, search: search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if visible.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            controls
            if availableCategories.count > 1 { categoryFilter }
            persistence
        }
        .padding(12)
    }

    /// The log is in memory, which is right when you can reproduce a problem
    /// and useless when it is happening on someone else's Mac. This is the
    /// escape hatch for the second case, and it stays off until asked.
    private var persistence: some View {
        HStack(spacing: 10) {
            Toggle("Keep a copy on disk", isOn: Binding(
                get: { settings.persistLog },
                set: { settings.persistLog = $0 }))
                .toggleStyle(.checkbox)
            Text(settings.persistLog
                 ? "Survives restarts. Owner-only, secrets redacted."
                 : "Off — the log is lost when NotchPill quits.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if settings.persistLog {
                Button("Show File") {
                    NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("all", active: categories.isEmpty) { categories.removeAll() }
                ForEach(availableCategories, id: \.self) { name in
                    chip(name, active: categories.contains(name)) {
                        if categories.contains(name) { categories.remove(name) }
                        else { categories.insert(name) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: active ? .semibold : .regular,
                              design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? NotchDesign.accent.opacity(0.22)
                                   : Color.secondary.opacity(0.12),
                            in: Capsule())
                .foregroundStyle(active ? NotchDesign.accent : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle("Problems only", isOn: $showErrorsOnly)
                .toggleStyle(.checkbox)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Spacer()
            // Both numbers, because a filter that hides everything and an empty
            // log look identical otherwise.
            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Clear") { log.clear() }
                .disabled(log.entries.isEmpty)
            // The report is the thing worth attaching to an issue; the raw log
            // alone leaves out every fact that usually explains the problem.
            Button(copiedReport ? "Copied" : "Copy Diagnostics") {
                let report = DiagnosticsReport.current()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                copiedReport = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedReport = false }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Hoisted out of the view builder: interpolation inside a ternary inside
    /// a `Text` inside an `HStack` is enough to stall the type-checker.
    private var countLabel: String {
        visible.count == log.entries.count
            ? "\(log.entries.count) / \(LogStore.capacity)"
            : "\(visible.count) of \(log.entries.count)"
    }

    private var empty: some View {
        VStack(spacing: 8) {
            // A filter that matches nothing and a log with nothing in it are
            // very different situations, and looked identical before.
            Text(log.entries.isEmpty
                 ? (showErrorsOnly ? "No problems recorded." : "Nothing recorded yet.")
                 : "No lines match the current filter.")
                .font(.headline)
            Text("The log starts empty at launch and fills as the notch does things — "
                 + "peeks arriving, agent scans, CI polls.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Follow the tail, which is what you want while reproducing
            // something. Scrolling up to read stops being useful the moment a
            // new line yanks you back, so this only fires on new arrivals.
            .onChange(of: visible.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(LogStore.lineFormatter.string(from: entry.date))
                .foregroundStyle(.tertiary)
            Text(entry.category)
                .foregroundStyle(NotchDesign.accent)
                .frame(width: 74, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
