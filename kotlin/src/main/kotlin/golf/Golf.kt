// Golf.kt — format constants, enums, and error types.

package golf

/** Fixed size of the header's fixed portion, in bytes. */
const val FIXED_HEADER_SIZE = 64

/** Size of one block-index descriptor, in bytes. */
const val BLOCK_DESCRIPTOR_SIZE = 40

/** Size of the trailing footer, in bytes. */
const val FOOTER_SIZE = 32

/** The only format version this implementation reads and writes. */
const val FORMAT_VERSION: Int = 1

/** ASCII magic at the start of every golf file. */
val HEADER_MAGIC = "GOLF".toByteArray(Charsets.US_ASCII)

/** ASCII magic inside the footer (`GOLF` reversed). */
val FOOTER_MAGIC = "FLOG".toByteArray(Charsets.US_ASCII)

/**
 * The unit in which record timestamps are expressed.
 *
 * Timestamps are unsigned 64-bit integers ([ULong]); the unit is declared once
 * in the file header and applies to every record in the file.
 */
enum class TimestampResolution(val code: UByte) {
    NANOSECONDS(0u),
    MICROSECONDS(1u),
    MILLISECONDS(2u);

    companion object {
        fun fromCode(code: UByte): TimestampResolution =
            entries.firstOrNull { it.code == code } ?: NANOSECONDS
    }
}

/**
 * The compression codec used for data blocks.
 *
 * Each block is compressed independently. [NONE] stores blocks verbatim. LZ4
 * uses the raw *block* format with a 4-byte little-endian uncompressed-size
 * prefix (the "prepend size" convention of Rust's `lz4_flex`). Zstandard files
 * can be read by the Rust, Go, and Python implementations but not written or
 * read here; doing so raises a [GolfException] with an explicit message.
 */
enum class Compression(val code: UByte) {
    NONE(0u),
    LZ4(1u),
    ZSTD(2u);

    companion object {
        fun fromCode(code: UByte): Compression? = entries.firstOrNull { it.code == code }
    }
}

/**
 * Error raised by all golf writer/reader failures (bad magic or CRC, size
 * mismatches, unsupported codecs, corrupt structures).
 */
class GolfException(message: String) : RuntimeException(message)
