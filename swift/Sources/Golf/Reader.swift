// Reader.swift — read-only access to .golf files with indexed range queries.

import Foundation

/// Read-only accessor for a golf file, loaded fully into memory.
///
/// Opening validates the footer, block index, and header (magic + CRC32C) and
/// decodes the metadata. ``query(start:end:)`` then binary-searches the block
/// index so that only blocks overlapping the requested range are touched;
/// untouched blocks are never decompressed. Files are immutable after sealing,
/// so instances are safe to share across reads.
public struct GolfReader {
    /// Validated fixed header of the file.
    public let header: GolfHeader
    /// Decoded header metadata (empty when none was written).
    public let metadata: [MetadataEntry]
    /// Block-index descriptors in file order.
    public let descriptors: [BlockDescriptor]

    private let data: [UInt8]
    private let recordSize: Int

    /// Total records in the file (from the validated header).
    public var recordCount: UInt64 { header.recordCount }

    /// Inclusive `[min, max]` timestamp span of the file.
    public var timestampRange: ClosedRange<UInt64> {
        header.minTimestamp...max(header.minTimestamp, header.maxTimestamp)
    }

    /// Parses an in-memory golf file image.
    public init(data: [UInt8]) throws {
        self.data = data
        guard data.count >= Golf.fixedHeaderSize + Golf.footerSize else {
            throw GolfError.fileTooSmall(data.count)
        }

        // Footer → block index → header; each step is checksum-validated.
        let footer = try Footer.decode(Array(data[(data.count - Golf.footerSize)...]))
        let indexStart = Int(footer.indexOffset)
        let indexEnd = indexStart + Int(footer.blockCount) * Golf.blockDescriptorSize
        guard indexStart >= 0, indexEnd <= data.count - Golf.footerSize else {
            throw GolfError.corruptedIndex("index range \(indexStart)..\(indexEnd) outside file")
        }
        let indexBytes = Array(data[indexStart..<indexEnd])
        guard CRC32C.checksum(indexBytes) == footer.indexCrc else {
            throw GolfError.crcMismatch("block index")
        }

        var descs: [BlockDescriptor] = []
        descs.reserveCapacity(Int(footer.blockCount))
        for i in 0..<Int(footer.blockCount) {
            descs.append(try BlockDescriptor.decode(indexBytes, offset: i * Golf.blockDescriptorSize))
        }
        self.descriptors = descs

        self.header = try GolfHeader.decode(Array(data[0..<Golf.fixedHeaderSize]))

        if header.metadataLength > 0 {
            let metaStart = Golf.fixedHeaderSize
            let metaEnd = metaStart + header.metadataLength
            guard metaEnd <= data.count else {
                throw GolfError.truncatedMetadata("metadata length exceeds file")
            }
            self.metadata = try decodeMetadata(Array(data[metaStart..<metaEnd]))
        } else {
            self.metadata = []
        }

        self.recordSize = 8 + header.recordValueSize
    }

    /// Loads and parses the file at `url`.
    public init(contentsOf url: URL) throws {
        try self.init(data: Array(Data(contentsOf: url)))
    }

    /// Loads and parses the file at `path`.
    public static func open(_ path: String) throws -> GolfReader {
        try GolfReader(contentsOf: URL(fileURLWithPath: path))
    }

    /// Returns every record whose timestamp falls inside `range`, ascending.
    ///
    /// Only blocks overlapping the range are read and decompressed; within each
    /// boundary block the scan is narrowed by binary search on timestamps.
    public func query(_ range: ClosedRange<UInt64>) throws -> [Record] {
        try query(start: range.lowerBound, end: range.upperBound)
    }

    /// Returns every record with `startTs <= timestamp <= endTs`, ascending.
    public func query(start startTs: UInt64, end endTs: UInt64) throws -> [Record] {
        guard !descriptors.isEmpty else { return [] }
        let firstIdx = findFirstBlock(descriptors, startTs)
        let lastIdx = findLastBlock(descriptors, endTs)
        guard firstIdx >= 0, lastIdx >= 0, firstIdx <= lastIdx else { return [] }

        var results: [Record] = []
        for bi in firstIdx...lastIdx {
            let desc = descriptors[bi]
            let raw = try decompressedBlock(desc)

            let recStart = bi == firstIdx ? binarySearchFirst(raw, recordSize: recordSize, count: desc.recordCount, target: startTs) : 0
            let recEnd = bi == lastIdx ? binarySearchLast(raw, recordSize: recordSize, count: desc.recordCount, target: endTs) : desc.recordCount - 1

            guard recStart <= recEnd else { continue }
            for i in recStart...recEnd {
                let ts = readTimestamp(raw, i, recordSize: recordSize)
                if ts >= startTs && ts <= endTs {
                    results.append(extractRecord(raw, i, recordValueSize: header.recordValueSize))
                }
            }
        }
        return results
    }

    /// Loads the block described by `desc` and verifies its CRC32C.
    private func decompressedBlock(_ desc: BlockDescriptor) throws -> [UInt8] {
        let start = Int(desc.blockOffset)
        let end = start + desc.compressedSize
        guard start >= 0, end <= data.count, start <= end else {
            throw GolfError.corruptedIndex("block at \(start)..\(end) outside file")
        }
        let payload = Array(data[start..<end])

        let raw: [UInt8]
        switch header.compression {
        case .none:
            raw = payload
        case .lz4:
            guard payload.count >= 4 else { throw GolfError.compressionError("LZ4 data too short") }
            let origSize = Int(LE.readU32(payload, 0))
            raw = try Lz4Block.decompress(Array(payload[4...]), outputSize: origSize)
        case .zstd:
            throw GolfError.compressionError("Zstd reading is not supported by this implementation")
        }

        guard CRC32C.checksum(raw) == desc.blockCrc else {
            throw GolfError.crcMismatch("block data")
        }
        return raw
    }
}
