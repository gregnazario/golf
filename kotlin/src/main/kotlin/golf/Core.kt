// Core.kt — data structures and little-endian encoding/decoding primitives.

package golf

import java.util.zip.CRC32C

/** CRC-32C (Castagnoli) checksum, as used by every integrity field in a golf
 *  file (header, block data — over the *uncompressed* bytes — and index). */
object Crc32c {
    /** Computes the CRC-32C of [data] over [length] bytes starting at [offset]. */
    fun checksum(data: ByteArray, offset: Int = 0, length: Int = data.size): UInt {
        val crc = CRC32C()
        crc.update(data, offset, length)
        return crc.value.toUInt()
    }
}

// MARK: little-endian byte helpers

internal object Le {
    fun u16(b: ByteArray, off: Int): Int =
        (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)

    fun u32(b: ByteArray, off: Int): Long {
        var v = 0L
        for (k in 3 downTo 0) v = (v shl 8) or (b[off + k].toLong() and 0xFF)
        return v
    }

    /** Reads a stored uint64; the result keeps its full 64-bit value as ULong. */
    fun u64(b: ByteArray, off: Int): ULong {
        var v = 0L
        for (k in 7 downTo 0) v = (v shl 8) or (b[off + k].toLong() and 0xFF)
        return v.toULong()
    }

    fun putU16(v: Int, b: ByteArray, off: Int) {
        b[off] = (v and 0xFF).toByte()
        b[off + 1] = ((v shr 8) and 0xFF).toByte()
    }

    fun putU32(v: Long, b: ByteArray, off: Int) {
        for (k in 0..3) b[off + k] = ((v shr (8 * k)) and 0xFF).toByte()
    }

    fun putU64(v: ULong, b: ByteArray, off: Int) {
        val bits = v.toLong()
        for (k in 0..7) b[off + k] = ((bits ushr (8 * k)) and 0xFF).toByte()
    }

    /** Appends a uint16 to a growable buffer. */
    fun appendU16(builder: MutableList<Byte>, v: Int) {
        builder.add((v and 0xFF).toByte())
        builder.add(((v shr 8) and 0xFF).toByte())
    }
}

/**
 * The fixed portion of a golf file header (see SPEC.md §1).
 */
data class GolfHeader(
    /** Format version this header was written under. */
    val version: Int = FORMAT_VERSION,
    /** Reserved flag bits; must be zero for version 1. */
    val flags: Int = 0,
    /** Size of each record's value in bytes (timestamps excluded). */
    val recordValueSize: Int,
    /** Unit applying to every timestamp in the file. */
    val tsResolution: TimestampResolution,
    /** Codec used for all data blocks. */
    val compression: Compression,
    /** Maximum number of records stored per data block. */
    val blockCapacity: Int,
    /** Smallest timestamp present in the file. */
    val minTimestamp: ULong,
    /** Largest timestamp present in the file. */
    val maxTimestamp: ULong,
    /** Total records across all blocks. */
    val recordCount: ULong,
    /** Length in bytes of the variable metadata section following the header. */
    val metadataLength: Int,
) {
    companion object {
        private const val HEADER_CRC_OFFSET = 56
        private const val HEADER_CRC_COVERAGE = 56

        /** Decodes and validates a fixed header (`magic`, `version`, CRC). */
        fun decode(buf: ByteArray): GolfHeader {
            if (buf.size < FIXED_HEADER_SIZE) {
                throw GolfException("expected $FIXED_HEADER_SIZE bytes, got ${buf.size}")
            }
            if (!buf.contentEquals(HEADER_MAGIC, end = 4)) {
                throw GolfException("invalid header magic")
            }
            val version = Le.u16(buf, 4)
            if (version != FORMAT_VERSION) throw GolfException("unsupported version: $version")

            val storedCrc = Le.u32(buf, HEADER_CRC_OFFSET)
            val computedCrc = Crc32c.checksum(buf, 0, HEADER_CRC_COVERAGE)
            if (storedCrc.toULong() != computedCrc.toULong()) {
                throw GolfException("header CRC mismatch: expected ${computedCrc.toString(16)}, got ${storedCrc.toString(16)}")
            }

            return GolfHeader(
                version = version,
                flags = Le.u16(buf, 6),
                recordValueSize = Le.u32(buf, 8).toInt(),
                tsResolution = TimestampResolution.fromCode(buf[12].toUByte()),
                compression = Compression.fromCode(buf[13].toUByte()) ?: Compression.NONE,
                blockCapacity = Le.u32(buf, 14).toInt(),
                minTimestamp = Le.u64(buf, 28),
                maxTimestamp = Le.u64(buf, 36),
                recordCount = Le.u64(buf, 44),
                metadataLength = Le.u32(buf, 52).toInt(),
            )
        }

        private fun ByteArray.contentEquals(other: ByteArray, end: Int): Boolean {
            if (size < end) return false
            for (i in 0 until end) if (this[i] != other[i]) return false
            return true
        }
    }

    /** Encodes the fixed 64-byte header, embedding the CRC over its first 56 bytes. */
    fun encode(): ByteArray {
        val buf = ByteArray(FIXED_HEADER_SIZE)
        HEADER_MAGIC.copyInto(buf)
        Le.putU16(version, buf, 4)
        Le.putU16(flags, buf, 6)
        Le.putU32(recordValueSize.toLong(), buf, 8)
        buf[12] = tsResolution.code.toByte()
        buf[13] = compression.code.toByte()
        Le.putU32(blockCapacity.toLong(), buf, 14)
        // 18..28 reserved (zeros)
        Le.putU64(minTimestamp, buf, 28)
        Le.putU64(maxTimestamp, buf, 36)
        Le.putU64(recordCount, buf, 44)
        Le.putU32(metadataLength.toLong(), buf, 52)
        Le.putU32(Crc32c.checksum(buf, 0, HEADER_CRC_COVERAGE).toLong(), buf, HEADER_CRC_OFFSET)
        // 60..64 padding (zeros)
        return buf
    }
}

