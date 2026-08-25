//
//  Crypto.swift
//  SalmanMacCleaner
//
//  Streaming SHA-256 hashing for the duplicate finder. Files are read in
//  bounded chunks through Foundation streams — never loaded wholesale into
//  memory — and hashing is cancellable so the duplicate scan stays responsive.
//

import Foundation
import CommonCrypto
import Darwin

/// Incremental SHA-256 hasher built on CommonCrypto. `feed` can be called any
/// number of times; `finalize` produces the lowercase hex digest.
public final class StreamingSHA256 {

    private var context = CC_SHA256_CTX()
    private var finalized = false

    public init() {
        CC_SHA256_Init(&context)
    }

    public func feed(_ data: Data) {
        guard !finalized else { return }
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            CC_SHA256_Update(&context, baseAddress, CC_LONG(rawBuffer.count))
        }
    }

    public func finalize() -> String {
        guard !finalized else { return "" }
        finalized = true
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = digest.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) in
            CC_SHA256_Final(rawBuffer.bindMemory(to: UInt8.self).baseAddress, &context)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum HashError: LocalizedError, Equatable {
    case openFailed(String)
    case unreadable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path): return NSLocalizedString("error.hash_open", comment: "") + " \(path)"
        case .unreadable(let path): return NSLocalizedString("error.hash_unreadable", comment: "") + " \(path)"
        case .cancelled: return NSLocalizedString("error.hash_cancelled", comment: "")
        }
    }
}

public enum Crypto {

    /// Chunk size used when streaming a file into the hasher.
    public static let chunkSize = 1 << 20 // 1 MiB

    /// Hash a file at `path`, streaming it in 1 MiB chunks. `isCancelled` is
    /// polled between chunks; cancellation surfaces as `HashError.cancelled`.
    /// Files larger than `sizeLimit` are refused up-front so the duplicate
    /// scan cannot be fed multi-gigabyte inputs by accident.
    public static func sha256(
        ofFileAt path: String,
        sizeLimit: Int64 = 8 * 1024 * 1024 * 1024,
        isCancelled: () -> Bool = { false }
    ) -> Result<String, HashError> {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else {
            return .failure(.openFailed(path))
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.unreadable(path))
        }
        if statBuffer.st_size > sizeLimit {
            return .failure(.unreadable(path))
        }

        // O_NOFOLLOW closes the enumeration-to-hash symlink race: a changed
        // leaf is rejected instead of reading an arbitrary target.
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            return .failure(.openFailed(path))
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        let hasher = StreamingSHA256()
        do {
            while true {
                if isCancelled() {
                    return .failure(.cancelled)
                }
                guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else {
                    break
                }
                hasher.feed(data)
            }
        } catch {
            return .failure(.unreadable(path))
        }
        return .success(hasher.finalize())
    }

    /// Bounded first/last sample used only as a hash-elimination stage. It
    /// uses the same no-symlink open policy as the full digest reader and is
    /// never treated as proof of equality.
    public static func sampleHash(ofFileAt path: String, size: Int64, sampleBytes: Int = 8 * 1024) -> String? {
        guard sampleBytes > 0 else { return nil }
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0,
              (statBuffer.st_mode & S_IFMT) == S_IFREG else { return nil }
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let hasher = StreamingSHA256()
        do {
            if let head = try handle.read(upToCount: sampleBytes), !head.isEmpty {
                hasher.feed(head)
            }
            if size > Int64(sampleBytes) {
                try handle.seek(toOffset: UInt64(max(size - Int64(sampleBytes), 0)))
                if let tail = try handle.read(upToCount: sampleBytes), !tail.isEmpty {
                    hasher.feed(tail)
                }
            }
            return hasher.finalize()
        } catch {
            return nil
        }
    }

    /// Convenience wrapper returning the digest or nil (used by tests).
    public static func sha256Hex(ofFileAt path: String) -> String? {
        switch sha256(ofFileAt: path) {
        case .success(let digest): return digest
        case .failure: return nil
        }
    }

    /// Hash the file quickly *by size* — the first grouping key in the
    /// duplicate pipeline. Returns the file size or nil when unavailable.
    public static func fileSize(of path: String) -> Int64? {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return nil }
        return statBuffer.st_size
    }

    /// The device id (st_dev) — used to build inode+device identity pairs.
    public static func deviceID(of path: String) -> dev_t? {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return nil }
        return statBuffer.st_dev
    }

    /// The file-system identity (device, inode) used to detect hard links.
    public static func inode(of path: String) -> (dev_t, ino_t)? {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return nil }
        return (statBuffer.st_dev, statBuffer.st_ino)
    }

    /// Number of directory entries pointing at a regular file. A selected
    /// hard-linked file is not physically reclaimable by moving one name, so
    /// cleanup revalidation can refuse it conservatively.
    public static func linkCount(of path: String) -> UInt64? {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return nil }
        return UInt64(statBuffer.st_nlink)
    }
}
