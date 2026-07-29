import AppKit
import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var flow = OnboardingFlow()
    /// Recomputed whenever the window regains focus, because both grants are
    /// made *outside* this window — in System Settings, or by a script — and a
    /// step that still says "not set up" after you set it up reads as broken.
    @State private var accessibilityGranted = AccessibilityAuthorization.isGranted
    @State private var hooksInstalled = AgentHooks.isInstalled()
    @State private var hookOutput: String?
    @State private var installingHooks = false

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                stepBody
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(minWidth: 500, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(flow.current.title)
                .font(.system(size: 20, weight: .bold))
            Text(flow.current.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch flow.current {
            case .welcome: welcomeStep
            case .accessibility: accessibilityStep
            case .agentHooks: agentHooksStep
            case .cards: cardsStep
            case .finish: finishStep
            }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("hand.point.up.left", "Hover the notch",
                   "It expands into a row of cards.")
            bullet("bell.badge", "It taps you when something needs you",
                   "A finished build, or an agent waiting on an answer.")
            bullet("slider.horizontal.3", "Everything is optional",
                   "Turn cards off, resize them, or shrink the whole pill.")
        }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow(done: accessibilityGranted,
                      doneText: "Accessibility granted",
                      todoText: "Not granted yet")
            if !accessibilityGranted {
                Button("Open Accessibility Settings") {
                    AccessibilityAuthorization.requestSystemPrompt()
                }
                .buttonStyle(.borderedProminent)
                Text("Tick NotchPill in the list, then come back here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            shortcutHint()
        }
    }

    private var agentHooksStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow(done: hooksInstalled,
                      doneText: "At least one agent is wired up",
                      todoText: "No agent configured yet")
            HStack(spacing: 10) {
                Button(hooksInstalled ? "Run Setup Again" : "Set Up Agent Notifications") {
                    installingHooks = true
                    AgentHooks.install { output in
                        installingHooks = false
                        hookOutput = output
                        hooksInstalled = AgentHooks.isInstalled()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(installingHooks)
                if installingHooks {
                    ProgressView().controlSize(.small)
                }
            }
            if let hookOutput, !hookOutput.isEmpty {
                ScrollView {
                    Text(hookOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
            Text("Skip this if you don't use coding agents — nothing else depends on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cardsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Live agents", isOn: $settings.showExpandedAgents)
            Toggle("CI status", isOn: $settings.showExpandedCI)
            Toggle("Now playing", isOn: $settings.showExpandedMedia)
            Toggle("Active app", isOn: $settings.showExpandedActiveApp)
            Toggle("Clock", isOn: $settings.showExpandedClock)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Size")
                    Spacer()
                    Text("\(Int((settings.notchScale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.notchScale, in: 0.7...1.3)
                Text("Smaller pills show fewer cards, and the text scales up to stay readable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("menubar.arrow.up.rectangle", "The menu bar icon",
                   "Cards, widths, updates and this guide all live there.")
            bullet("arrow.left.and.right", "Card widths",
                   "Settings → Card Widths divides the row however you like.")
            Button("Open Settings") { PreferencesController.shared.show() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Pieces

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(NotchDesign.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(done: Bool, doneText: String, todoText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text(done ? doneText : todoText)
                .font(.subheadline.weight(.medium))
        }
    }

    private func shortcutHint() -> some View {
        Text("Without it, hovering still expands the notch — only the keyboard "
             + "shortcuts are unavailable.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            NotchDesign.settingsHeader
            VStack(alignment: .leading, spacing: 10) {
                Text("NotchPill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                ProgressView(value: flow.progress)
                    .tint(.white)
                    .frame(maxWidth: 220)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
        .frame(height: 84)
    }

    private var footer: some View {
        HStack {
            if !flow.isFirst {
                Button("Back") { flow.back() }
            }
            Spacer()
            // "Skip" only while there is something left to skip; on the last
            // step the primary button already means the same thing.
            if !flow.isLast {
                Button("Skip") { onFinish() }
            }
            // Deliberately no `.keyboardShortcut(.defaultAction)`. The guide
            // takes focus on first launch, and anything typing into the
            // frontmost window — an agent injecting a reply, a keystroke meant
            // for the terminal underneath — would otherwise walk the guide
            // forward or dismiss it. Observed, not hypothetical.
            Button(flow.isLast ? "Done" : "Continue") {
                if flow.isLast { onFinish() } else { flow.next() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.bar)
    }

    private func refreshStatus() {
        accessibilityGranted = AccessibilityAuthorization.isGranted
        hooksInstalled = AgentHooks.isInstalled()
    }
}
