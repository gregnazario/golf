// Lz4Block.swift — self-contained LZ4 raw-block compressor and decompressor.
//
// Golf stores LZ4-compressed blocks in the raw LZ4 *block* format (not framed),
// prefixed with the uncompressed size as a little-endian uint32 — the same
// "prepend size" convention used by the reference implementations' `lz4_flex`
// bindings, Rust included. The prefix lives at the golf layer (see Core.swift);
// everything here operates on bare LZ4 block payloads.

/// Minimal-but-conformant implementation of the LZ4 block format.
///
/// The decoder parses arbitrary conformant blocks. The encoder uses a greedy
/// single-slot hash-chain matcher and obeys the format's safety rules the same
/// way the reference encoder does: minimum match length 4, offsets 1...65535,
/// no match starting within the last `mflimit` (12) bytes of the input, and
/// match extension capped so the final `lastLiterals` (5) bytes are always
/// emitted as a literal run — strict decoders such as liblz4 reject blocks
/// that end inside a match. Its ratio trails the reference `liblz4`, but the
/// output is bit-compatible with anything that speaks the block format.
enum Lz4Block {
    private static let minMatch = 4
    private static let mflimit = 12       // matches may not start in the last 12 bytes
    private static let lastLiterals = 5
    private static let hashLog = 14
    private static let hashSize = 1 << hashLog

    /// Worst-case compressed size for `size` input bytes.
    static func compressBound(_ size: Int) -> Int {
        size + size / 255 + 16
    }

    // MARK: Compress

    /// Compresses `src` into raw LZ4 block bytes.
    ///
    /// Always makes progress: for incompressible or tiny inputs the result is a
    /// single all-literals sequence, which is itself a valid block.
    static func compress(_ src: [UInt8]) -> [UInt8] {
        let n = src.count
        var out: [UInt8] = []
        out.reserveCapacity(compressBound(n))

        if n == 0 {
            out.append(0x00)
            return out
        }

        var table = [Int32](repeating: -1, count: hashSize)
        var anchor = 0   // start of pending literals
        var i = 0        // forward scan position

        while n - i >= mflimit + minMatch {
            let h = hash4(src, i)
            let candidate = table[h]
            // Record the current position immediately (before any `i`
            // mutation below) — a deferred write would observe the mutated i.
            table[h] = Int32(i)

            var tookMatch = false
            if candidate >= 0 {
                let cand = Int(candidate)
                let distance = i - cand
                if distance >= 1 && distance <= 65_535,
                   src[cand] == src[i],
                   src[cand + 1] == src[i + 1],
                   src[cand + 2] == src[i + 2],
                   src[cand + 3] == src[i + 3] {
                    // Match confirmed; extend like the reference encoder, whose
                    // match limit excludes the final `lastLiterals` bytes so the
                    // block always ends with a >=5-byte literal run (strict
                    // decoders such as liblz4 reject anything shorter).
                    var matchLen = minMatch
                    while i + matchLen < n - lastLiterals,
                          src[cand + matchLen] == src[i + matchLen] {
                        matchLen += 1
                    }

                    emitSequence(&out, src, anchor..<i, distance: distance, matchLen: matchLen)
                    anchor = i + matchLen
                    i = anchor
                    tookMatch = true
                }
            }

            if !tookMatch {
                i += 1
            }
        }

        // Trailing bytes become the mandatory final literal run.
        emitLastLiterals(&out, src, anchor..<n)
        return out
    }

    private static func hash4(_ src: [UInt8], _ i: Int) -> Int {
        let v = UInt32(src[i])
            | (UInt32(src[i + 1]) << 8)
            | (UInt32(src[i + 2]) << 16)
            | (UInt32(src[i + 3]) << 24)
        // Knuth's multiplicative hash; keep the top `hashLog` bits.
        let hashed = (v &* 2_654_435_761) >> (32 - hashLog)
        return Int(hashed)
    }

