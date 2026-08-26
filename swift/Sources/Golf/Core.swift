// Core.swift — data structures and little-endian encoding/decoding primitives.

// MARK: - Byte helpers

enum LE {
    static func readU16(_ b: [UInt8], _ off: Int) -> UInt16 {
        UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
    }

    static func readU32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off])
            | (UInt32(b[off + 1]) << 8)
            | (UInt32(b[off + 2]) << 16)
            | (UInt32(b[off + 3]) << 24)
    }

    static func readU64(_ b: [UInt8], _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in stride(from: 7, through: 0, by: -1) {
            v = (v << 8) | UInt64(b[off + k])
        }
        return v
    }

    static func writeU16(_ v: UInt16, into b: inout [UInt8], _ off: Int) {
        b[off] = UInt8(v & 0xFF)
        b[off + 1] = UInt8(v >> 8)
    }

    static func writeU32(_ v: UInt32, into b: inout [UInt8], _ off: Int) {
        b[off] = UInt8(v & 0xFF)
        b[off + 1] = UInt8((v >> 8) & 0xFF)
        b[off + 2] = UInt8((v >> 16) & 0xFF)
        b[off + 3] = UInt8((v >> 24) & 0xFF)
    }

    static func writeU64(_ v: UInt64, into b: inout [UInt8], _ off: Int) {
        for k in 0..<8 {
            b[off + k] = UInt8((v >> (8 * k)) & 0xFF)
        }
    }
}

// MARK: - Public model types

/// The fixed portion of a golf file header (see SPEC.md §1).
public struct GolfHeader: Equatable, Sendable {
    /// Format version this header was written under.
    public var version: UInt16
    /// Reserved flag bits; must be zero for version 1.
    public var flags: UInt16
    /// Size of each record's value in bytes (timestamps excluded).
    public var recordValueSize: Int
    /// Unit applying to every timestamp in the file.
    public var tsResolution: TimestampResolution
    /// Codec used for all data blocks.
    public var compression: Compression
    /// Maximum number of records stored per data block.
    public var blockCapacity: Int
    /// Smallest timestamp present in the file.
    public var minTimestamp: UInt64
    /// Largest timestamp present in the file.
    public var maxTimestamp: UInt64
    /// Total records across all blocks.
    public var recordCount: UInt64
    /// Length in bytes of the variable metadata section that follows the header.
    public var metadataLength: Int

    public init(
        version: UInt16 = Golf.formatVersion,
        flags: UInt16 = 0,
        recordValueSize: Int,
        tsResolution: TimestampResolution,
        compression: Compression,
        blockCapacity: Int,
        minTimestamp: UInt64,
        maxTimestamp: UInt64,
        recordCount: UInt64,
        metadataLength: Int
    ) {
        self.version = version
        self.flags = flags
        self.recordValueSize = recordValueSize
        self.tsResolution = tsResolution
        self.compression = compression
        self.blockCapacity = blockCapacity
        self.minTimestamp = minTimestamp
        self.maxTimestamp = maxTimestamp
        self.recordCount = recordCount
        self.metadataLength = metadataLength
    }
}

