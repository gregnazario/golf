// Crc32c.swift — software CRC-32/ISCSI (Castagnoli), poly 0x1EDC6F41 (reflected 0x82F63B78).

/// CRC-32C (Castagnoli) checksum, as used by every integrity field in a golf
/// file (header, block data — over the *uncompressed* bytes — and block index).
///
/// Implemented with a slice-by-one table so the package carries no external
/// dependencies; where hardware CRC32C is available the OS toolchain is free to
/// vectorize the table walk.
enum CRC32C {
    private static let polynomial: UInt32 = 0x82F6_3B78 // reflected Castagnoli

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (c >> 1) ^ polynomial : c >> 1
            }
            return c
        }
    }()

    /// Computes the CRC-32C of `data`, returned as an unsigned value in
    /// [0, 2^32).
    static func checksum(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Convenience for checksumming a slice of a buffer.
    static func checksum(_ data: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
