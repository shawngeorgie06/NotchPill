import SwiftUI

/// Shared tokens for the settings window (notch overlay uses plain black).
enum NotchDesign {
    static let accent = Color(red: 0.52, green: 0.62, blue: 1.0)
    static let accentMuted = Color(red: 0.52, green: 0.62, blue: 1.0).opacity(0.35)
    /// Calm semantic accents for the dark notch surface. They stay readable
    /// without the fluorescent green/orange blocks used by the older peeks.
    static let devReadyGreen = Color(red: 0.39, green: 0.78, blue: 0.57)
    static let devReadyAmber = Color(red: 0.90, green: 0.63, blue: 0.31)
    /// Claude's terracotta, for the drawn Claude mark.
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let pillStroke = Color.white.opacity(0.07)

    static let settingsHeader = LinearGradient(
        colors: [
            Color(red: 0.18, green: 0.20, blue: 0.32),
            Color(red: 0.10, green: 0.11, blue: 0.16),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Plain black notch / pill surface with rounded bottom corners.
struct PillSurface: View {
    var bottomRadius: CGFloat
    /// Non-zero only where there is no hardware notch to tuck into.
    var topRadius: CGFloat = 0

    private var shape: NotchShape {
        NotchShape(bottomRadius: bottomRadius, topRadius: topRadius)
    }

    var body: some View {
        shape
            .fill(Color.black)
            .overlay {
                shape.stroke(NotchDesign.pillStroke, lineWidth: 0.5)
            }
    }
}

/// The expanded, floating silhouette. The notch and the lower pill share a
/// single path so the surface feels like it grows out of the hardware rather
/// than two panels snapping together.
struct ExpandedPillSurface: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let progress: CGFloat
    var hasPhysicalNotch: Bool = true

    private var shape: ExpandedNotchShape {
        ExpandedNotchShape(notchWidth: notchWidth, notchHeight: notchHeight,
                           progress: progress, hasPhysicalNotch: hasPhysicalNotch)
    }

    var body: some View {
        shape
            .fill(Color.black)
            .overlay {
                // The hairline matters more without a notch: the pill has no
                // hardware edge to borrow, so this is the only thing separating
                // it from a dark wallpaper.
                shape.stroke(NotchDesign.pillStroke, lineWidth: 0.5)
            }
    }
}
