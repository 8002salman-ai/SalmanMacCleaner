//
//  MachOArchitecture.swift
//  SalmanMacCleaner
//
//  Reads Mach-O headers directly (no shell, no `file` command) to report the
//  architectures contained in a binary.
//

import Foundation

public enum MachOArchitecture {

    public static func architectures(ofBinaryAt path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        // Headers + fat entries are tiny; reading a bounded prefix is enough.
        guard let raw = try? handle.read(upToCount: 4096) else { return [] }
        let bytes = [UInt8](raw)
        guard bytes.count >= 4 else { return [] }

        let magic = be32(bytes, 0)
        switch magic {
        case 0xFEEDFACF: // MH_MAGIC_64 — thin 64-bit
            return [cpuName(cpuType: be32(bytes, 4))]
        case 0xFEEDFACE: // MH_MAGIC — thin 32-bit
            return [cpuName(cpuType: be32(bytes, 4))]
        case 0xCAFEBABE: // FAT_MAGIC — 32-bit fat entries
            return fatArchitectures(bytes, entrySize: 20)
        case 0xCAFEBAFF: // FAT_MAGIC_64 — 64-bit fat entries
            return fatArchitectures(bytes, entrySize: 32)
        default:
            return []
        }
    }

    private static func fatArchitectures(_ bytes: [UInt8], entrySize: Int) -> [String] {
        guard bytes.count >= 8 else { return [] }
        let count = Int(be32(bytes, 4))
        guard count > 0, count < 64 else { return [] }
        guard bytes.count >= 8 + count * entrySize else { return [] }

        var names: [String] = []
        for index in 0..<count {
            let cpuType = be32(bytes, 8 + index * entrySize)
            let name = cpuName(cpuType: cpuType)
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func cpuName(cpuType: UInt32) -> String {
        switch cpuType {
        case 0x0100_000C: return "arm64"
        case 0x0100_000E: return "arm64e"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        case 0x0000_0012: return "ppc"
        default: return String(format: "cpu-0x%x", cpuType)
        }
    }
}
