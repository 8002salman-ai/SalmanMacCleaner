//
//  ProcessSampler.swift
//  SalmanMacCleaner
//
//  Evidence-based resource sampling for the Performance module using public
//  libproc APIs. Two samples are taken a short time apart; CPU fraction is
//  the delta of user+system time over elapsed wall time. When sampling is
//  unavailable the module reports "unavailable" instead of inventing data.
//

import Foundation
import AppKit
import Darwin

public struct ProcessSample: Identifiable, Equatable {
    public var id: pid_t { pid }
    public var pid: pid_t
    public var name: String
    public var cpuFraction: Double
    public var residentBytes: UInt64

    public init(pid: pid_t, name: String, cpuFraction: Double, residentBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuFraction = cpuFraction
        self.residentBytes = residentBytes
    }
}

public enum ProcessSampler {

    /// Sample running applications for `interval` seconds. Returns processes
    /// sorted by CPU fraction descending, capped at `limit` entries.
    public static func sampleRunningApplications(
        interval: TimeInterval = 0.6,
        limit: Int = 10
    ) -> [ProcessSample] {
        var firstSample: [pid_t: (cpu: UInt64, rss: UInt64)] = [:]
        let firstTime = mach_absolute_time()
        for app in NSWorkspace.shared.runningApplications {
            guard let usage = usageInfo(pid: app.processIdentifier) else { continue }
            firstSample[app.processIdentifier] = usage
        }

        Thread.sleep(forTimeInterval: interval)

        let secondTime = mach_absolute_time()
        var results: [ProcessSample] = []
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        for app in NSWorkspace.shared.runningApplications {
            guard let first = firstSample[app.processIdentifier],
                  let second = usageInfo(pid: app.processIdentifier) else { continue }
            let cpuDelta = second.cpu >= first.cpu ? second.cpu - first.cpu : 0
            let elapsedTicks = secondTime >= firstTime ? secondTime - firstTime : 0
            let elapsedSeconds = Double(elapsedTicks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
            guard elapsedSeconds > 0 else { continue }
            let cpuFraction = Double(cpuDelta) / 1_000_000_000 / elapsedSeconds
            results.append(ProcessSample(
                pid: app.processIdentifier,
                name: app.localizedName ?? "pid-\(app.processIdentifier)",
                cpuFraction: cpuFraction,
                residentBytes: second.rss
            ))
        }

        return results
            .filter { $0.cpuFraction > 0.0005 }
            .sorted { $0.cpuFraction > $1.cpuFraction }
            .prefix(limit)
            .map { $0 }
    }

    /// CPU time (ns) + resident bytes via proc_pid_rusage RUSAGE_INFO_V2.
    private static func usageInfo(pid: pid_t) -> (cpu: UInt64, rss: UInt64)? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer(pointer))
        }
        guard result == 0 else { return nil }
        let cpu = info.ri_user_time + info.ri_system_time
        return (cpu, info.ri_resident_size)
    }
}
