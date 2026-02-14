//
//  Diagnostics.swift
//  LosslessSwitcher
//
//  A lightweight logger that can be used without Xcode.
//

import Foundation

final class Diagnostics {
    static let shared = Diagnostics()

    private let queue = DispatchQueue(label: "Diagnostics.queue")
    private var lines: [String] = []
    private let maxLines = 2000

    private init() {}

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)"
        queue.async {
            self.lines.append(line)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    func snapshot() -> String {
        queue.sync {
            self.lines.joined(separator: "\n") + "\n"
        }
    }

    func writeLogFile() throws -> URL {
        let fm = FileManager.default
        let logsDir = try fm.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("LosslessSwitcher", isDirectory: true)

        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "debug_\(dateFormatter.string(from: Date())).log"
        let fileURL = logsDir.appendingPathComponent(filename)

        try snapshot().write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}

