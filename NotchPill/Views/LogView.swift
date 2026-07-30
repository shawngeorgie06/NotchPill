import AppKit
import SwiftUI

/// Live view of what the app has been doing.
///
/// The point is to answer "did it even try?" — the notch is a transient
/// overlay, so a peek that never appeared and a peek that appeared while you
/// were looking elsewhere are indistinguishable without this.
struct LogView: View {
    @ObservedObject private var log = LogStore.shared
    @State private var showErrorsOnly = false
    @State private var copiedReport = false

    private var visible: [LogEntry] {
        showErrorsOnly ? log.entries.filter { $0.level != .info } : log.entries
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
        HStack(spacing: 12) {
            Toggle("Problems only", isOn: $showErrorsOnly)
                .toggleStyle(.checkbox)
            Spacer()
            Text("\(log.entries.count) / \(LogStore.capacity)")
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
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(showErrorsOnly ? "No problems recorded." : "Nothing recorded yet.")
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
