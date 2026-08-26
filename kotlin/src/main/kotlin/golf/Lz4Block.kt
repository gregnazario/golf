// Lz4Block.kt — self-contained LZ4 raw-block compressor and decompressor.
//
// Golf stores LZ4-compressed blocks in the raw LZ4 *block* format (not
// framed). The 4-byte little-endian uncompressed-size prefix lives at the golf
// layer (see Core.kt / Writer.kt); everything here operates on bare LZ4 block
// payloads.

package golf

/**
 * Minimal-but-conformant implementation of the LZ4 block format, ported from
 * the Swift implementation in this repository so both produce identical
 * sequences for identical input.
 *
 * The decoder parses arbitrary conformant blocks. The encoder uses a greedy
 * single-slot hash matcher and obeys the format's safety rules the same way
 * the reference encoder does: minimum match length 4, offsets 1..65535, no
 * match starting within the last `mflimit` (12) bytes of input, and match
 * extension capped so the final `lastLiterals` (5) bytes are always emitted
 * as a literal run — strict decoders such as liblz4 reject blocks that end
 * inside a match. Its ratio trails reference `liblz4`, but output is
 * compatible with anything that speaks the block format.
 */
object Lz4Block {
    private const val MIN_MATCH = 4
    private const val MFLIMIT = 12      // matches may not start in the last 12 bytes
    private const val LAST_LITERALS = 5 // final literal run guaranteed >= this
    private const val HASH_LOG = 14

    /** Worst-case compressed size for [size] input bytes. */
    fun compressBound(size: Int): Int = size + size / 255 + 16

    /** Compresses [src] into raw LZ4 block bytes. Always succeeds; tiny or
     *  incompressible inputs come back as a single all-literals sequence. */
    fun compress(src: ByteArray): ByteArray {
        val n = src.size
        if (n == 0) return byteArrayOf(0)

        val out = ByteArray(compressBound(n))
        var op = 0

        val table = IntArray(1 shl HASH_LOG) { -1 }
        var anchor = 0   // start of pending literals
        var i = 0        // forward scan position

        while (n - i >= MFLIMIT + MIN_MATCH) {
            val h = hash4(src, i)
            val candidate = table[h]
            // Record the current position immediately (before any mutation of
            // i below) so later candidates compare against the right offset.
            table[h] = i

            if (candidate >= 0 && candidate < i) {
                val cand = candidate
                val distance = i - cand
                if (distance in 1..65535 &&
                    src[cand] == src[i] &&
                    src[cand + 1] == src[i + 1] &&
                    src[cand + 2] == src[i + 2] &&
                    src[cand + 3] == src[i + 3]
                ) {
                    // Match confirmed; extend like the reference encoder,
                    // whose match limit excludes the final LAST_LITERALS
                    // bytes so the block always ends with a >=5-byte literal
                    // run (strict decoders reject anything shorter).
                    var matchLen = MIN_MATCH
                    while (i + matchLen < n - LAST_LITERALS &&
                           src[cand + matchLen] == src[i + matchLen]) {
                        matchLen++
                    }

                    op = emitSequence(out, op, src, anchor, i, distance, matchLen)
                    anchor = i + matchLen
                    i = anchor
                    continue
                }
            }
            i++
        }

        // Trailing bytes become the mandatory final literal run.
        op = emitLastLiterals(out, op, src, anchor, n)
        return out.copyOf(op)
    }

    private fun hash4(src: ByteArray, i: Int): Int {
        val v = (src[i].toUInt().and(0xFFu)) or
            ((src[i + 1].toUInt().and(0xFFu)) shl 8) or
            ((src[i + 2].toUInt().and(0xFFu)) shl 16) or
            ((src[i + 3].toUInt().and(0xFFu)) shl 24)
        // Knuth's multiplicative hash; keep the top HASH_LOG bits.
        return ((v * 2654435761u) shr (32 - HASH_LOG)).toInt()
    }

