import ApplicationServices
import Foundation

/// Tracks Accessibility (TCC) status without nagging on every launch.
enum AccessibilityAuthorization {
    private static let promptedExecutableKey = "accessibilityPromptedExecutable"
    private static let declinedExecutableKey = "accessibilityAlertDeclinedExecutable"

    /// Stable identity for this app binary — changes when Xcode produces a new build path.
    static var executableIdentity: String {
        Bundle.main.executableURL?.path ?? Bundle.main.bundlePath
    }

    static var isGranted: Bool {
        AXIsProcessTrustedWithOptions(checkOptions(prompt: false))
    }

    /// True when we should show the one-time system Accessibility sheet.
    static var shouldOfferSystemPrompt: Bool {
        guard !isGranted else { return false }
        return UserDefaults.standard.string(forKey: promptedExecutableKey) != executableIdentity
    }

    /// True when we should show our explanatory alert (once per binary, unless declined).
    static var shouldOfferAlert: Bool {
        guard !isGranted else { return false }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: declinedExecutableKey) == executableIdentity { return false }
        if defaults.string(forKey: promptedExecutableKey) == executableIdentity { return false }
        return true
    }

    static func markSystemPromptOffered() {
        UserDefaults.standard.set(executableIdentity, forKey: promptedExecutableKey)
    }

    static func markAlertDeclined() {
        UserDefaults.standard.set(executableIdentity, forKey: declinedExecutableKey)
    }

    /// Opens the system Accessibility prompt sheet (use sparingly — from menu actions).
    static func requestSystemPrompt() {
        guard !isGranted else { return }
        _ = AXIsProcessTrustedWithOptions(checkOptions(prompt: true))
        markSystemPromptOffered()
    }

    private static func checkOptions(prompt: Bool) -> CFDictionary {
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    }
}
