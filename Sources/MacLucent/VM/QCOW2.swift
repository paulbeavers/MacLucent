import Foundation
import Compression

/// Converts a QCOW2 disk image (what most cloud images ship as) to the raw format
/// Virtualization.framework boots — so Lucent needs no qemu-img. Handles QCOW2 v2/v3 with
/// zlib-compressed clusters; the output is sparse (unallocated and zero clusters are holes).
enum QCOW2 {
    static func isQCOW2(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data([0x51, 0x46, 0x49, 0xFB]) // "QFI\xfb"
    }

    static func convert(_ input: URL, to output: URL, progress: ((Double) -> Void)? = nil) throws {
        let src = try FileHandle(forReadingFrom: input)
        defer { try? src.close() }
        let header = try read(src, at: 0, count: 112)
        guard header.prefix(4) == Data([0x51, 0x46, 0x49, 0xFB]) else { throw VMError.message("Not a QCOW2 image") }
        let version = be32(header, 4)
        guard version == 2 || version == 3 else { throw VMError.message("Unsupported QCOW2 version \(version)") }
        guard be64(header, 8) == 0 else { throw VMError.message("QCOW2 images with a backing file aren't supported") }
        let clusterBits = Int(be32(header, 20))
        let virtualSize = be64(header, 24)
        guard be32(header, 32) == 0 else { throw VMError.message("Encrypted QCOW2 images aren't supported") }
        let l1Size = Int(be32(header, 36))
        let l1Offset = be64(header, 40)
        if version == 3 {
            let incompatible = be64(header, 72)
            if incompatible & (1 << 4) != 0 { throw VMError.message("QCOW2 extended L2 entries aren't supported") }
            let headerLength = Int(be32(header, 100))
            if incompatible & (1 << 3) != 0, headerLength > 104, header[104] != 0 {
                throw VMError.message("QCOW2 zstd compression isn't supported")
            }
        }
        let clusterSize = 1 << clusterBits
        let l2Entries = clusterSize / 8
        let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00 // bits 9–55
        // Compressed descriptor: host offset in the low (62 − (clusterBits − 8)) bits, then the
        // count of additional 512-byte sectors.
        let compressedShift = UInt64(62 - (clusterBits - 8))
        let compressedOffsetMask = (UInt64(1) << compressedShift) - 1
        let sectorsMask = (UInt64(1) << (62 - compressedShift)) - 1

        FileManager.default.createFile(atPath: output.path, contents: nil)
        let dst = try FileHandle(forWritingTo: output)
        defer { try? dst.close() }

        let l1 = try read(src, at: l1Offset, count: l1Size * 8)
        var cluster = [UInt8](repeating: 0, count: clusterSize)
        for i in 0..<l1Size {
            progress?(Double(i) / Double(max(1, l1Size)))
            let l2Offset = be64(l1, i * 8) & offsetMask
            guard l2Offset != 0 else { continue }
            let l2 = try read(src, at: l2Offset, count: clusterSize)
            for j in 0..<l2Entries {
                let guestOffset = (UInt64(i) * UInt64(l2Entries) + UInt64(j)) << UInt64(clusterBits)
                guard guestOffset < virtualSize else { break }
                let entry = be64(l2, j * 8)
                if entry & (1 << 62) != 0 {
                    let host = entry & compressedOffsetMask
                    let sectors = (entry >> compressedShift) & sectorsMask
                    let length = Int((sectors + 1) * 512 - (host & 511))
                    let packed = try read(src, at: host, count: length, allowShort: true)
                    let n = packed.withUnsafeBytes { p in
                        compression_decode_buffer(&cluster, clusterSize,
                                                  p.bindMemory(to: UInt8.self).baseAddress!, packed.count,
                                                  nil, COMPRESSION_ZLIB)
                    }
                    guard n > 0 else { throw VMError.message("Couldn't decompress a QCOW2 cluster") }
                    if n < clusterSize { cluster.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress! + n, 0, clusterSize - n) } }
                    try writeIfNonZero(dst, Data(cluster), at: guestOffset)
                } else {
                    let host = entry & offsetMask
                    if host == 0 || entry & 1 != 0 { continue } // unallocated or all-zero
                    try writeIfNonZero(dst, try read(src, at: host, count: clusterSize), at: guestOffset)
                }
            }
        }
        try dst.truncate(atOffset: virtualSize)
        progress?(1)
    }

    /// Zero clusters stay holes, so the raw file takes only the space the data needs.
    private static func writeIfNonZero(_ h: FileHandle, _ data: Data, at offset: UInt64) throws {
        let allZero = data.withUnsafeBytes { p -> Bool in
            let words = p.bindMemory(to: UInt64.self)
            for w in words where w != 0 { return false }
            return true
        }
        guard !allZero else { return }
        try h.seek(toOffset: offset)
        try h.write(contentsOf: data)
    }

    private static func read(_ h: FileHandle, at offset: UInt64, count: Int, allowShort: Bool = false) throws -> Data {
        try h.seek(toOffset: offset)
        let d = try h.read(upToCount: count) ?? Data()
        guard d.count == count || allowShort else { throw VMError.message("QCOW2 image is truncated") }
        return d
    }

    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }

    private static func be64(_ d: Data, _ o: Int) -> UInt64 {
        d.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    }
}