extension GolfHeader {
    /// Encodes the fixed 64-byte header, embedding the CRC over its first 56 bytes.
    public func encode() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: Golf.fixedHeaderSize)
        buf.replaceSubrange(0..<4, with: headerMagic)
        LE.writeU16(version, into: &buf, 4)
        LE.writeU16(flags, into: &buf, 6)
        LE.writeU32(UInt32(recordValueSize), into: &buf, 8)
        buf[12] = tsResolution.rawValue
        buf[13] = compression.rawValue
        LE.writeU32(UInt32(blockCapacity), into: &buf, 14)
        // 18..28 reserved (zeros)
        LE.writeU64(minTimestamp, into: &buf, 28)
        LE.writeU64(maxTimestamp, into: &buf, 36)
        LE.writeU64(recordCount, into: &buf, 44)
        LE.writeU32(UInt32(metadataLength), into: &buf, 52)
        LE.writeU32(CRC32C.checksum(buf[0..<56]), into: &buf, 56)
        // 60..64 padding (zeros)
        return buf
    }

    /// Decodes and validates a fixed header (`magic`, `version`, CRC).
    public static func decode(_ buf: [UInt8]) throws -> GolfHeader {
        guard buf.count >= Golf.fixedHeaderSize else {
            throw GolfError.truncated(expected: Golf.fixedHeaderSize, actual: buf.count)
        }
        guard Array(buf[0..<4]) == headerMagic else { throw GolfError.invalidMagic("header") }
        let version = LE.readU16(buf, 4)
        guard version == Golf.formatVersion else { throw GolfError.unsupportedVersion(version) }

        let storedCRC = LE.readU32(buf, 56)
        let computedCRC = CRC32C.checksum(buf[0..<56])
        guard storedCRC == computedCRC else { throw GolfError.crcMismatch("header") }

        // Unknown enum bytes must fail loudly rather than silently remap:
        // an unrecognized codec misreported as "none" would only surface as
        // a confusing block-CRC error later.
        guard let resolution = TimestampResolution(rawValue: buf[12]) else {
            throw GolfError.unsupportedTimestampResolution(buf[12])
        }
        guard let compression = Compression(rawValue: buf[13]) else {
            throw GolfError.unsupportedCompressionCodec(buf[13])
        }

        return GolfHeader(
            version: version,
            flags: LE.readU16(buf, 6),
            recordValueSize: Int(LE.readU32(buf, 8)),
            tsResolution: resolution,
            compression: compression,
            blockCapacity: Int(LE.readU32(buf, 14)),
            minTimestamp: LE.readU64(buf, 28),
            maxTimestamp: LE.readU64(buf, 36),
            recordCount: LE.readU64(buf, 44),
            metadataLength: Int(LE.readU32(buf, 52))
        )
    }
}

/// A user-defined key/value pair stored in the variable header metadata
/// (see SPEC.md §1 "Variable Metadata"). Both key and value are UTF-8 strings;
/// readers must ignore keys they do not understand.
public struct MetadataEntry: Equatable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One entry of the block index describing where a compressed data block lives
/// and how to validate it (see SPEC.md §3).
public struct BlockDescriptor: Equatable, Sendable {
    /// First timestamp stored in the block.
    public var minTs: UInt64
    /// Last timestamp stored in the block.
    public var maxTs: UInt64
    /// Absolute file offset of the (possibly compressed) block payload.
    public var blockOffset: UInt64
    /// Stored payload length in bytes.
    public var compressedSize: Int
    /// Uncompressed length in bytes; equals `(8 + recordValueSize) * recordCount`.
    public var uncompressedSize: Int
    /// Number of records inside the block.
    public var recordCount: Int
    /// CRC32C of the *uncompressed* block bytes.
    public var blockCrc: UInt32

    public init(
        minTs: UInt64, maxTs: UInt64, blockOffset: UInt64,
        compressedSize: Int, uncompressedSize: Int,
        recordCount: Int, blockCrc: UInt32
    ) {
        self.minTs = minTs
        self.maxTs = maxTs
        self.blockOffset = blockOffset
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.recordCount = recordCount
        self.blockCrc = blockCrc
    }

