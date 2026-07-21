import AppKit
import Combine

/// Headless self-checks used to verify the spec without hand-driving the GUI.
/// Enabled with NOTCHPILL_DIAG=1; prints geometry facts and runs the
/// debounce/priority burst test, then exits.
@MainActor
enum Diagnostics {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["NOTCHPILL_DIAG"] == "1" }
    static var forceExpand: Bool { ProcessInfo.processInfo.environment["NOTCHPILL_FORCE_EXPAND"] == "1" }

    /// Seeds the shelf with a couple of real files (from NOTCHPILL_DEMO_SHELF, a
    /// colon-separated path list) so the populated shelf can be inspected.
    static func seedShelfIfRequested(_ shelf: ShelfStore) {
        guard let paths = ProcessInfo.processInfo.environment["NOTCHPILL_DEMO_SHELF"] else { return }
        let urls = paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        shelf.add(urls: urls)
    }

    static func run() {
        print("=== NotchPill diagnostics ===")
        printGeometry()
        runBurstTest {
            print("=== diagnostics complete ===")
            exit(0)
        }
    }

    private static func printGeometry() {
        guard let geo = NotchGeometry.current() else {
            print("GEOMETRY: no built-in notched display detected (overlay would be hidden).")
            return
        }
        let f = geo.screen.frame
        let inset = geo.screen.safeAreaInsets.top
        print("SCREEN frame: \(rectStr(f)), safeAreaTop: \(inset)")
        if let l = geo.screen.auxiliaryTopLeftArea { print("auxTopLeft: \(rectStr(l))") }
        if let r = geo.screen.auxiliaryTopRightArea { print("auxTopRight: \(rectStr(r))") }
        print("NOTCH rect (global): \(rectStr(geo.notchRect))")
        let win = geo.windowFrame
        print("WINDOW frame: \(rectStr(win))")

        // Assert: window horizontally centered on the notch, top flush with screen.
        let notchCenterX = geo.notchRect.midX
        let winCenterX = win.midX
        let centeredOK = abs(notchCenterX - winCenterX) < 0.5
        let topFlushOK = abs(win.maxY - f.maxY) < 0.5
        let coversNotchTop = win.maxY >= geo.notchRect.maxY - 0.5 && win.minX <= geo.notchRect.minX + 0.5 && win.maxX >= geo.notchRect.maxX - 0.5
        print("ASSERT window centered on notch: \(centeredOK ? "PASS" : "FAIL") (notchMidX=\(notchCenterX), winMidX=\(winCenterX))")
        print("ASSERT window top flush with screen top: \(topFlushOK ? "PASS" : "FAIL")")
        print("ASSERT window spans the notch region: \(coversNotchTop ? "PASS" : "FAIL")")
    }

    /// Fires two state changes within 200ms and confirms the single state
    /// manager resolves them to exactly ONE published activity (no duplicate
    /// render / glitch).
    private static func runBurstTest(completion: @escaping () -> Void) {
        let state = NotchState()
        var emissions: [String] = []
        var bag = Set<AnyCancellable>()
        state.$activity
            .dropFirst() // ignore the initial .idle value
            .sink { activity in emissions.append(activity.transitionKey) }
            .store(in: &bag)

        let track = NowPlaying(title: "Song A", artist: "Artist", isPlaying: true, artwork: nil)
        let track2 = NowPlaying(title: "Song B", artist: "Artist", isPlaying: true, artwork: nil)

        // Burst 1 — two MEDIA changes 100ms apart (within the 200ms window).
        state.notifyMediaChanged(track)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            state.notifyMediaChanged(track2)
        }

        // Burst 2 — two APP-SWITCH changes 100ms apart, after burst 1 settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            state.notifyAppSwitched("Xcode")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) {
            state.notifyAppSwitched("Safari")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withExtendedLifetime(state) {} // hold the state manager for the test's duration
            _ = bag // keep the subscription alive
            // Each burst must resolve to exactly ONE published activity.
            let mediaCount = emissions.filter { $0 == "media" }.count
            let appCount = emissions.filter { $0 == "appSwitch" }.count
            print("BURST emissions sequence: \(emissions)")
            print("ASSERT media burst (2 events/200ms) -> single render: \(mediaCount == 1 ? "PASS" : "FAIL") (count=\(mediaCount))")
            print("ASSERT appSwitch burst (2 events/200ms) -> single render: \(appCount == 1 ? "PASS" : "FAIL") (count=\(appCount))")
            print("ASSERT no duplicate renders in burst: \(emissions.count == 2 ? "PASS" : "FAIL") (total=\(emissions.count))")
            completion()
        }
    }

    private static func rectStr(_ r: CGRect) -> String {
        String(format: "(x=%.1f, y=%.1f, w=%.1f, h=%.1f)", r.minX, r.minY, r.width, r.height)
    }
}
