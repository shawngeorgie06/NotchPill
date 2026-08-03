import Foundation
import CoreGraphics

/// Short-lived geometry trace for diagnosing hover animation. It is disabled
/// normally and, when explicitly enabled, writes only window measurements to a
/// temporary file — never agent, prompt, or app-content data.
enum MotionTrace {
    static let enabled = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_MOTION"] == "1"
    static let url = URL(fileURLWithPath: "/private/tmp/notchpill-motion.log")

    static func record(_ message: String) {
        guard enabled else { return }
        let line = "\(LogStore.lineFormatter.string(from: Date())) [motion] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func rect(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1f×%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}
