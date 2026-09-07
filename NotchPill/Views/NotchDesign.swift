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
    /// The island's rim at full strength. The pill surfaces below draw it as
    /// a gradient; the HUDs, which have a real edge all the way round, use it
    /// flat.
    static let pillStroke = Color.white.opacity(NotchOpacity.rim)

    static let settingsHeader = LinearGradient(
        colors: [
            Color(red: 0.18, green: 0.20, blue: 0.32),
            Color(red: 0.10, green: 0.11, blue: 0.16),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Painted depth for the opaque island.
///
/// Not a material. The fill stays `Color.black` so the surface reads as one
/// object with the hardware cutout above it, and wallpaper never shows
/// through. What made it read as a hole rather than a surface was the rim: a
/// 0.5pt line at 7% white is a void's edge, not an object's.
enum NotchIslandChrome {
    /// Hairline at the top, the full rim at the bottom curve.
    ///
    /// On notched hardware the pill's top edge *is* the seam with the cutout,
    /// and a uniformly brighter line there reads as a crack under the notch.
    /// The light still comes from above; it just does not land on the seam.
    static var rim: LinearGradient {
        LinearGradient(colors: [.white.opacity(NotchOpacity.hairline),
                                .white.opacity(NotchOpacity.rim)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The sheen along a real top edge, gone within `NotchSpace.base`. Only
    /// drawn where the pill has one — the free-floating island on a display
    /// with no notch. The caller clips it to the surface.
    static var highlight: some View {
        LinearGradient(colors: [.white.opacity(NotchOpacity.highlight), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: NotchSpace.base)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Black notch / pill surface with rounded bottom corners and a painted rim.
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
                // A rounded top is a real edge; a square one is the seam.
                if topRadius > 0 {
                    NotchIslandChrome.highlight.clipShape(shape)
                }
            }
            .overlay {
                shape.stroke(NotchIslandChrome.rim, lineWidth: 0.5)
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
                if !hasPhysicalNotch {
                    NotchIslandChrome.highlight.clipShape(shape)
                }
            }
            .overlay {
                // The rim matters more without a notch: the pill has no
                // hardware edge to borrow, so this is the only thing separating
                // it from a dark wallpaper.
                shape.stroke(NotchIslandChrome.rim, lineWidth: 0.5)
            }
    }
}