    /** Wire order: token | literal-length ext | literals | offset | match ext. */
    private fun emitSequence(
        out: ByteArray, opIn: Int, src: ByteArray,
        litStart: Int, litEnd: Int, distance: Int, matchLen: Int,
    ): Int {
        require(matchLen >= MIN_MATCH)
        var op = opIn
        val litLen = litEnd - litStart
        val lenCode = matchLen - MIN_MATCH

        var token = (if (litLen < 15) (litLen shl 4) else 0xF0)
        if (lenCode < 15) token = token or lenCode else token = token or 0x0F

        out[op++] = token.toByte()
        if (litLen >= 15) {
            var rem = litLen - 15
            while (rem >= 255) { out[op++] = 255.toByte(); rem -= 255 }
            out[op++] = rem.toByte()
        }
        System.arraycopy(src, litStart, out, op, litLen); op += litLen
        out[op++] = (distance and 0xFF).toByte()
        out[op++] = ((distance shr 8) and 0xFF).toByte()
        if (lenCode >= 15) {
            var rem = lenCode - 15
            while (rem >= 255) { out[op++] = 255.toByte(); rem -= 255 }
            out[op++] = rem.toByte()
        }
        return op
    }

    /** Writes the mandatory trailing literal-only sequence. */
    private fun emitLastLiterals(out: ByteArray, opIn: Int, src: ByteArray, start: Int, end: Int): Int {
        var op = opIn
        val runLen = end - start
        if (runLen >= 15) {
            out[op++] = 0xF0.toByte()
            var rem = runLen - 15
            while (rem >= 255) { out[op++] = 255.toByte(); rem -= 255 }
            out[op++] = rem.toByte()
        } else {
            out[op++] = (runLen shl 4).toByte()
        }
        System.arraycopy(src, start, out, op, runLen)
        return op + runLen
    }

    /**
     * Decompresses a raw LZ4 block. [outputSize] bounds the destination; use
     * the uncompressed size recorded next to the block in a golf file.
     */
    fun decompress(src: ByteArray, offset: Int, length: Int, outputSize: Int): ByteArray {
        val dst = ByteArray(outputSize)
        var ip = offset          // input cursor
        val ipEnd = offset + length
        var op = 0               // output cursor

        while (ip < ipEnd) {
            val token = src[ip++].toInt() and 0xFF

            // ── Literals ──
            var litLen = token ushr 4
            if (litLen == 15) {
                do {
                    checkInput(ip < ipEnd, "truncated LZ4 literal length")
                    val extra = src[ip++].toInt() and 0xFF
                    litLen += extra
                    check(litLen <= outputSize) { "LZ4 literal length overflow" }
                } while (extra == 255)
            }
            checkInput(ip + litLen <= ipEnd, "truncated LZ4 literals")
            check(op + litLen <= outputSize) { "LZ4 output overflow" }
            if (litLen > 0) {
                System.arraycopy(src, ip, dst, op, litLen)
                op += litLen
                ip += litLen
            }
            if (ip >= ipEnd) break           // final sequence ends with literals

            // ── Match ──
            checkInput(ip + 2 <= ipEnd, "truncated LZ4 match offset")
            val off = (src[ip].toInt() and 0xFF) or ((src[ip + 1].toInt() and 0xFF) shl 8)
            ip += 2
            if (off < 1 || off > op) throw GolfException("invalid LZ4 offset $off")

            var matchLen = (token and 0x0F) + MIN_MATCH
            if ((token and 0x0F) == 15) {
                do {
                    checkInput(ip < ipEnd, "truncated LZ4 match length")
                    val extra = src[ip++].toInt() and 0xFF
                    matchLen += extra
                    check(matchLen <= outputSize) { "LZ4 match length overflow" }
                } while (extra == 255)
            }
            check(op + matchLen <= outputSize) { "LZ4 output overflow" }

            // Offsets smaller than the match length mean overlap: copy forward
            // one byte at a time so earlier output feeds later bytes.
            var sp = op - off
            repeat(matchLen) { dst[it + op] = dst[sp++] }
            op += matchLen
        }

        if (op != outputSize) {
            throw GolfException("LZ4 produced $op bytes, expected $outputSize")
        }
        return dst
    }

    private fun checkInput(condition: Boolean, message: String) {
        if (!condition) throw GolfException(message)
    }
}