/**
 * A user-defined key/value pair stored in the variable header metadata
 * (see SPEC.md §1 "Variable Metadata"). Both key and value are UTF-8 strings;
 * readers must ignore keys they do not understand.
 */
data class MetadataEntry(val key: String, val value: String)

/**
 * One entry of the block index describing where a compressed data block lives
 * and how to validate it (see SPEC.md §3).
 */
data class BlockDescriptor(
    /** First timestamp stored in the block. */
    val minTs: ULong,
    /** Last timestamp stored in the block. */
    val maxTs: ULong,
    /** Absolute file offset of the (possibly compressed) block payload. */
    val blockOffset: ULong,
    /** Stored payload length in bytes. */
    val compressedSize: Int,
    /** Uncompressed length in bytes; equals `(8 + recordValueSize) * recordCount`. */
    val uncompressedSize: Int,
    /** Number of records inside the block. */
    val recordCount: Int,
    /** CRC32C of the *uncompressed* block bytes. */
    val blockCrc: UInt,
) {
    /** Encodes the descriptor into exactly 40 bytes. */
    fun encode(): ByteArray {
        val buf = ByteArray(BLOCK_DESCRIPTOR_SIZE)
        Le.putU64(minTs, buf, 0)
        Le.putU64(maxTs, buf, 8)
        Le.putU64(blockOffset, buf, 16)
        Le.putU32(compressedSize.toLong(), buf, 24)
        Le.putU32(uncompressedSize.toLong(), buf, 28)
        Le.putU32(recordCount.toLong(), buf, 32)
        Le.putU32(blockCrc.toLong(), buf, 36)
        return buf
    }

    companion object {
        /** Decodes one descriptor from [buf] starting at [offset]. */
        fun decode(buf: ByteArray, offset: Int = 0): BlockDescriptor {
            if (offset < 0 || offset + BLOCK_DESCRIPTOR_SIZE > buf.size) {
                throw GolfException("expected $BLOCK_DESCRIPTOR_SIZE bytes")
            }
            return BlockDescriptor(
                minTs = Le.u64(buf, offset),
                maxTs = Le.u64(buf, offset + 8),
                blockOffset = Le.u64(buf, offset + 16),
                compressedSize = Le.u32(buf, offset + 24).toInt(),
                uncompressedSize = Le.u32(buf, offset + 28).toInt(),
                recordCount = Le.u32(buf, offset + 32).toInt(),
                blockCrc = Le.u32(buf, offset + 36).toUInt(),
            )
        }
    }
}

/** A single time-series sample: an unsigned timestamp plus a fixed-size value. */
data class Record(val timestamp: ULong, val value: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is Record && timestamp == other.timestamp && value.contentEquals(other.value)

    override fun hashCode(): Int = 31 * timestamp.hashCode() + value.contentHashCode()
}

/**
 * The trailing 32-byte footer that anchors readers to the block index
 * (see SPEC.md §4).
 */
data class Footer(
    /** Absolute file offset of the block-index section. */
    val indexOffset: ULong,
    /** Number of descriptors in the block index. */
    val blockCount: ULong,
    /** CRC32C covering the whole block index. */
    val indexCrc: UInt,
) {
    companion object {
        /** Decodes and validates a footer (`magic` + CRC). */
        fun decode(buf: ByteArray): Footer {
            if (buf.size < FOOTER_SIZE) throw GolfException("expected $FOOTER_SIZE bytes")
            if (!buf.copyOfRange(20, 24).contentEquals(FOOTER_MAGIC)) {
                throw GolfException("invalid footer magic")
            }
            val storedCrc = Le.u32(buf, 24)
            val computedCrc = Crc32c.checksum(buf, 0, 24)
            if (storedCrc.toULong() != computedCrc.toULong()) {
                throw GolfException("footer CRC mismatch")
            }
            return Footer(
                indexOffset = Le.u64(buf, 0),
                blockCount = Le.u64(buf, 8),
                indexCrc = Le.u32(buf, 16).toUInt(),
            )
        }
    }

    /** Encodes the footer into exactly 32 bytes. */
    fun encode(): ByteArray {
        val buf = ByteArray(FOOTER_SIZE)
        Le.putU64(indexOffset, buf, 0)
        Le.putU64(blockCount, buf, 8)
        Le.putU32(indexCrc.toLong(), buf, 16)
        FOOTER_MAGIC.copyInto(buf, 20)
        Le.putU32(Crc32c.checksum(buf, 0, 24).toLong(), buf, 24)
        // 28..32 padding (zeros)
        return buf
    }
}

