import AppKit

/// Resolves the physical notch rectangle on a built-in display, in AppKit
/// global (bottom-left origin) coordinates, and derives collapsed/expanded
/// overlay frames from it.
struct NotchGeometry {
    /// The screen that owns the notch (built-in display with a top safe-area inset).
    let screen: NSScreen
    /// Notch rectangle in global screen coordinates (matches the black cutout).
    let notchRect: CGRect
    /// Whether `notchRect` was measured from the display or assumed.
    ///
    /// This matters visually, not just diagnostically. The pill is drawn
    /// starting at the *lower edge of the hardware cutout* and never paints
    /// above it, so every one of its dimensions is trusted to match the real
    /// notch. When the measurement is a guess and the guess is wrong, the neck
    /// is the wrong width and the shoulders start at the wrong depth — the pill
    /// stops reading as an extension of the notch and starts reading as a
    /// separate panel hanging under it. That is the bug reported from another
    /// machine, and until now nothing anywhere said which of the two paths a
    /// given Mac had taken.
    var source: Source = .measured

    enum Source: String {
        case measured
        case assumed
        /// A display with no cutout at all — an external monitor. The pill is
        /// placed at top centre against the menu bar instead of being fitted to
        /// hardware, so nothing about it is a measurement of a notch.
        case external
    }

    /// Which display the overlay is allowed to live on.
    ///
    /// The pill only ever ran on the built-in display, which is right when the
    /// lid is open and useless the moment it is not: in clamshell the built-in
    /// screen leaves `NSScreen.screens` entirely, so the overlay hid itself and
    /// the app looked dead while docked.
    enum DisplayMode: String, CaseIterable {
        /// Built-in only. What every version before this did.
        case builtInOnly
        /// Built-in when it is there, otherwise the best external display.
        /// Nothing moves while the lid is open; clamshell gains a pill.
        case builtInThenExternal
        /// Wherever the menu bar is. For a desk where the monitor is primary
        /// and the laptop is off to one side.
        case mainDisplay
    }

    /// One display, as the selection rule needs to see it.
    ///
    /// Plain values rather than `NSScreen` so the rule can be exercised against
    /// clamshell and dual-monitor layouts that cannot be attached to CI.
    struct Candidate: Equatable {
        var isBuiltIn: Bool
        var isMain: Bool
        var frame: CGRect
        var visibleFrame: CGRect
        var safeTop: CGFloat
        var left: CGRect?
        var right: CGRect?

        init(isBuiltIn: Bool, isMain: Bool, frame: CGRect, visibleFrame: CGRect,
             safeTop: CGFloat, left: CGRect? = nil, right: CGRect? = nil) {
            self.isBuiltIn = isBuiltIn
            self.isMain = isMain
            self.frame = frame
            self.visibleFrame = visibleFrame
            self.safeTop = safeTop
            self.left = left
            self.right = right
        }
    }

    // Expanded overlay *design* dimensions (before shrink). The pill hangs below
    // the notch, wider than it. `expandedScale` shrinks the whole pill uniformly.
    static let expandedWidth: CGFloat = 720
    static let expandedHeight: CGFloat = 128
    // Uniform shrink of the expanded pill. Raising this expands the pill a little
    // and lifts the width cap that bounds how large the readability/text scale can
    // grow — i.e. bigger, more legible text. NOTE: this affects only the EXPANDED
    // pill; the hover *activation* zone is derived from the physical notch rect and
    // the collapsed size, so it is unchanged by this value.
    // Keep the hover panel compact: it needs room for the agent cards, but
    // should still read as an extension of the notch rather than a banner.
    static let expandedScale: CGFloat = 0.54
    /// Extra gap (render points) between the notch and the content, so the top
    /// row sits clear of the notch.
    static let contentTopGap: CGFloat = 10
    // Extra horizontal slack around the pill so the hosting window can host the
    // full expanded pill even when the notch is narrow.
    static let horizontalPadding: CGFloat = 40

    /// Screen-space menu bar strip (full width) — clicks here must reach status items.
    static func menuBarStrip(for screen: NSScreen) -> CGRect {
        let height = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        return CGRect(x: screen.frame.minX,
                      y: screen.frame.maxY - height,
                      width: screen.frame.width,
                      height: height)
    }

    /// Screen rects beside the physical notch where browsers (Chrome, Brave, Safari)
    /// render tabs. Clicks here must always pass through the overlay.
    static func browserFlankRects(for screen: NSScreen) -> [CGRect] {
        let inset = screen.safeAreaInsets.top
        guard inset > 0 else { return [] }

        var rects: [CGRect] = []
        if let left = screen.auxiliaryTopLeftArea, left.width > 1, left.height > 1 {
            rects.append(left)
        }
        if let right = screen.auxiliaryTopRightArea, right.width > 1, right.height > 1 {
            rects.append(right)
        }

        // Fallback when auxiliary areas are unavailable.
        if rects.isEmpty, let notch = notchRect(for: screen) {
            let frame = screen.frame
            let top = frame.maxY - inset
            rects.append(CGRect(x: frame.minX, y: top, width: notch.minX - frame.minX, height: inset))
            rects.append(CGRect(x: notch.maxX, y: top, width: frame.maxX - notch.maxX, height: inset))
        }

        // Unified browser tab bars extend below the menu bar band.
        let tabBarExtension: CGFloat = 52
        return rects.map { rect in
            CGRect(x: rect.minX,
                   y: rect.minY - tabBarExtension,
                   width: rect.width,
                   height: rect.height + tabBarExtension)
        }
    }