    /// Writes one [literals][match] sequence given its leading literal range.
    private static func emitSequence(
        _ out: inout [UInt8], _ src: [UInt8], _ literals: Range<Int>,
        distance: Int, matchLen: Int
    ) {
        precondition(matchLen >= minMatch)
        let litLen = literals.count
        let lenCode = matchLen - minMatch

        var token: UInt8 = litLen < 15 ? UInt8(litLen) << 4 : 0xF0
        if lenCode < 15 {
            token |= UInt8(lenCode)
        } else {
            token |= 0x0F
        }

        // Wire order: token | literal-length ext | literals | offset | match-length ext.
        out.append(token)
        if litLen >= 15 { writeExtendedLength(&out, litLen - 15) }
        out.append(contentsOf: src[literals])
        appendLE16(&out, UInt16(distance))
        if lenCode >= 15 { writeExtendedLength(&out, lenCode - 15) }
    }

    private static func writeExtendedLength(_ out: inout [UInt8], _ remaining: Int) {
        var rem = remaining
        while rem >= 255 {
            out.append(255)
            rem -= 255
        }
        out.append(UInt8(rem))
    }

    private static func appendLE16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8(v >> 8))
    }

    /// Writes the mandatory trailing literal-only sequence.
    private static func emitLastLiterals(_ out: inout [UInt8], _ src: [UInt8], _ range: Range<Int>) {
        let runLen = range.count
        if runLen >= 15 {
            out.append(0xF0)
            writeExtendedLength(&out, runLen - 15)
        } else {
            out.append(UInt8(runLen) << 4)
        }
        out.append(contentsOf: src[range])
    }

    // MARK: Decompress

    /// Decompresses a raw LZ4 block. `outputSize` bounds the destination; use
    /// the size recorded next to the block in a golf file.
    static func decompress(_ src: [UInt8], outputSize: Int) throws -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: outputSize)
        var ip = 0      // input cursor
        var op = 0      // output cursor

        while ip < src.count {
            let token = src[ip]
            ip += 1

            // ── Literals ──
            var litLen = Int(token >> 4)
            if litLen == 15 {
                var extra: Int
                repeat {
                    guard ip < src.count else { throw GolfError.compressionError("truncated LZ4 literal length") }
                    extra = Int(src[ip]); ip += 1
                    litLen += extra
                    if litLen > outputSize { throw GolfError.compressionError("LZ4 literal length overflow") }
                } while extra == 255
            }
            guard ip + litLen <= src.count else { throw GolfError.compressionError("truncated LZ4 literals") }
            guard op + litLen <= outputSize else { throw GolfError.compressionError("LZ4 output overflow") }
            if litLen > 0 {
                dst.replaceSubrange(op..<op + litLen, with: src[ip..<ip + litLen])
                op += litLen
                ip += litLen
            }
            guard ip < src.count else { break } // final sequence ends with literals

            // ── Match ──
            guard ip + 2 <= src.count else { throw GolfError.compressionError("truncated LZ4 match offset") }
            let offset = Int(src[ip]) | (Int(src[ip + 1]) << 8)
            ip += 2
            guard offset >= 1 && offset <= op else { throw GolfError.compressionError("invalid LZ4 offset \(offset)") }

            var matchLen = Int(token & 0x0F) + minMatch
            if (token & 0x0F) == 15 {
                var extra: Int
                repeat {
                    guard ip < src.count else { throw GolfError.compressionError("truncated LZ4 match length") }
                    extra = Int(src[ip]); ip += 1
                    matchLen += extra
                    if matchLen > outputSize { throw GolfError.compressionError("LZ4 match length overflow") }
                } while extra == 255
            }
            guard op + matchLen <= outputSize else { throw GolfError.compressionError("LZ4 output overflow") }

            // Offsets smaller than the match length mean overlap: copy forward
            // one byte at a time so earlier output feeds later bytes.
            var sourcePos = op - offset
            var end = op
            while end < op + matchLen {
                dst[end] = dst[sourcePos]
                sourcePos += 1
                end += 1
            }
            op += matchLen
        }

        guard op == outputSize else {
            throw GolfError.compressionError("LZ4 produced \(op) bytes, expected \(outputSize)")
        }
        return dst
    }
}
