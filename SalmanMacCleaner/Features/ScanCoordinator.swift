//
//  ScanCoordinator.swift
//  SalmanMacCleaner
//
//  Cancellable background scan operations shared by the large-file, duplicate
//  and developer-cache features. Uses structured concurrency: the operation
//  body runs off the main actor, progress is marshalled back to the main
//  actor, and cancellation is cooperative.
//

import Foundation
import Combine

public enum ScanError: LocalizedError, Equatable {
    case noRoots
    case cancelled
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .noRoots: return NSLocalizedString("scan.error.no_roots", comment: "")
        case .cancelled: return NSLocalizedString("scan.error.cancelled", comment: "")
        case .permissionDenied(let path): return NSLocalizedString("scan.error.permission", comment: "") + " \(path)"
        }
    }
}

/// A single scan task definition. Runs off the main actor.
public struct ScanOperation<Output> {
    public let title: String
    public let roots: [String]
    public let run: (_ progress: @escaping (Double, String?) -> Void,
                     _ isCancelled: @escaping () -> Bool) async throws -> Output

    public init(title: String,
                roots: [String],
                run: @escaping (_ progress: @escaping (Double, String?) -> Void,
                                _ isCancelled: @escaping () -> Bool) async throws -> Output) {
        self.title = title
        self.roots = roots
        self.run = run
    }
}

/// Coordinates scan lifecycles: one at a time, cancellable, progress-aware.
@MainActor
public final class ScanCoordinator: ObservableObject {

    @Published public private(set) var isRunning = false
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var detail: String?
    @Published public private(set) var lastError: String?

    public static let shared = ScanCoordinator()

    private var currentTask: Task<Void, Never>?
    private var generation = UUID()

    public init() {}

    /// Start an operation, cancelling any in-flight one first.
    ///
    /// - Parameters:
    ///   - operation: The scan to run.
    ///   - onProgress: Main-actor callback for progress updates (optional).
    ///   - onComplete: Main-actor callback with the final outcome.
    public func start<Output>(
        _ operation: ScanOperation<Output>,
        onProgress: ((Double, String?) -> Void)? = nil,
        onComplete: @escaping (Result<Output, Error>) -> Void
    ) {
        cancel()
        isRunning = true
        progress = 0
        detail = operation.title
        lastError = nil

        // A generation token ensures a superseded task never mutates state
        // after a newer scan has started.
        let token = UUID()
        generation = token

        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let output = try await operation.run(
                    { fraction, text in
                        Task { @MainActor in
                            guard self.generation == token else { return }
                            self.progress = fraction
                            if let text { self.detail = text }
                            onProgress?(fraction, text)
                        }
                    },
                    {
                        Task.isCancelled
                    }
                )
                await self.finishIfCurrent(token: token, outcome: .success(output), onComplete: onComplete)
            } catch is CancellationError {
                await self.finishIfCurrent(token: token, outcome: .failure(ScanError.cancelled), onComplete: onComplete)
            } catch {
                await self.finishIfCurrent(token: token, outcome: .failure(error), onComplete: onComplete)
            }
        }
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        generation = UUID()
        isRunning = false
        progress = 0
        detail = nil
    }

    private func finishIfCurrent<Output>(
        token: UUID,
        outcome: Result<Output, Error>,
        onComplete: @escaping (Result<Output, Error>) -> Void
    ) {
        // Only update shared coordinator state when this task is still the
        // active one; the completion handler always fires so callers can
        // observe cancellations and reset their own UI.
        if generation == token {
            isRunning = false
            progress = 1
            if case .failure(let error) = outcome {
                lastError = error.localizedDescription
            }
        }
        onComplete(outcome)
    }
}