    static func browserFlankRects(for geometry: NotchGeometry) -> [CGRect] {
        browserFlankRects(for: geometry.screen)
    }

    static func pointIsInBrowserFlank(_ point: NSPoint, on screen: NSScreen) -> Bool {
        browserFlankRects(for: screen).contains { $0.contains(point) }
    }

    /// True when `notchRect` describes real hardware.
    ///
    /// The pill is shaped like the cutout it grows out of — square top corners,
    /// a neck at the cutout's exact width, shoulders flaring below it. That
    /// shape only makes sense if there is a cutout above it to disappear into.
    /// On a display with no notch there is nothing above it, and the same
    /// drawing reads as a black slab hanging in free space under the menu bar.
    var hasPhysicalNotch: Bool { source == .measured }

    /// Finds the built-in screen the overlay should live on.
    ///
    /// The test below is `safeAreaInsets.top > 0`, which is a **menu bar**
    /// test, not a notch test — every built-in display reports a top inset for
    /// the menu bar whether or not it has a cutout. So this returns a geometry
    /// on notch-less Macs too, and it always did; the difference is that the
    /// notch rect it carries is then the assumed one, and callers now have
    /// `hasPhysicalNotch` to tell the two apart instead of drawing hardware
    /// that is not there.
    static func current(mode: DisplayMode = .builtInThenExternal) -> NotchGeometry? {
        let screens = NSScreen.screens
        let candidates = screens.map { screen in
            Candidate(isBuiltIn: isBuiltIn(screen),
                      isMain: screen == NSScreen.main,
                      frame: screen.frame,
                      visibleFrame: screen.visibleFrame,
                      safeTop: screen.safeAreaInsets.top,
                      left: screen.auxiliaryTopLeftArea,
                      right: screen.auxiliaryTopRightArea)
        }
        guard let choice = choose(candidates, mode: mode),
              screens.indices.contains(choice.index) else { return nil }
        return NotchGeometry(screen: screens[choice.index],
                             notchRect: choice.rect,
                             source: choice.source)
    }

    /// Picks the display and the rect to hang the pill from.
    ///
    /// Built-in always wins when it qualifies, in every mode that allows it, so
    /// plugging in a monitor never moves a pill that is already where the user
    /// expects it. Only when there is no usable built-in display — clamshell,
    /// or a Mac mini — does an external one come into play.
    static func choose(_ candidates: [Candidate],
                       mode: DisplayMode) -> (index: Int, rect: CGRect, source: Source)? {
        func builtIn() -> (Int, CGRect, Source)? {
            for (index, candidate) in candidates.enumerated() {
                guard candidate.isBuiltIn, candidate.safeTop > 0 else { continue }
                guard let resolved = resolveNotch(inFrame: candidate.frame,
                                                  safeTop: candidate.safeTop,
                                                  left: candidate.left,
                                                  right: candidate.right) else { continue }
                return (index, resolved.rect, resolved.source)
            }
            return nil
        }

        func external(preferMain: Bool) -> (Int, CGRect, Source)? {
            let usable = candidates.enumerated().filter { $0.element.frame.width > 0 }
            guard !usable.isEmpty else { return nil }
            let picked = (preferMain ? usable.first { $0.element.isMain } : nil)
                ?? usable.first { $0.element.isMain }
                ?? usable.first { !$0.element.isBuiltIn }
                ?? usable.first!
            return (picked.offset, placeholderNotch(for: picked.element), .external)
        }

        switch mode {
        case .builtInOnly:
            return builtIn().map { ($0.0, $0.1, $0.2) }
        case .builtInThenExternal:
            if let found = builtIn() { return (found.0, found.1, found.2) }
            return external(preferMain: true).map { ($0.0, $0.1, $0.2) }
        case .mainDisplay:
            // A built-in main display still gets its real notch measured.
            if let main = candidates.enumerated().first(where: { $0.element.isMain }),
               main.element.isBuiltIn, main.element.safeTop > 0,
               let resolved = resolveNotch(inFrame: main.element.frame,
                                           safeTop: main.element.safeTop,
                                           left: main.element.left,
                                           right: main.element.right) {
                return (main.offset, resolved.rect, resolved.source)
            }
            if let found = external(preferMain: true) { return (found.0, found.1, found.2) }
            return builtIn().map { ($0.0, $0.1, $0.2) }
        }
    }