    /// Encodes the descriptor into exactly 40 bytes.
    public func encode() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: Golf.blockDescriptorSize)
        LE.writeU64(minTs, into: &buf, 0)
        LE.writeU64(maxTs, into: &buf, 8)
        LE.writeU64(blockOffset, into: &buf, 16)
        LE.writeU32(UInt32(compressedSize), into: &buf, 24)
        LE.writeU32(UInt32(uncompressedSize), into: &buf, 28)
        LE.writeU32(UInt32(recordCount), into: &buf, 32)
        LE.writeU32(blockCrc, into: &buf, 36)
        return buf
    }

    /// Decodes one descriptor from `buf` starting at `offset`.
    public static func decode(_ buf: [UInt8], offset: Int = 0) throws -> BlockDescriptor {
        guard offset >= 0, offset + Golf.blockDescriptorSize <= buf.count else {
            throw GolfError.truncated(expected: Golf.blockDescriptorSize, actual: buf.count - offset)
        }
        return BlockDescriptor(
            minTs: LE.readU64(buf, offset),
            maxTs: LE.readU64(buf, offset + 8),
            blockOffset: LE.readU64(buf, offset + 16),
            compressedSize: Int(LE.readU32(buf, offset + 24)),
            uncompressedSize: Int(LE.readU32(buf, offset + 28)),
            recordCount: Int(LE.readU32(buf, offset + 32)),
            blockCrc: LE.readU32(buf, offset + 36)
        )
    }
}

/// A single time-series sample: an unsigned timestamp plus a fixed-size value.
public struct Record: Equatable, Sendable {
    public var timestamp: UInt64
    public var value: [UInt8]

    public init(timestamp: UInt64, value: [UInt8]) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// The trailing 32-byte footer that anchors readers to the block index
/// (see SPEC.md §4).
public struct Footer: Equatable, Sendable {
    /// Absolute file offset of the block-index section.
    public var indexOffset: UInt64
    /// Number of descriptors in the block index.
    public var blockCount: UInt64
    /// CRC32C covering the whole block index.
    public var indexCrc: UInt32

    public init(indexOffset: UInt64, blockCount: UInt64, indexCrc: UInt32) {
        self.indexOffset = indexOffset
        self.blockCount = blockCount
        self.indexCrc = indexCrc
    }

    /// Encodes the footer into exactly 32 bytes.
    public func encode() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: Golf.footerSize)
        LE.writeU64(indexOffset, into: &buf, 0)
        LE.writeU64(blockCount, into: &buf, 8)
        LE.writeU32(indexCrc, into: &buf, 16)
        buf.replaceSubrange(20..<24, with: footerMagic)
        LE.writeU32(CRC32C.checksum(buf[0..<24]), into: &buf, 24)
        // 28..32 padding (zeros)
        return buf
    }

    /// Decodes and validates a footer (`magic` + CRC).
    public static func decode(_ buf: [UInt8]) throws -> Footer {
        guard buf.count >= Golf.footerSize else {
            throw GolfError.truncated(expected: Golf.footerSize, actual: buf.count)
        }
        guard Array(buf[20..<24]) == footerMagic else { throw GolfError.invalidMagic("footer") }
        let storedCRC = LE.readU32(buf, 24)
        let computedCRC = CRC32C.checksum(buf[0..<24])
        guard storedCRC == computedCRC else { throw GolfError.crcMismatch("footer") }
        return Footer(
            indexOffset: LE.readU64(buf, 0),
            blockCount: LE.readU64(buf, 8),
            indexCrc: LE.readU32(buf, 16)
        )
    }
}

// MARK: - Metadata

/// Encodes metadata entries into the wire format: repeated
/// `u16 keyLen | key | u16 valueLen | value` tuples with UTF-8 strings.
public func encodeMetadata(_ entries: [MetadataEntry]) throws -> [UInt8] {
    func appendU16(_ v: UInt16, to out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8(v >> 8))
    }

    var out: [UInt8] = []
    for e in entries {
        let kb = Array(e.key.utf8)
        let vb = Array(e.value.utf8)
        guard kb.count <= UInt16.max, vb.count <= UInt16.max else {
            throw GolfError.compressionError("metadata string exceeds 65535 bytes")
        }
        appendU16(UInt16(kb.count), to: &out)
        out.append(contentsOf: kb)
        appendU16(UInt16(vb.count), to: &out)
        out.append(contentsOf: vb)
    }
    return out
}

