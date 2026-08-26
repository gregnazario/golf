// Writer.kt — append-then-seal construction of .golf files.

package golf

import java.io.File
import java.io.IOException

/**
 * Configuration for [GolfWriter].
 *
 * @property recordValueSize required size in bytes of every appended record's value.
 * @property tsResolution unit of the timestamps you will append (default nanoseconds).
 * @property compression block codec (default LZ4).
 * @property blockCapacity maximum records per data block — hence per index entry.
 *   Larger blocks compress better; smaller ones make narrow range queries cheaper.
 * @property metadata user-defined key/value pairs embedded in the header.
 */
data class WriterConfig(
    val recordValueSize: Int,
    val tsResolution: TimestampResolution = TimestampResolution.NANOSECONDS,
    val compression: Compression = Compression.LZ4,
    val blockCapacity: Int = 8192,
    val metadata: List<MetadataEntry> = emptyList(),
)

/**
 * Accumulates `(timestamp, value)` records and seals them into an immutable
 * golf file.
 *
 * Usage: construct once, [append] any number of records in any order, then call
 * [seal] exactly once. Sealing sorts by timestamp (ties keep an
 * implementation-defined order), partitions into blocks of at most
 * [WriterConfig.blockCapacity], compresses each block independently, writes the
 * block index and footer, and returns the whole file as a byte array.
 */
class GolfWriter(private val config: WriterConfig) {
    private val records = ArrayList<Record>()
    private var sealed = false

    /** Number of records buffered so far. */
    val count: Int get() = records.size

    /**
     * Buffers one record. The value is copied and must be exactly
     * `recordValueSize` bytes long.
     */
    fun append(timestamp: ULong, value: ByteArray) {
        check(!sealed) { throw GolfException("writer already sealed") }
        if (value.size != config.recordValueSize) {
            throw GolfException(
                "value size mismatch: expected ${config.recordValueSize}, got ${value.size}",
            )
        }
        records.add(Record(timestamp, value.copyOf()))
    }

    /** Seals the accumulated records into a complete `.golf` file image. */
    fun seal(): ByteArray {
        if (sealed) throw GolfException("writer already sealed")
        if (records.isEmpty()) throw GolfException("no records to seal")
        sealed = true

        // Spec: sort ascending by timestamp; tie order is unspecified.
        records.sortWith(compareBy { it.timestamp })

        val capacity = maxOf(1, config.blockCapacity)
        val metaBytes = encodeMetadata(config.metadata)

        val parts = mutableListOf<ByteArray>()
        parts.add(
            GolfHeader(
                recordValueSize = config.recordValueSize,
                tsResolution = config.tsResolution,
                compression = config.compression,
                blockCapacity = capacity,
                minTimestamp = records.first().timestamp,
                maxTimestamp = records.last().timestamp,
                recordCount = records.size.toULong(),
                metadataLength = metaBytes.size,
            ).encode(),
        )
        if (metaBytes.isNotEmpty()) parts.add(metaBytes)

        var offset = (FIXED_HEADER_SIZE + metaBytes.size).toULong()
        val descriptors = mutableListOf<BlockDescriptor>()

        var index = 0
        while (index < records.size) {
            val end = minOf(index + capacity, records.size)
            val chunk = records.subList(index, end)
            val raw = serializeBlock(chunk, config.recordValueSize)
            val compressed: ByteArray = when (config.compression) {
                Compression.NONE -> raw
                Compression.LZ4 -> lePrefixed(uncompressedCount = raw.size, payload = Lz4Block.compress(raw))
                Compression.ZSTD ->
                    throw GolfException("Zstd writing is not supported by this implementation")
            }

            descriptors.add(
                BlockDescriptor(
                    minTs = chunk.first().timestamp,
                    maxTs = chunk.last().timestamp,
                    blockOffset = offset,
                    compressedSize = compressed.size,
                    uncompressedSize = raw.size,
                    recordCount = chunk.size,
                    blockCrc = Crc32c.checksum(raw),
                ),
            )
            parts.add(compressed)
            offset += compressed.size.toULong()
            index += capacity
        }

        val indexOffset = offset
        val indexBytes = descriptors.flatMap { it.encode().toList() }.toByteArray()
        parts.add(indexBytes)
        parts.add(Footer(indexOffset, descriptors.size.toULong(), Crc32c.checksum(indexBytes)).encode())

        return concat(parts)
    }

    /** Seals directly to [file], replacing any existing content.
     *  @throws IOException when the file cannot be written. */
    fun sealTo(file: File) {
        file.writeBytes(seal())
    }

    private fun lePrefixed(uncompressedCount: Int, payload: ByteArray): ByteArray {
        val out = ByteArray(4 + payload.size)
        Le.putU32(uncompressedCount.toLong(), out, 0)
        payload.copyInto(out, 4)
        return out
    }

    private fun concat(parts: List<ByteArray>): ByteArray {
        val total = parts.sumOf { it.size }
        val out = ByteArray(total)
        var pos = 0
        for (p in parts) { p.copyInto(out, pos); pos += p.size }
        return out
    }
}