    /// Where to hang the pill on a display with no cutout.
    ///
    /// Centred at the top, as wide as a notch would be, and as deep as that
    /// display's menu bar so the pill still emerges from under it rather than
    /// floating in the content area. A secondary display with no menu bar of
    /// its own reports no inset, so a standard bar height stands in.
    static func placeholderNotch(for candidate: Candidate) -> CGRect {
        let measuredInset = candidate.frame.maxY - candidate.visibleFrame.maxY
        let inset: CGFloat
        if candidate.safeTop > 0 {
            inset = candidate.safeTop
        } else if measuredInset >= 8 {
            inset = measuredInset
        } else {
            inset = standardMenuBarHeight
        }
        let width: CGFloat = 200
        return CGRect(x: candidate.frame.midX - width / 2,
                      y: candidate.frame.maxY - inset,
                      width: width,
                      height: inset)
    }

    /// macOS menu bar height on a display without a notch.
    static let standardMenuBarHeight: CGFloat = 24

    /// True when the screen is the internal display (as opposed to an external
    /// monitor that might also report a safe-area inset).
    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    /// Computes the notch rect from the two auxiliary top areas that flank it.
    private static func notchRect(for screen: NSScreen) -> CGRect? {
        resolvedNotch(for: screen)?.rect
    }

    static func resolvedNotch(for screen: NSScreen) -> (rect: CGRect, source: Source)? {
        resolveNotch(inFrame: screen.frame,
                     safeTop: screen.safeAreaInsets.top,
                     left: screen.auxiliaryTopLeftArea,
                     right: screen.auxiliaryTopRightArea)
    }

    /// The rule on its own, so the awkward inputs can be fed to it directly.
    ///
    /// Two things were wrong here, and together they put the pill off to the
    /// right of the screen under a black bar.
    ///
    /// It read the auxiliary areas' *widths* and assumed each was flush to a
    /// screen edge, instead of reading the edges it actually wanted. And it
    /// accepted whatever came out as long as the width was positive — so one
    /// degenerate area (macOS hands back an empty or zero-width one in some
    /// configurations) produced a "notch" running to the right edge of the
    /// display. The pill centres on that rect and is sized from it, which is a
    /// black bar, off to the right, in one step.
    ///
    /// A notch is a small gap near the middle of the top edge. Anything that
    /// is not that is not a measurement, and the centred fallback is better
    /// than a confident wrong answer.
    static func notchRect(inFrame frame: CGRect,
                          safeTop: CGFloat,
                          left: CGRect?,
                          right: CGRect?) -> CGRect? {
        resolveNotch(inFrame: frame, safeTop: safeTop, left: left, right: right)?.rect
    }

    /// The same rule, saying which branch it took.
    ///
    /// The assumed branch is a real guess — 200 points wide because that is
    /// close to a 14"/16" Pro — and on a Mac whose notch is not that, every
    /// dimension the pill derives from it is wrong in a way that shows. It used
    /// to be indistinguishable from a measurement from the outside, including
    /// in the diagnostics report, which is why a "the pill is floating" report
    /// had nothing to check against.
    static func resolveNotch(inFrame frame: CGRect,
                             safeTop: CGFloat,
                             left: CGRect?,
                             right: CGRect?) -> (rect: CGRect, source: Source)? {
        guard safeTop > 0, frame.width > 0 else { return nil }

        if let left, let right,
           left.width > 1, left.height > 1,
           right.width > 1, right.height > 1 {
            // The edges facing the notch — not the widths.
            let width = right.minX - left.maxX
            let candidate = CGRect(x: left.maxX,
                                   y: frame.maxY - safeTop,
                                   width: width,
                                   height: safeTop)
            if isPlausibleNotch(candidate, in: frame) { return (candidate, .measured) }
        }

        // Fallback: assume a centered notch of a typical width.
        let assumedWidth: CGFloat = 200
        return (CGRect(x: frame.midX - assumedWidth / 2,
                       y: frame.maxY - safeTop,
                       width: assumedWidth,
                       height: safeTop),
                .assumed)
    }

    /// A notch is narrow and sits near the middle. Bounds chosen wide enough to
    /// cover every shipping Mac and narrow enough to reject a bad reading.
    static func isPlausibleNotch(_ rect: CGRect, in frame: CGRect) -> Bool {
        guard rect.width >= 80, rect.width <= 400 else { return false }
        guard rect.width < frame.width / 3 else { return false }
        // Physically centred, give or take a rounding error.
        return abs(rect.midX - frame.midX) <= frame.width * 0.05
    }

    /// The window that hosts the overlay. Sized to fit the fully expanded pill when
    /// expanded; shrinks to the visible collapsed pill when not.
    func windowFrame(expanded: Bool, collapsedContentSize: CGSize, expandedContentSize: CGSize) -> CGRect {
        if expanded {
            let pad: CGFloat = 2
            let width = expandedContentSize.width + pad * 2
            let height = expandedContentSize.height + pad
            return CGRect(x: notchRect.midX - width / 2,
                          y: screen.frame.maxY - height,
                          width: width,
                          height: height)
        }
        let pad: CGFloat = 2
        let width = collapsedContentSize.width + pad * 2
        let height = collapsedContentSize.height + pad
        return CGRect(x: notchRect.midX - width / 2,
                      y: screen.frame.maxY - height,
                      width: width,
                      height: height)
    }
}
