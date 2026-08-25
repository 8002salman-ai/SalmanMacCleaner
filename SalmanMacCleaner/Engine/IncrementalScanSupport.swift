//
//  IncrementalScanSupport.swift
//  SalmanMacCleaner
//
//  Incremental scan support using ONLY public FSEvents APIs. Stores the last
//  processed event id per volume; invalidates cached inventory whenever the
//  event history is unavailable or inconsistent. Never reads the private
//  .fseventsd database.
//

import Foundation
import CoreServices

public enum IncrementalScanSupport {

    /// Collect changed directories on `root` since `sinceEventID` using a
    /// public FSEventStream. Runs for a bounded time and returns the changed
    /// paths (parents of changed files) plus the newest event id observed.
    /// Returns nil when event history is unavailable (caller must fall back
    /// to a full rescan).
    public static func collectChangedDirectories(
        root: String,
        sinceEventID: UInt64,
        collectDuration: TimeInterval = 1.0
    ) -> (paths: Set<String>, newestEventID: UInt64?)? {
        let collector = ChangedDirectoryCollector()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, eventIDs in
            guard let info, eventCount > 0 else { return }
            let collector = Unmanaged<ChangedDirectoryCollector>.fromOpaque(info).takeUnretainedValue()
            let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self)
            var paths: [String] = []
            for index in 0..<eventCount {
                if let path = pathsArray.object(at: index) as? String {
                    paths.append(path)
                }
            }
            guard !paths.isEmpty else { return }
            collector.append(
                paths: paths,
                flags: Array(UnsafeBufferPointer(start: eventFlags, count: eventCount)),
                ids: Array(UnsafeBufferPointer(start: eventIDs, count: eventCount))
            )
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(sinceEventID),
            0.1,
            flags
        ) else {
            return nil
        }

        let queue = DispatchQueue(label: "com.salman.maccleaner.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }

        // Bounded collection window, then flush and tear down.
        Thread.sleep(forTimeInterval: collectDuration)
        FSEventStreamFlushSync(stream)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        let snapshot = collector.snapshot()
        guard snapshot.newestEventID != 0 else {
            return (snapshot.paths, nil)
        }
        return (snapshot.paths, snapshot.newestEventID)
    }

    /// The latest event id for a device at a given time (public API).
    public static func lastEventID(device: Int32, before date: Date = Date()) -> UInt64 {
        FSEventsGetLastEventIdForDeviceBeforeTime(dev_t(device), date.timeIntervalSinceReferenceDate)
    }
}

/// Thread-safe collector for FSEvents callbacks.
private final class ChangedDirectoryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var changedPaths: Set<String> = []
    private var newestEventID: UInt64 = 0
    /// Flag kFSEventStreamEventFlagMustScanSubDirs.
    private static let mustScanSubDirs: FSEventStreamEventFlags = 0x00000004

    func append(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        lock.lock()
        defer { lock.unlock() }
        for (index, path) in paths.enumerated() {
            if index < flags.count && (flags[index] & Self.mustScanSubDirs) != 0 {
                // Directory-level changes require the directory rescan.
                changedPaths.insert((path as NSString).deletingLastPathComponent)
            } else {
                changedPaths.insert((path as NSString).deletingLastPathComponent)
            }
            if index < ids.count {
                newestEventID = max(newestEventID, ids[index])
            }
        }
    }

    func snapshot() -> (paths: Set<String>, newestEventID: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (changedPaths, newestEventID)
    }
}
