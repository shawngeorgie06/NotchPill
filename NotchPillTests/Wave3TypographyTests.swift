import AppKit
import Testing
@testable import NotchPill

@Suite("Small text readability on black")
struct Wave3TypographyTests {
    @Test("supporting and metadata text exceed 7:1 contrast on pure black")
    func smallTextContrast() {
        // White alpha over black produces this sRGB grey. Convert to linear
        // luminance before comparing; alpha itself is not a contrast ratio.
        for opacity in [NotchOpacity.secondary, NotchOpacity.tertiary] {
            let luminance = opacity <= 0.04045
                ? opacity / 12.92 : pow((opacity + 0.055) / 1.055, 2.4)
            #expect((luminance + 0.05) / 0.05 >= 7)
        }
    }

    @Test("caption digits and titles fit their controls at the smallest pill preference")
    func controlTypeFitsWithCompensation() {
        let scales: [CGFloat] = [1, NotchContentLayout.textCompensation(forUserScale: 0.7)]
        for scale in scales {
            let caption = NSFont.monospacedDigitSystemFont(ofSize: NotchType.mono * scale,
                                                         weight: .medium)
            let title = NSFont.systemFont(ofSize: NotchType.title * scale, weight: .semibold)
            #expect(caption.ascender - caption.descender + caption.leading <= NotchSpace.mark)
            #expect(title.ascender - title.descender + title.leading <= 28)

            // The widest reset-clock form must fit a half-width meter on the
            // compact 389pt canvas, with its normal insets, without shrinking.
            let reset = NSAttributedString(string: "session · 12:59 AM", attributes: [.font: caption])
            let meterTextWidth = (389 - NotchSpace.section * 2 - NotchSpace.snug) / 2
                - NotchSpace.base * 2
            #expect(reset.size().width <= meterTextWidth)
        }
    }
}
