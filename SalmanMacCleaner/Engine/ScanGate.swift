//
//  ScanGate.swift
//  SalmanMacCleaner
//
//  Pause/resume control for long scans. Scanners poll `waitIfPaused()` at
//  safe points; pausing blocks them cooperatively without killing work.
//

import Foundation

public actor ScanGate {

    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func pause() {
        paused = true
    }

    public func resume() {
        guard paused else { return }
        paused = false
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    public func isPaused() -> Bool {
        paused
    }

    /// Suspends the caller while the gate is paused. Returns immediately when
    /// running.
    public func waitIfPaused() async {
        while paused {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    public func cancelAll() {
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
