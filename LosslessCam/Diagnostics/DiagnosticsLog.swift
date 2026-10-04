import Foundation
import Combine
import UIKit
import os

/// Persistent, user-visible log of capture-session errors, caught Objective-C
/// exceptions, recovery steps and recording summaries.
///
/// Lines are appended to `Documents/LosslessCam_diagnostics.log` (exportable
/// through the Files app / USB) and mirrored into an in-memory tail that the
/// Settings screen shows and can copy to the clipboard. Nothing leaves the
/// device.
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    @Published private(set) var tail: [String] = []

    private let queue = DispatchQueue(label: "com.losslesscam.diagnostics", qos: .utility)
    private let maxTail = 500
    private let maxFileBytes: UInt64 = 2 * 1024 * 1024
    private let url: URL
    private let formatter: DateFormatter
    private let logger = Logger(subsystem: "com.losslesscam.app", category: "diagnostics")

    private init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LosslessCam_diagnostics.log")
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n").map(String.init)
        tail = Array(lines.suffix(maxTail))
    }

    var fileURL: URL { url }

    var text: String { tail.joined(separator: "\n") }

    /// Appends one line. Safe from any thread.
    func log(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)"
        logger.log("\(line, privacy: .public)")
        queue.async { [self] in
            self.append(line)
        }
        DispatchQueue.main.async { [self] in
            self.tail.append(line)
            if self.tail.count > self.maxTail { self.tail.removeFirst(self.tail.count - self.maxTail) }
        }
    }

    func clear() {
        queue.async { [self] in try? FileManager.default.removeItem(at: self.url) }
        DispatchQueue.main.async { [self] in self.tail.removeAll() }
    }

    private func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            if let size = try? h.seekToEnd(), size > maxFileBytes {
                // Keep the file bounded: restart it with a marker.
                try? h.truncate(atOffset: 0)
                try? h.write(contentsOf: Data("--- log truncated ---\n".utf8))
            }
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Human-readable description of an NSError including domain, code and the
    /// underlying error chain (the only way to tell the "Cannot Record" family apart).
    static func describe(_ error: Error?) -> String {
        guard let error = error else { return "unknown error" }
        let ns = error as NSError
        var parts: [String] = ["\(ns.domain) \(ns.code): \(ns.localizedDescription)"]
        if let reason = ns.localizedFailureReason, !reason.isEmpty { parts.append("reason: \(reason)") }
        if let suggestion = ns.localizedRecoverySuggestion, !suggestion.isEmpty { parts.append("suggestion: \(suggestion)") }
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let u = underlying, depth < 4 {
            parts.append("underlying: \(u.domain) \(u.code)" + (u.localizedDescription.isEmpty ? "" : " \(u.localizedDescription)"))
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        for (k, v) in ns.userInfo where k != NSUnderlyingErrorKey && k != NSLocalizedDescriptionKey && k != NSLocalizedFailureReasonErrorKey && k != NSLocalizedRecoverySuggestionErrorKey {
            parts.append("\(k)=\(v)")
        }
        return parts.joined(separator: " · ")
    }

    /// Short label for an AVFoundation error code, for the user-facing alert.
    static func shortLabel(_ error: Error?) -> String {
        guard let ns = error as NSError? else { return "unknown error" }
        let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (underlying \($0.domain) \($0.code))" } ?? ""
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)\(underlying)]"
    }
}
