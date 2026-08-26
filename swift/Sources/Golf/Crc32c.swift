// Crc32c.swift — software CRC-32/ISCSI (Castagnoli), poly 0x1EDC6F41 (reflected 0x82F63B78).

/// CRC-32C (Castagnoli) checksum, as used by every integrity field in a golf
/// file (header, block data — over the *uncompressed* bytes — and block index).
///
/// Implemented with slice-by-8 so the package carries no external dependencies
/// while keeping per-query cost reasonable on multi-megabyte blocks. This is a
/// pure table walk: it will not be turned into hardware `crc32` instructions
/// by the compiler; if a hardware path is ever needed, integrate zlib's
/// `crc32_z`/CommonCrypto explicitly.
enum CRC32C {
    private static let polynomial: UInt32 = 0x82F6_3B78 // reflected Castagnoli

    /// Eight slice tables. `tables[0]` is the classic byte-wise table; each
    /// subsequent level folds the previous level through the base table:
    /// `t[k][i] = t[0][ t[k-1][i] & 0xFF ] ^ (t[k-1][i] >> 8)`.
    private static let tables: [[UInt32]] = {
        var t0 = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (c >> 1) ^ polynomial : c >> 1
            }
            t0[i] = c
        }
        var all = [t0]
        for _ in 1..<8 {
            let prev = all.last!
            all.append((0..<256).map { i in t0[Int(prev[i] & 0xFF)] ^ (prev[i] >> 8) })
        }
        return all
    }()

    /// Computes the CRC-32C of `data`, returned as an unsigned value in
    /// [0, 2^32).
    ///
    /// Processes eight bytes per iteration from the little-endian halves of
    /// the input word (standard slice-by-8), then finishes any remainder one
    /// byte at a time.
    static func checksum(_ data: [UInt8]) -> UInt32 {
        guard !data.isEmpty else { return 0 }
        return checksumSlice(data, offset: 0, count: data.count)
    }

    /// Convenience for checksumming a slice of a buffer.
    static func checksum(_ data: ArraySlice<UInt8>) -> UInt32 {
        guard !data.isEmpty else { return 0 }
        // Copying the slice keeps the hot loop contiguous and bounds-free.
        return checksum([UInt8](data))
    }

    private static func checksumSlice(_ data: [UInt8], offset: Int, count: Int) -> UInt32 {
        let t = tables
        var crc: UInt32 = 0xFFFF_FFFF
        var i = offset
        let end = offset + count
        let simdEnd = end - ((end - offset) % 8)

        while i < simdEnd {
            let x = crc ^ LE.readU32(data, i)
            crc = t[7][Int(x & 0xFF)]
                ^ t[6][Int((x >> 8) & 0xFF)]
                ^ t[5][Int((x >> 16) & 0xFF)]
                ^ t[4][Int((x >> 24) & 0xFF)]
                ^ t[3][Int(data[i + 4])]
                ^ t[2][Int(data[i + 5])]
                ^ t[1][Int(data[i + 6])]
                ^ t[0][Int(data[i + 7])]
            i += 8
        }
        while i < end {
            crc = t[0][Int((crc ^ UInt32(data[i])) & 0xFF)] ^ (crc >> 8)
            i += 1
        }
        return crc ^ 0xFFFF_FFFF
    }
}
