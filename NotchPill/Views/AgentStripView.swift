import SwiftUI

/// An agent's logo: the vendor's installed app icon, Anthropic's bundled mark
/// for Claude Code when the Claude app is not here, and an SF Symbol only as
/// a last resort.
struct AgentLogo: View {
    let agent: DevReadyAlert.KnownAgent?
    var size: CGFloat

    var body: some View {
        Group {
            if let icon = agent?.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let mark = agent?.bundledMark {
                Image(mark)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.08)
            } else {
                Image(systemName: agent?.symbol ?? "sparkles")
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(AgentTint.color(for: agent) ?? .white.opacity(NotchOpacity.primary))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The closed notch while an agent works: its logo on the left of the camera,
/// the chosen reading on the right. Laid out across the whole collapsed frame;
/// the middle, where the hardware notch is, stays empty.
struct AgentStripView: View {
    let strip: AgentStrip
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var wing: CGFloat { NotchContentLayout.agentStripWingWidth }
    private var logoSize: CGFloat { min(18, notchHeight * 0.56) }

    var body: some View {
        HStack(spacing: 0) {
            leadingWing
                .padding(.leading, 7)
                .frame(width: wing, height: notchHeight, alignment: .leading)
            Spacer(minLength: notchWidth)
            trailingWing
                .padding(.trailing, 5)
                .frame(width: wing, height: notchHeight, alignment: .trailing)
        }
        .frame(height: notchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var leadingWing: some View {
        ZStack(alignment: .topTrailing) {
            if strip.isWaiting || reduceMotion {
                AgentLogo(agent: strip.agent, size: logoSize)
            } else {
                // Breathing, not blinking: the strip is up for minutes at a
                // time and a hard flash would pull the eye every second.
                AgentLogo(agent: strip.agent, size: logoSize)
                    .phaseAnimator([false, true]) { logo, bright in
                        logo
                            .opacity(bright ? 1 : 0.55)
                            .scaleEffect(bright ? 1 : 0.9)
                    } animation: { _ in .easeInOut(duration: 1.1) }
            }
            if strip.isWaiting {
                Circle()
                    .fill(NotchDesign.devReadyAmber)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.black, lineWidth: 1.5))
                    .offset(x: 2, y: -2)
            }
        }
    }

    @ViewBuilder
    private var trailingWing: some View {
        switch strip.reading {
        case .limit(let window):
            limitReading(window)
        case .count(let count):
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
        case nil:
            EmptyView()
        }
    }

    private func limitReading(_ window: AgentStrip.UsageWindow) -> some View {
        let tint = window.isStale
            ? Color.white.opacity(NotchOpacity.tertiary)
            : AgentTint.meter(percent: window.percent,
                              agent: AgentTint.color(for: window.agent) ?? .white)
        return HStack(spacing: 2) {
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(window.percent) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 9, height: 9)
            Text("\(window.percent)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(window.isStale ? tint : .white.opacity(NotchOpacity.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var accessibilityText: String {
        let name: String
        switch strip.agent {
        case .claudeCode: name = "Claude Code"
        case .codex: name = "Codex"
        case .cursor: name = "Cursor"
        case .openCode: name = "OpenCode"
        case nil: name = "An agent"
        }
        var text = name + (strip.isWaiting ? " is waiting for you" : " is working")
        if strip.activeCount > 1 { text += ", \(strip.activeCount) agents active" }
        switch strip.reading {
        case .limit(let window):
            text += ", \(window.agent == strip.agent ? "its" : "closest") plan limit \(window.percent) percent used"
            if window.isStale { text += ", cached" }
        case .count, nil: break
        }
        return text
    }
}
