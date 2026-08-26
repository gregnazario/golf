// Writer.swift — append-then-seal construction of .golf files.

import Foundation

/// Configuration for ``GolfWriter``.
public struct WriterConfig: Sendable {
    /// Required size in bytes of every appended record's value.
    public var recordValueSize: Int
    /// Unit of the timestamps you will append. Default `.nanoseconds`.
    public var tsResolution: TimestampResolution
    /// Block codec. Default `.lz4`.
    public var compression: Compression
    /// Maximum records per data block (hence per index entry). Default `8192`.
    /// Larger blocks compress better; smaller blocks make narrow range queries cheaper.
    public var blockCapacity: Int
    /// User-defined key/value pairs embedded in the header.
    public var metadata: [MetadataEntry]

    public init(
        recordValueSize: Int,
        tsResolution: TimestampResolution = .nanoseconds,
        compression: Compression = .lz4,
        blockCapacity: Int = 8192,
        metadata: [MetadataEntry] = []
    ) {
        self.recordValueSize = recordValueSize
        self.tsResolution = tsResolution
        self.compression = compression
        self.blockCapacity = blockCapacity
        self.metadata = metadata
    }
}

/// Accumulates `(timestamp, value)` records and seals them into an immutable
/// golf file.
///
/// Usage: configure once, `append` any number of records in any order, then
/// call ``seal()`` exactly once. Sealing sorts by timestamp, partitions into
/// blocks of up to ``WriterConfig/blockCapacity``, compresses each block
/// independently, writes the block index and footer, and returns the whole
/// file as a byte buffer.
public final class GolfWriter {
    private let config: WriterConfig
    private var records: [Record] = []
    private var sealed = false

    /// Number of records buffered so far.
    public var count: Int { records.count }

    /// - Parameter config: see ``WriterConfig``.
    public init(config: WriterConfig) {
        self.config = config
    }

    /// Buffers one record. The value is copied and must be exactly
    /// `recordValueSize` bytes long.
    public func append(timestamp: UInt64, value: [UInt8]) throws {
        if sealed { throw GolfError.writerAlreadySealed }
        guard value.count == config.recordValueSize else {
            throw GolfError.valueSizeMismatch(expected: config.recordValueSize, actual: value.count)
        }
        records.append(Record(timestamp: timestamp, value: value))
    }

    /// Convenience that builds the value from a little-endian integer.
    ///
    /// The integer is serialized with shift-based byte extraction (endian-
    /// independent on any host), then zero-padded in the high-order bytes to
    /// `recordValueSize` (or truncated to its low 8 bytes when smaller).
    public func append(timestamp: UInt64, intValue: UInt64) throws {
        let size = max(config.recordValueSize, 0)
        let raw = intValue.bytes()
        if size > 8 {
            var padded = [UInt8](repeating: 0, count: size)
            padded.replaceSubrange(0..<8, with: raw)
            try append(timestamp: timestamp, value: padded)
        } else {
            try append(timestamp: timestamp, value: Array(raw[0..<min(8, size)]))
        }
    }

    /// Seals the accumulated records and returns the complete `.golf` file image.
    public func seal() throws -> [UInt8] {
        if sealed { throw GolfError.writerAlreadySealed }
        guard !records.isEmpty else { throw GolfError.noRecords }
        sealed = true

        // Spec: sort ascending; ties keep implementation-defined order.
        records.sort { $0.timestamp < $1.timestamp }

        let capacity = max(1, config.blockCapacity)
        let metaBytes = try encodeMetadata(config.metadata)

        var parts: [[UInt8]] = []
        parts.append(
            GolfHeader(
                recordValueSize: config.recordValueSize,
                tsResolution: config.tsResolution,
                compression: config.compression,
                blockCapacity: capacity,
                minTimestamp: records.first!.timestamp,
                maxTimestamp: records.last!.timestamp,
                recordCount: UInt64(records.count),
                metadataLength: metaBytes.count
            ).encode()
        )
        if !metaBytes.isEmpty { parts.append(metaBytes) }

        var offset = UInt64(Golf.fixedHeaderSize + metaBytes.count)
        var descriptors: [BlockDescriptor] = []

        var index = 0
        while index < records.count {
            let chunk = Array(records[index..<Swift.min(index + capacity, records.count)])
            let raw = serializeBlock(chunk, recordValueSize: config.recordValueSize)

            let compressed: [UInt8]
            switch config.compression {
            case .none:
                compressed = raw
            case .lz4:
                compressed = lePrefixed(uncompressedCount: raw.count,
                                        payload: Lz4Block.compress(raw))
            case .zstd:
                throw GolfError.compressionError("Zstd writing is not supported by this implementation")
            }

            descriptors.append(
                BlockDescriptor(
                    minTs: chunk.first!.timestamp,
                    maxTs: chunk.last!.timestamp,
                    blockOffset: offset,
                    compressedSize: compressed.count,
                    uncompressedSize: raw.count,
                    recordCount: chunk.count,
                    blockCrc: CRC32C.checksum(raw)
                )
            )
            parts.append(compressed)
            offset += UInt64(compressed.count)
            index += capacity
        }

        let indexOffset = offset
        let indexBytes = descriptors.flatMap { $0.encode() }
        parts.append(indexBytes)
        parts.append(
            Footer(
                indexOffset: indexOffset,
                blockCount: UInt64(descriptors.count),
                indexCrc: CRC32C.checksum(indexBytes)
            ).encode()
        )

        return parts.flatMap { $0 }
    }

    /// Seals directly to a file at `url`, replacing any existing file.
    public func seal(to url: URL) throws {
        let data = Data(try seal())
        try data.write(to: url, options: .atomic)
    }

    /// `[u32 LE uncompressed size][payload]` — the on-disk LZ4 convention
    /// shared with the reference implementations (`lz4_flex` prepend-size).
    private func lePrefixed(uncompressedCount: Int, payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4 + payload.count)
        LE.writeU32(UInt32(uncompressedCount), into: &out, 0)
        out.replaceSubrange(4..<out.count, with: payload)
        return out
    }
}

private extension UInt64 {
    func bytes() -> [UInt8] {
        (0..<8).map { UInt8((self >> (8 * $0)) & 0xFF) }
    }
}