/// Decodes metadata entries, validating each pair is fully present.
public func decodeMetadata(_ data: [UInt8]) throws -> [MetadataEntry] {
    var entries: [MetadataEntry] = []
    var off = 0

    func takeString(_ len: Int, what: String) throws -> String {
        guard off + len <= data.count else {
            throw GolfError.truncatedMetadata("truncated metadata \(what)")
        }
        defer { off += len }
        return String(decoding: data[off..<off + len], as: UTF8.self)
    }

    while off < data.count {
        guard off + 2 <= data.count else {
            throw GolfError.truncatedMetadata("truncated metadata key length")
        }
        let keyLen = Int(LE.readU16(data, off)); off += 2
        let key = try takeString(keyLen, what: "key")

        guard off + 2 <= data.count else {
            throw GolfError.truncatedMetadata("truncated metadata value length")
        }
        let valLen = Int(LE.readU16(data, off)); off += 2
        let value = try takeString(valLen, what: "value")

        entries.append(MetadataEntry(key: key, value: value))
    }
    return entries
}

// MARK: - Blocks

/// Packs sorted records into the flat uncompressed block layout
/// (`u64 timestamp | value` per record, little-endian, zero padding).
func serializeBlock(_ records: [Record], recordValueSize: Int) -> [UInt8] {
    let recordSize = 8 + recordValueSize
    var buf = [UInt8](repeating: 0, count: records.count * recordSize)
    for (i, rec) in records.enumerated() {
        let off = i * recordSize
        LE.writeU64(rec.timestamp, into: &buf, off)
        let n = min(rec.value.count, recordValueSize)
        buf.replaceSubrange(off + 8..<off + 8 + n, with: rec.value[rec.value.startIndex..<rec.value.startIndex + n])
    }
    return buf
}

/// Reads the record at `index` from an uncompressed block buffer.
func extractRecord(_ data: [UInt8], _ index: Int, recordValueSize: Int) -> Record {
    let recordSize = 8 + recordValueSize
    let off = index * recordSize
    return Record(
        timestamp: LE.readU64(data, off),
        value: Array(data[(off + 8)..<(off + recordSize)])
    )
}

/// Reads the little-endian timestamp at record slot `index` without copying
/// the value — used for in-block binary search.
func readTimestamp(_ data: [UInt8], _ index: Int, recordSize: Int) -> UInt64 {
    LE.readU64(data, index * recordSize)
}

// MARK: - Binary search

/// Index of the first block whose `maxTs >= target`, or `-1` if none qualify.
///
/// Together with ``findLastBlock`` this brackets the blocks that may contain a
/// `[start, end]` timestamp range.
func findFirstBlock(_ descriptors: [BlockDescriptor], _ target: UInt64) -> Int {
    var lo = 0, hi = descriptors.count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if descriptors[mid].maxTs < target { lo = mid + 1 } else { hi = mid }
    }
    return lo < descriptors.count ? lo : -1
}

/// Index of the last block whose `minTs <= target`, or `-1` if none qualify.
func findLastBlock(_ descriptors: [BlockDescriptor], _ target: UInt64) -> Int {
    var lo = 0, hi = descriptors.count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if descriptors[mid].minTs <= target { lo = mid + 1 } else { hi = mid }
    }
    return lo > 0 ? lo - 1 : -1
}

/// First record index in `data` whose timestamp is `>= target`.
func binarySearchFirst(_ data: [UInt8], recordSize: Int, count: Int, target: UInt64) -> Int {
    var lo = 0, hi = count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if readTimestamp(data, mid, recordSize: recordSize) < target {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}

/// Last record index in `data` whose timestamp is `<= target`; 0 when empty.
func binarySearchLast(_ data: [UInt8], recordSize: Int, count: Int, target: UInt64) -> Int {
    var lo = 0, hi = count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if readTimestamp(data, mid, recordSize: recordSize) <= target {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return max(0, lo - 1)
}
