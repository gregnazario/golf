// Golf.swift — format constants, enums, and error types.

/// Root namespace for the golf file format library.
public enum Golf {
    /// Fixed size of the header's fixed portion, in bytes.
    public static let fixedHeaderSize = 64

    /// Size of one block-index descriptor, in bytes.
    public static let blockDescriptorSize = 40

    /// Size of the trailing footer, in bytes.
    public static let footerSize = 32

    /// The only format version this implementation reads and writes.
    public static let formatVersion: UInt16 = 1
}

/// ASCII magic at the start of every golf file.
let headerMagic: [UInt8] = Array("GOLF".utf8)

/// ASCII magic inside the footer (`GOLF` reversed).
let footerMagic: [UInt8] = Array("FLOG".utf8)

/// The unit in which record timestamps are expressed.
///
/// Timestamps are unsigned 64-bit integers; the unit is declared once in the
/// file header and applies to every record in the file.
public enum TimestampResolution: UInt8, Sendable, CaseIterable {
    case nanoseconds = 0
    case microseconds = 1
    case milliseconds = 2
}

/// The compression codec used for data blocks.
///
/// Each block is compressed independently. `none` stores blocks verbatim.
/// LZ4 uses the raw *block* format with a 4-byte little-endian uncompressed-size
/// prefix (the "prepend size" convention of `lz4_flex`). Zstandard files can be
/// read by the Rust, Go, and Python implementations but not written or read here;
/// see ``GolfError/unsupportedCompression(_:)``.
public enum Compression: UInt8, Sendable, CaseIterable {
    case none = 0
    case lz4 = 1
    case zstd = 2
}

/// Errors thrown by golf writer and reader operations.
public enum GolfError: Error, Equatable, Sendable {
    /// The file is shorter than a minimal (header + footer) golf file.
    case fileTooSmall(Int)

    /// A required field count truncated mid-structure.
    case truncated(expected: Int, actual: Int)

    /// Header/footer magic did not match.
    case invalidMagic(String)

    /// File version differs from `formatVersion` (1).
    case unsupportedVersion(UInt16)

    /// A CRC32C checksum did not match the stored value.
    case crcMismatch(String)

    /// Metadata section ended in the middle of a key/value pair.
    case truncatedMetadata(String)

    /// Appended value length does not equal `recordValueSize`.
    case valueSizeMismatch(expected: Int, actual: Int)

    /// Attempted to append to or re-seal an already sealed writer.
    case writerAlreadySealed

    /// Sealing with zero records appended.
    case noRecords

    /// LZ4/Zstd payload malformed or unsupported by this implementation.
    case compressionError(String)

    /// Block index range was invalid against file size.
    case corruptedIndex(String)
}
