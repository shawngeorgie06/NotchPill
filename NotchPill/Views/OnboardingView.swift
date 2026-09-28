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
                    .padding(20)
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
        VStack(alignment: .leading, spacing: 14) {
            Text(flow.current.title)
                .font(.system(size: 22, weight: .semibold))
            Text(flow.current.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            stepContent
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.current {
        case .welcome: welcomeStep
        case .accessibility: accessibilityStep
        case .agentHooks: agentHooksStep
        case .cards: cardsStep
        case .finish: finishStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("hand.point.up.left", "Hover the notch",
                   "It expands into a deck of full-width cards.")
            bullet("bell.badge", "It taps you when something needs you",
                   "A finished build, or an agent waiting on an answer.")
            bullet("slider.horizontal.3", "Everything is optional",
                   "Turn cards off, change their order, or resize the pill.")
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 12) {
                Toggle("Live agents", isOn: $settings.showExpandedAgents)
                Toggle("Builds & tests", isOn: $settings.showExpandedCommands)
                Toggle("CI status", isOn: $settings.showExpandedCI)
                Toggle("Now playing", isOn: $settings.showExpandedMedia)
                Toggle("Active app", isOn: $settings.showExpandedActiveApp)
                Toggle("Clock", isOn: $settings.showExpandedClock)
            }
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
                   "Cards, settings, updates and this guide all live there.")
            bullet("square.stack", "Card order",
                   "Settings → Card Order chooses which pages appear first.")
            Button("Open Settings") { PreferencesController.shared.show() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Pieces

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(done: Bool, doneText: String, todoText: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? NotchDesign.devReadyGreen : Color.secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("NotchPill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("STEP \(flow.index + 1) OF \(flow.steps.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.6))
                }
                ProgressView(value: flow.progress)
                    .tint(.white)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .frame(height: 94)
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
            .tint(NotchDesign.accent)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private func refreshStatus() {
        accessibilityGranted = AccessibilityAuthorization.isGranted
        hooksInstalled = AgentHooks.isInstalled()
    }
}
