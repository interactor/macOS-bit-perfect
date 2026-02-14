//
//  Console.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//
// https://developer.apple.com/forums/thread/677068

import OSLog
import Cocoa

struct SimpleConsole {
    let date: Date
    let message: String
}

enum EntryType: String {
    case music = "com.apple.Music"
    case coreAudio = "com.apple.coreaudio"
    case coreMedia = "com.apple.coremedia"
    
    var predicate: NSPredicate {
        // Prefer matching the subsystem only. On newer macOS versions the `process` field
        // may vary (e.g. Music, musicd), and we further filter by message patterns anyway.
        NSPredicate(format: "subsystem = %@", rawValue)
    }
}

class Console {
    private static let storeQueue = DispatchQueue(label: "Console.OSLogStore.queue")
    private static var cachedStore: OSLogStore?

    private static func getStore() throws -> OSLogStore {
        try storeQueue.sync {
            if let cachedStore {
                return cachedStore
            }
            let store = try OSLogStore.local()
            cachedStore = store
            return store
        }
    }

    static func getRecentEntries(
        type: EntryType,
        lookbackSeconds: TimeInterval = 10,
        maxEntries: Int = 2_000
    ) throws -> [SimpleConsole] {
        // We iterate newest -> oldest for speed (early cutoff), then reverse
        // so callers see logs in chronological order (oldest -> newest).
        var messages = [SimpleConsole]()
        messages.reserveCapacity(min(maxEntries, 256))

        let store = try getStore()
        let end = store.position(timeIntervalSinceEnd: 0)
        let cutoff = Date().addingTimeInterval(-lookbackSeconds)

        // Iterate from newest to oldest and stop early to keep polling low-latency.
        let entries = try store.getEntries(with: [.reverse], at: end, matching: type.predicate)
        for case let entry as OSLogEntryLog in entries {
            if entry.date < cutoff {
                break
            }
            messages.append(SimpleConsole(date: entry.date, message: entry.composedMessage))
            if messages.count >= maxEntries {
                break
            }
        }

        messages.reverse()
        return messages
    }
}
