import AppKit

/// Brings another application to the front, and — the part that matters —
/// *checks that it worked*.
///
/// `NSRunningApplication.activate` returns `Bool`, and from a background
/// accessory app on macOS 26 that `Bool` is a lie: it reports `true` while the
/// frontmost application never changes. Measured from an `LSUIElement` bundle
/// with cmux frontmost and Terminal running:
///
/// ```
/// frontmost before: com.cmuxterm.app
/// activate() returned: true
/// frontmost after:  com.cmuxterm.app
/// ```
///
/// `activateIgnoringOtherApps` was deprecated in macOS 14 with the note that it
/// "will have no effect", and cooperative activation replaced it: an app that
/// is not itself active cannot simply take focus. NotchPill is never active —
/// it is an accessory with a nonactivating panel — so this affects every focus
/// handoff it makes.
///
/// Two features died on that lie, both silently:
///
/// - **Tap to jump** called `activate`, saw `true`, and returned. The peek
///   dismissed itself and no app came forward, so the tap looked like it did
///   nothing at all.
/// - **Reply** waited 2.5s for the target to become frontmost and then aborted
///   with `.focusTimeout`. That abort is the correct, safe behaviour — it is
///   what stops a stray ⏎ landing in someone else's window — but it meant
///   replying could never succeed, on any agent.
///
/// The rule here is that a return value is not evidence. Every strategy is
/// followed by an observation of `frontmostApplication`, and we only stop when
/// the app we asked for is genuinely in front.
enum AppActivator {
    /// How long to watch for the frontmost app to change before deciding a
    /// strategy failed and escalating. Activation is asynchronous — the request
    /// goes to the window server and lands on a later turn of the run loop — so
    /// this polls rather than reading once.
    static let settleTimeout: TimeInterval = 1.2
    static let pollInterval: TimeInterval = 0.05
    private static var maxPolls: Int { Int(settleTimeout / pollInterval) }

    /// The strategies, in the order they are tried.
    ///
    /// Cheapest first. AppleScript is second rather than first because it costs
    /// an Apple Event round trip and, against a target we have not addressed
    /// before, can raise a one-time Automation consent prompt — no reason to pay
    /// either when the plain call happens to work.
    enum Strategy: String, CaseIterable {
        /// `NSRunningApplication.activate()`. Works when NotchPill is somehow
        /// already the active app; a silent no-op otherwise.
        case direct
        /// `tell application id "…" to activate` — asks the target to activate
        /// *itself*, which cooperative activation permits, where us demanding
        /// focus on its behalf does not.
        case appleScript
        /// LaunchServices. Also the only branch that can help when the app is
        /// not running at all, or has no Apple Event support.
        case launchServices
    }

    /// Brings `bundleId` forward, escalating until the app is *observed*
    /// frontmost. Returns immediately; `completion` reports what actually
    /// happened, on the main actor.
    ///
    /// Never blocks. An earlier synchronous draft polled with `Thread.sleep`,
    /// which would have frozen the UI for up to a second on every tap — the
    /// callers here are all on the main actor.
    @MainActor
    static func activate(
        bundleId: String,
        frontmost: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !bundleId.isEmpty else { completion?(false); return }
        if frontmost() == bundleId { completion?(true); return }
        attempt(Strategy.allCases[...], bundleId: bundleId,
                frontmost: frontmost, completion: completion)
    }

    @MainActor
    private static func attempt(
        _ remaining: ArraySlice<Strategy>,
        bundleId: String,
        frontmost: @escaping () -> String?,
        completion: ((Bool) -> Void)?
    ) {
        guard let strategy = remaining.first else {
            LogStore.log("focus", "could not bring \(bundleId) forward "
                         + "(frontmost=\(frontmost() ?? "nil"))")
            completion?(false)
            return
        }
        let next = remaining.dropFirst()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first

        switch strategy {
        case .direct:
            guard let running else {
                attempt(next, bundleId: bundleId, frontmost: frontmost, completion: completion)
                return
            }
            _ = running.activate()
        case .appleScript:
            guard running != nil, runAppleScriptActivate(bundleId: bundleId) else {
                attempt(next, bundleId: bundleId, frontmost: frontmost, completion: completion)
                return
            }
        case .launchServices:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                attempt(next, bundleId: bundleId, frontmost: frontmost, completion: completion)
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }

        poll(bundleId, attemptsLeft: maxPolls, frontmost: frontmost) { won in
            if won {
                LogStore.log("focus", "\(bundleId) frontmost via \(strategy.rawValue)")
                completion?(true)
            } else {
                attempt(next, bundleId: bundleId, frontmost: frontmost, completion: completion)
            }
        }
    }

    /// Polls until `bundleId` is frontmost or the attempts run out.
    @MainActor
    private static func poll(
        _ bundleId: String,
        attemptsLeft: Int,
        frontmost: @escaping () -> String?,
        then body: @escaping (Bool) -> Void
    ) {
        if frontmost() == bundleId { body(true); return }
        if attemptsLeft <= 0 { body(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            poll(bundleId, attemptsLeft: attemptsLeft - 1, frontmost: frontmost, then: body)
        }
    }

    /// Characters a bundle identifier is allowed to contain.
    ///
    /// Validated rather than escaped. Bundle ids reach us from hook payloads,
    /// so they are untrusted input, and they end up inside an AppleScript string
    /// literal — but escaping is the wrong tool here. Escaping quotes still
    /// leaves a raw newline, which AppleScript cannot carry inside a string at
    /// all, and chasing that leads to guessing which characters a future
    /// compiler treats as special. Nothing outside this set is a bundle
    /// identifier, so anything else is refused.
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    static func isValidBundleId(_ bundleId: String) -> Bool {
        !bundleId.isEmpty && bundleId.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `tell application id "…" to activate`, or nil when `bundleId` is not a
    /// bundle id.
    ///
    /// Addressing by **id** rather than by name is deliberate: a name has to
    /// match the app's localised title, and picks the wrong app when two share
    /// one.
    static func activateScript(bundleId: String) -> String? {
        guard isValidBundleId(bundleId) else { return nil }
        return "tell application id \"\(bundleId)\" to activate"
    }

    private static func runAppleScriptActivate(bundleId: String) -> Bool {
        guard let source = activateScript(bundleId: bundleId) else {
            LogStore.log("focus", "refused to script a malformed bundle id")
            return false
        }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            LogStore.log("focus", "AppleScript activate failed for \(bundleId): "
                         + "\(error[NSAppleScript.errorMessage] ?? "unknown")")
            return false
        }
        return true
    }
}