/** Encodes metadata entries into the wire format: repeated
 *  `u16 keyLen | key | u16 valueLen | value` tuples with UTF-8 strings. */
fun encodeMetadata(entries: List<MetadataEntry>): ByteArray {
    val out = mutableListOf<Byte>()
    for (e in entries) {
        val kb = e.key.toByteArray(Charsets.UTF_8)
        val vb = e.value.toByteArray(Charsets.UTF_8)
        if (kb.size > UShort.MAX_VALUE.toInt() || vb.size > UShort.MAX_VALUE.toInt()) {
            throw GolfException("metadata string exceeds 65535 bytes")
        }
        Le.appendU16(out, kb.size); out.addAll(kb.toList())
        Le.appendU16(out, vb.size); out.addAll(vb.toList())
    }
    return out.toByteArray()
}

/** Decodes metadata entries, validating each pair is fully present. */
fun decodeMetadata(data: ByteArray): List<MetadataEntry> {
    val entries = mutableListOf<MetadataEntry>()
    var off = 0

    while (off < data.size) {
        if (off + 2 > data.size) throw GolfException("truncated metadata key length")
        val keyLen = Le.u16(data, off); off += 2
        if (off + keyLen > data.size) throw GolfException("truncated metadata key")
        val key = String(data, off, keyLen, Charsets.UTF_8); off += keyLen

        if (off + 2 > data.size) throw GolfException("truncated metadata value length")
        val valLen = Le.u16(data, off); off += 2
        if (off + valLen > data.size) throw GolfException("truncated metadata value")
        val value = String(data, off, valLen, Charsets.UTF_8); off += valLen

        entries.add(MetadataEntry(key, value))
    }
    return entries
}

/** Packs sorted records into the flat uncompressed block layout
 *  (`u64 timestamp | value` per record, little-endian, zero padding). */
internal fun serializeBlock(records: List<Record>, recordValueSize: Int): ByteArray {
    val recordSize = 8 + recordValueSize
    val buf = ByteArray(records.size * recordSize)
    records.forEachIndexed { i, rec ->
        val off = i * recordSize
        Le.putU64(rec.timestamp, buf, off)
        rec.value.copyInto(buf, off + 8, 0, minOf(rec.value.size, recordValueSize))
    }
    return buf
}

/** Reads the record at [index] from an uncompressed block buffer. */
internal fun extractRecord(data: ByteArray, index: Int, recordValueSize: Int): Record {
    val recordSize = 8 + recordValueSize
    val off = index * recordSize
    return Record(
        timestamp = Le.u64(data, off),
        value = data.copyOfRange(off + 8, off + recordSize),
    )
}

/** Reads the little-endian timestamp at record slot [index] without copying
 *  the value — used for in-block binary search. */
internal fun readTimestamp(data: ByteArray, index: Int, recordSize: Int): ULong =
    Le.u64(data, index * recordSize)

/** Index of the first block whose max_ts >= target, or -1 if none qualify.
 *
 *  Together with [findLastBlock] this brackets the blocks that may contain a
 *  `[start, end]` timestamp range. */
internal fun findFirstBlock(descriptors: List<BlockDescriptor>, target: ULong): Int {
    var lo = 0
    var hi = descriptors.size
    while (lo < hi) {
        val mid = lo + (hi - lo) / 2
        if (descriptors[mid].maxTs < target) lo = mid + 1 else hi = mid
    }
    return if (lo < descriptors.size) lo else -1
}

/** Index of the last block whose min_ts <= target, or -1 if none qualify. */
internal fun findLastBlock(descriptors: List<BlockDescriptor>, target: ULong): Int {
    var lo = 0
    var hi = descriptors.size
    while (lo < hi) {
        val mid = lo + (hi - lo) / 2
        if (descriptors[mid].minTs <= target) lo = mid + 1 else hi = mid
    }
    return if (lo > 0) lo - 1 else -1
}

/** First record index in [data] whose timestamp is >= target. */
internal fun binarySearchFirst(data: ByteArray, recordSize: Int, count: Int, target: ULong): Int {
    var lo = 0
    var hi = count
    while (lo < hi) {
        val mid = lo + (hi - lo) / 2
        if (readTimestamp(data, mid, recordSize) < target) lo = mid + 1 else hi = mid
    }
    return lo
}

/** Last record index in [data] whose timestamp is <= target; 0 when none match. */
internal fun binarySearchLast(data: ByteArray, recordSize: Int, count: Int, target: ULong): Int {
    var lo = 0
    var hi = count
    while (lo < hi) {
        val mid = lo + (hi - lo) / 2
        if (readTimestamp(data, mid, recordSize) <= target) lo = mid + 1 else hi = mid
    }
    return maxOf(0, lo - 1)
}
