//
//  CleanupExecutor.swift
//  SalmanMacCleaner
//
//  Executes an immutable cleanup plan. Trash-only: items move to the Trash
//  via FileManager.trashItem after the CleanupSafetyValidator rechecks every
//  guard. No permanent deletion, no Trash emptying, no privileged actions.
//

import Foundation

public struct ExecutedCleanupResult: Equatable {
    public var moved: [String]
    public var previewed: [String]
    public var failures: [(path: String, reason: String)]
    public var bytesReclaimed: Int64
    public var previewOnly: Bool

    public init(moved: [String] = [],
                previewed: [String] = [],
                failures: [(path: String, reason: String)] = [],
                bytesReclaimed: Int64 = 0,
                previewOnly: Bool) {
        self.moved = moved
        self.previewed = previewed
        self.failures = failures
        self.bytesReclaimed = bytesReclaimed
        self.previewOnly = previewOnly
    }

    public var succeededCount: Int { moved.count + previewed.count }
    public var failedCount: Int { failures.count }
}

public enum CleanupExecutorError: LocalizedError, Equatable {
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cancelled: return NSLocalizedString("scan.error.cancelled", comment: "")
        }
    }
}

@MainActor
public final class CleanupExecutor: ObservableObject {

    @Published public private(set) var isRunning = false
    @Published public private(set) var currentItem: String?

    public static let shared = CleanupExecutor()

    public init() {}

    /// Execute a plan. `previewOnly` plans touch nothing; otherwise each item
    /// is revalidated immediately before `trashItem`.
    public func execute(
        plan: CleanupPlan,
        allowBundles: Bool = false,
        libraryRoots: [String] = [],
        reviewRoots: [String] = [],
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) async -> ExecutedCleanupResult {
        isRunning = true
        defer {
            isRunning = false
            currentItem = nil
        }

        var result = ExecutedCleanupResult(previewOnly: plan.previewOnly)
        let total = max(plan.items.count, 1)

        for (index, item) in plan.items.enumerated() {
            if isCancelled() {
                return result
            }
            progress(Double(index) / Double(total), item.path)

            switch CleanupSafetyValidator.validate(
                item: item,
                allowBundles: allowBundles,
                libraryRoots: libraryRoots,
                reviewRoots: reviewRoots
            ) {
            case .failure(let failure):
                result.failures.append((item.path, failure.localizedDescription))
                continue
            case .success(let validated):
                currentItem = validated.path
                if plan.previewOnly {
                    result.previewed.append(validated.path)
                    result.bytesReclaimed += validated.expectedSize
                } else {
                    do {
                        var resultingURL: NSURL?
                        try FileManager.default.trashItem(
                            at: URL(fileURLWithPath: validated.path),
                            resultingItemURL: &resultingURL
                        )
                        result.moved.append(validated.path)
                        result.bytesReclaimed += validated.expectedSize
                    } catch {
                        result.failures.append((validated.path, error.localizedDescription))
                    }
                }
            }
        }
        progress(1, nil)
        return result
    }
}
