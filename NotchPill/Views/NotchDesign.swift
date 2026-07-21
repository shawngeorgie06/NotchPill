import SwiftUI

/// Shared tokens for the settings window (notch overlay uses plain black).
enum NotchDesign {
    static let accent = Color(red: 0.52, green: 0.62, blue: 1.0)
    static let accentMuted = Color(red: 0.52, green: 0.62, blue: 1.0).opacity(0.35)
    static let devReadyGreen = Color(red: 0.35, green: 0.88, blue: 0.55)
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

    var body: some View {
        NotchShape(bottomRadius: bottomRadius)
            .fill(Color.black)
            .overlay {
                NotchShape(bottomRadius: bottomRadius)
                    .stroke(NotchDesign.pillStroke, lineWidth: 0.5)
            }
    }
}
