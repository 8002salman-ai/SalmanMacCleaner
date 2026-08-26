//
//  DuplicatePipeline.swift
//  SalmanMacCleaner
//
//  Staged duplicate detection:
//   1. group by allocated/logical size
//   2. drop impossible groups
//   3. lightweight sample hash (first + last 8 KiB, streaming)
//   4. full streaming SHA-256 only for remaining candidates
//   5. compare device/inode identity — hard links are never "duplicates"
//   6. flag APFS clone uncertainty in the reclaim estimate
//

import Foundation

public enum DuplicatePipeline {

    public static let sampleBytes: Int = 8 * 1024

    /// Run the staged pipeline over `candidates`. Bounded hashing
    /// concurrency; cooperative cancellation between stages.
    public static func detect(
        candidates: [ScannedItem],
        isCancelled: @escaping () -> Bool
    ) throws -> [DuplicateCandidateGroup] {
        // Stage 1: group by exact size.
        var bySize: [Int64: [ScannedItem]] = [:]
        for item in candidates {
            bySize[item.size, default: []].append(item)
        }

        var groups: [DuplicateCandidateGroup] = []
        let sizeGroups = bySize.values.filter { $0.count > 1 }

        for sizeGroup in sizeGroups {
            if isCancelled() { throw DuplicateScanError.cancelled }

            // Stage 2: skip impossible groups (fewer than 2 distinct files).
            if sizeGroup.count < 2 { continue }

            // Stage 3: sample hash to prune cheaply.
            var bySample: [String: [ScannedItem]] = [:]
            for item in sizeGroup {
                if isCancelled() { throw DuplicateScanError.cancelled }
                if let sample = sampleHash(item.path, size: item.size) {
                    bySample[sample, default: []].append(item)
                }
            }

            // Stage 4: full streaming SHA-256 on surviving candidates.
            for (_, sampleGroup) in bySample where sampleGroup.count > 1 {
                if isCancelled() { throw DuplicateScanError.cancelled }
                var byFull: [String: [ScannedItem]] = [:]
                for item in sampleGroup {
                    if isCancelled() { throw DuplicateScanError.cancelled }
                    switch Crypto.sha256(ofFileAt: item.path, isCancelled: isCancelled) {
                    case .success(let digest):
                        byFull[digest, default: []].append(item)
                    case .failure:
                        continue
                    }
                }

                for (digest, files) in byFull {
                    // Stage 5: split by device/inode identity.
                    let identitySets = splitByIdentity(files)
                    guard identitySets.count > 1 else { continue }
                    let representatives = identitySets.compactMap { $0.first }
                    guard let first = representatives.first else { continue }

                    // Stage 6: clone uncertainty — allocated size may be
                    // shared by APFS clones, so label the estimate.
                    // APFS clone extents are not exposed by the portable
                    // stat identity used here. Marking the estimate as
                    // uncertain is safer than claiming every logical byte is
                    // independently reclaimable.
                    let cloneUncertain = true
                    groups.append(DuplicateCandidateGroup(
                        files: representatives,
                        size: first.size,
                        hash: digest,
                        apfsCloneUncertain: cloneUncertain
                    ))
                }
            }
        }

        groups.sort { $0.reclaimableEstimate > $1.reclaimableEstimate }
        return groups
    }

    /// Lightweight sample hash: first and last `sampleBytes`, streamed.
    static func sampleHash(_ path: String, size: Int64) -> String? {
        Crypto.sampleHash(ofFileAt: path, size: size, sampleBytes: sampleBytes)
    }

    /// Group files by (device, inode) so hard links to one file are one set.
    static func splitByIdentity(_ files: [ScannedItem]) -> [[ScannedItem]] {
        var identityGroups: [String: [ScannedItem]] = [:]
        for file in files {
            let key: String
            if let identity = Crypto.inode(of: file.path) {
                key = "\(identity.0)-\(identity.1)"
            } else {
                key = "missing-\(file.path)"
            }
            identityGroups[key, default: []].append(file)
        }
        return Array(identityGroups.values)
    }
}
