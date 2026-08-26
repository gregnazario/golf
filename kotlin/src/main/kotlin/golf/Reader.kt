// Reader.kt — read-only access to .golf files with indexed range queries.

package golf

import java.io.File

/**
 * Read-only accessor for a golf file, loaded fully into memory.
 *
 * Opening validates the footer, block index, and header (magic + CRC32C) and
 * decodes the metadata. [query] then binary-searches the block index so only
 * blocks overlapping the requested range are touched; untouched blocks are
 * never decompressed. Files are immutable after sealing, so instances are safe
 * to share across reads.
 *
 * Per-block data integrity is verified lazily: each block's CRC32C is checked
 * as it is first decompressed during a query.
 */
class GolfReader private constructor(
    /** Validated fixed header of the file. */
    val header: GolfHeader,
    /** Decoded header metadata (empty when none was written). */
    val metadata: List<MetadataEntry>,
    /** Block-index descriptors in file order. */
    val descriptors: List<BlockDescriptor>,
    private val data: ByteArray,
) {
    private val recordSize = 8 + header.recordValueSize

    /** Total records in the file (from the validated header). */
    val recordCount: ULong get() = header.recordCount

    /** Inclusive `[min, max]` timestamp span of the file. */
    val timestampRange: ClosedRange<ULong>
        get() = header.minTimestamp..maxOf(header.minTimestamp, header.maxTimestamp)

    companion object {
        /** Loads and parses the file at [path]. */
        fun open(path: String): GolfReader = fromBytes(File(path).readBytes())

        /** Loads and parses the given [file]. */
        fun open(file: File): GolfReader = fromBytes(file.readBytes())

        /**
         * Parses an in-memory golf file image. The array is retained by the
         * reader (not copied), so callers must not mutate it afterwards.
         */
        fun fromBytes(data: ByteArray): GolfReader {
            if (data.size < FIXED_HEADER_SIZE + FOOTER_SIZE) {
                throw GolfException("file too small: ${data.size} bytes")
            }

            // Footer → block index → header; each step is checksum-validated.
            // Offset arithmetic runs in the unsigned domain with bounds
            // checked *before* any narrowing, so crafted u64s surface as
            // typed errors instead of truncation or OutOfMemoryError.
            val footer = Footer.decode(data.copyOfRange(data.size - FOOTER_SIZE, data.size))
            if (footer.indexOffset > data.size.toULong() ||
                footer.blockCount > (data.size / BLOCK_DESCRIPTOR_SIZE).toULong()
            ) {
                throw GolfException(
                    "corrupted index: offset ${footer.indexOffset}, ${footer.blockCount} blocks outside file",
                )
            }
            val indexStart = footer.indexOffset.toInt()
            val indexEnd = indexStart + footer.blockCount.toInt() * BLOCK_DESCRIPTOR_SIZE // bounded ⇒ no overflow
            if (indexEnd > data.size - FOOTER_SIZE) {
                throw GolfException(
                    "corrupted index: range $indexStart..$indexEnd outside file",
                )
            }
            val indexBytes = data.copyOfRange(indexStart, indexEnd)
            if (Crc32c.checksum(indexBytes) != footer.indexCrc) {
                throw GolfException("block index CRC mismatch")
            }
            // Capacity hint is clamped: a hostile blockCount can't make the
            // ArrayList preallocation itself fail.
            val descriptors = ArrayList<BlockDescriptor>(minOf(footer.blockCount.toInt(), 4096))
            repeat(footer.blockCount.toInt()) { i ->
                descriptors.add(BlockDescriptor.decode(indexBytes, i * BLOCK_DESCRIPTOR_SIZE))
            }

            val header = GolfHeader.decode(data.copyOf(0.coerceAtLeast(FIXED_HEADER_SIZE)))

            val metadata = if (header.metadataLength > 0) {
                val end = FIXED_HEADER_SIZE + header.metadataLength
                if (end > data.size) throw GolfException("metadata length exceeds file")
                decodeMetadata(data.copyOfRange(FIXED_HEADER_SIZE, end))
            } else emptyList()

            return GolfReader(header, metadata, descriptors, data)
        }
    }

    /**
     * Returns every record with `startTs <= timestamp <= endTs`, ascending.
     *
     * Only blocks overlapping the range are read and decompressed; within each
     * boundary block the scan is narrowed by timestamp binary search.
     */
    fun query(startTs: ULong, endTs: ULong): List<Record> {
        if (descriptors.isEmpty()) return emptyList()
        val firstIdx = findFirstBlock(descriptors, startTs)
        val lastIdx = findLastBlock(descriptors, endTs)
        if (firstIdx < 0 || lastIdx < 0 || firstIdx > lastIdx) return emptyList()

        val results = ArrayList<Record>()
        for (bi in firstIdx..lastIdx) {
            val desc = descriptors[bi]
            val raw = decompressedBlock(desc)

            val recStart = if (bi == firstIdx) {
                binarySearchFirst(raw, recordSize, desc.recordCount, startTs)
            } else 0
            val recEnd = if (bi == lastIdx) {
                binarySearchLast(raw, recordSize, desc.recordCount, endTs)
            } else desc.recordCount - 1

            if (recStart > recEnd) continue
            for (i in recStart..recEnd) {
                val ts = readTimestamp(raw, i, recordSize)
                if (ts >= startTs && ts <= endTs) {
                    results.add(extractRecord(raw, i, header.recordValueSize))
                }
            }
        }
        return results
    }

    /** Returns every record whose timestamp falls inside [range], ascending. */
    fun query(range: ClosedRange<ULong>): List<Record> = query(range.start, range.endInclusive)

    /** Loads the block described by [desc] and verifies its CRC32C. */
    private fun decompressedBlock(desc: BlockDescriptor): ByteArray {
        // Narrow only after unsigned-domain bounds checks.
        if (desc.blockOffset > data.size.toULong() ||
            desc.compressedSize.toLong() !in 0..data.size.toLong()
        ) {
            throw GolfException("corrupted block: offset ${desc.blockOffset}, size ${desc.compressedSize} outside file")
        }
        val start = desc.blockOffset.toInt()
        val end = start + desc.compressedSize
        if (end < start || end > data.size) {
            throw GolfException("corrupted block: range $start..$end outside file")
        }
        val payload = data.copyOfRange(start, end)

        val raw: ByteArray = when (header.compression) {
            Compression.NONE -> payload
            Compression.LZ4 -> {
                if (payload.size < 4) throw GolfException("LZ4 data too short")
                val origSize = Le.u32(payload, 0).toInt()
                Lz4Block.decompress(payload, 4, payload.size - 4, origSize)
            }
            Compression.ZSTD ->
                throw GolfException("Zstd reading is not supported by this implementation")
        }

        if (Crc32c.checksum(raw) != desc.blockCrc) {
            throw GolfException("block CRC mismatch")
        }
        return raw
    }
}
