// TestMain.kt — self-contained test suite runnable without JUnit or any
// third-party dependency, so `kotlinc` alone can verify the implementation:
//
//   kotlinc src/main/kotlin src/test/kotlin -include-runtime -d golf-tests.jar
//   java -jar golf-tests.jar <path-to>/testdata
//
// When built through Gradle instead, each `runSuite` function maps 1:1 onto a
// standard unit-test class; see kotlin/README.md.

package golf

import java.io.File

private var passed = 0
private val failures = mutableListOf<String>()

private fun suite(name: String, block: () -> Unit) {
    try {
        block()
        println("PASS $name")
    } catch (t: Throwable) {
        failures.add("$name: ${t.javaClass.simpleName}: ${t.message}")
        System.err.println("FAIL $name: ${t.javaClass.simpleName}: ${t.message}")
    }
}

private fun check(condition: Boolean, message: String) {
    if (!condition) throw AssertionError(message)
}

private fun checkEquals(expected: Any?, actual: Any?, message: String = "") {
    val e = when (expected) { is IntArray -> expected.toList(); is ByteArray -> expected.toList(); else -> expected }
    val a = when (actual) { is IntArray -> actual.toList(); is ByteArray -> actual.toList(); else -> actual }
    if (e != a) throw AssertionError("expected $e but got $a ${if (message.isEmpty()) "" else "($message)"}")
}

private inline fun <reified T : Throwable> checkThrows(messageContains: String = "", block: () -> Unit) {
    try {
        block()
        throw AssertionError("expected ${T::class.simpleName} to be thrown")
    } catch (t: Throwable) {
        if (t is AssertionError) throw t
        if (!T::class.isInstance(t)) throw AssertionError("expected ${T::class.simpleName}, got ${t.javaClass.simpleName}: ${t.message}")
        if (messageContains.isNotEmpty() && !(t.message ?: "").contains(messageContains, ignoreCase = true)) {
            throw AssertionError("message '${t.message}' does not contain '$messageContains'")
        }
    }
}

private fun makeValue(seed: Int, size: Int): ByteArray {
    val buf = ByteArray(size)
    for (i in 0 until size) buf[i] = ((seed + i) and 0xFF).toByte()
    return buf
}

fun main(args: Array<String>) {
    val testDataDir = args.firstOrNull() ?: "../testdata"

    Crc32cTests.run()
    Lz4BlockTests.run()
    WriterReaderTests.run()

    val fixtures = FixtureCompatTests(File(testDataDir))
    if (fixtures.hasFixtures()) fixtures.run() else println("SKIP fixture tests (no testdata found at $testDataDir)")

    println("=".repeat(60))
    if (failures.isEmpty()) {
        println("All Kotlin tests passed ($passed checks)")
    } else {
        System.err.println("${failures.size} test group(s) failed:")
        failures.forEach { System.err.println("  - $it") }
        kotlin.system.exitProcess(1)
    }
}

// ── CRC32C ─────────────────────────────────────────────────────────────────

private object Crc32cTests {
    fun run() = suite("CRC32C known answers") {
        checkEquals(0x00000000u, Crc32c.checksum(byteArrayOf()))
        checkEquals(0xC1D04330u, Crc32c.checksum("a".toByteArray()))
        checkEquals(0xE3069283u, Crc32c.checksum("123456789".toByteArray()))
        checkEquals(0xC99465AAu, Crc32c.checksum("hello world".toByteArray()))
        val sentence = "the quick brown fox jumps over the lazy dog".toByteArray()
        checkEquals(0x3C18F4D6u, Crc32c.checksum(sentence))
        // Slice API must agree with a standalone copy of the same region.
        checkEquals(
            Crc32c.checksum(sentence, 4, sentence.size - 4),
            Crc32c.checksum(sentence.copyOfRange(4, sentence.size)),
            "slice vs copy",
        )
        passed++
    }
}

// ── LZ4 block codec ────────────────────────────────────────────────────────

private object Lz4BlockTests {
    private fun deterministicBytes(n: Int, seed: Long = 12345): ByteArray {
        val v = ByteArray(n)
        var s = seed
        for (i in 0 until n) {
            s = s * 6364136223846793005L + 1442695040888963407L
            v[i] = ((s ushr 33) and 0xFF).toByte()
            if (i >= 17 && i % 5 == 0) v[i] = v[i - 17]
        }
        return v
    }

    private fun assertRoundtrip(input: ByteArray) {
        val compressed = Lz4Block.compress(input)
        check(compressed.size <= Lz4Block.compressBound(input.size), "output within bound")
        val output = Lz4Block.decompress(compressed, 0, compressed.size, input.size)
        checkEquals(input, output, "roundtrip size=${input.size}")
    }

    fun run() {
        suite("LZ4 roundtrip various sizes") {
            assertRoundtrip(byteArrayOf())
            for (n in listOf(1, 2, 3, 4, 12, 13, 15, 16, 17, 100, 4096, 65537)) {
                assertRoundtrip(deterministicBytes(n))
            }
            passed++
        }

        suite("LZ4 RLE pattern") {
            val rle = ByteArray(10_000) { 7 }
            rle[500] = 9
            assertRoundtrip(rle)
            passed++
        }

        suite("LZ4 repetitive text compresses well") {
            val sentence = "the quick brown fox ".toByteArray()
            val text = ByteArray(sentence.size * 600)
            for (r in 0 until 600) sentence.copyInto(text, r * sentence.size)
            val compressed = Lz4Block.compress(text)
            check(compressed.size < text.size / 3, "ratio: got ${compressed.size} for ${text.size}")
            assertRoundtrip(text)
            passed++
        }

        suite("LZ4 incompressible stays valid") {
            val random = deterministicBytes(50_000, seed = 999)
            assertRoundtrip(random)
            passed++
        }

        suite("LZ4 extended length encodings") {
            // A >14-byte unique literal prefix forces literal-length extension
            // bytes; appending a distant duplicate of the body forces a long
            // match with match-length extension bytes.
            val base = deterministicBytes(3_000, seed = 77)
            val input = base.toMutableList()
            "UNIQUE-LITERAL-HEADER-".toByteArray().forEach { input.add(it) }
            input.addAll(base.toList().subList(100, 2200))     // distant duplicate
            assertRoundtrip(input.toByteArray())
            passed++
        }

        suite("LZ4 corrupt payload throws") {
            val valid = Lz4Block.compress(deterministicBytes(200))
            valid[0] = (valid[0].toInt() xor 0xFF).toByte()
            checkThrows<GolfException>("") {
                Lz4Block.decompress(valid, 0, valid.size, 200)
            }
            passed++
        }
    }
}

// ── Writer/Reader behavior ─────────────────────────────────────────────────

private object WriterReaderTests {
    private fun build(pairs: List<Pair<Long, Int>>, config: WriterConfig): GolfReader =
        GolfWriter(config).let { w ->
            pairs.forEach { (ts, seed) -> w.append(ts.toULong(), makeValue(seed, config.recordValueSize)) }
            GolfReader.fromBytes(w.seal())
        }

    fun run() {
        suite("roundtrip no compression") {
            val pairs = (0 until 10).map { it * 1000L to it }
            val reader = build(pairs, WriterConfig(recordValueSize = 16, compression = Compression.NONE, blockCapacity = 4))

            checkEquals(10UL, reader.recordCount)
            checkEquals(0UL..9000UL, reader.timestampRange)
            check(reader.metadata.isEmpty(), "no metadata")
            checkEquals(3, reader.descriptors.size)

            val all = reader.query(0UL, 9000UL)
            checkEquals(10, all.size)
            all.forEachIndexed { i, rec ->
                checkEquals(i.toULong() * 1000UL, rec.timestamp, "ts $i")
                checkEquals(makeValue(i, 16), rec.value, "value $i")
            }

            checkEquals(listOf(3000UL, 4000UL, 5000UL), reader.query(2500UL, 5500UL).map { it.timestamp })
            checkEquals(1, reader.query(4000UL, 4000UL).size)          // point query
            checkEquals(0, reader.query(20_000UL, 30_000UL).size)      // beyond max
            checkEquals(0, reader.query(12_000UL, ULong.MAX_VALUE).size)
            passed++
        }

        suite("roundtrip LZ4 with unsorted appends and duplicates") {
            val pairs = mutableListOf(50L to 11, 10L to 12, 30L to 13, 30L to 14, 90L to 15, 70L to 16)
            pairs.shuffle()
            val reader = build(pairs, WriterConfig(recordValueSize = 8, compression = Compression.LZ4, blockCapacity = 3))

            val all = reader.query(0UL, ULong.MAX_VALUE)
            checkEquals(listOf(10UL, 30UL, 30UL, 50UL, 70UL, 90UL), all.map { it.timestamp })

            val duplicates = all.filter { it.timestamp == 30UL }
            checkEquals(2, duplicates.size)
            check(duplicates.map { it.value.toList() }.toSet().size == 2, "duplicate values both present")
            checkEquals(2, reader.query(30UL, 30UL).size)
            passed++
        }

        suite("metadata survives seal/open") {
            val meta = listOf(MetadataEntry("source", "kotlin"), MetadataEntry("scene", "integration"))
            val reader = build(listOf(1L to 1), WriterConfig(recordValueSize = 4, compression = Compression.NONE, blockCapacity = 10, metadata = meta))
            checkEquals(meta, reader.metadata)
            passed++
        }

        suite("append validation errors") {
            val w = GolfWriter(WriterConfig(recordValueSize = 4))
            checkThrows<GolfException>("value size mismatch") { w.append(1UL, byteArrayOf(0, 0, 0)) }
            w.append(1UL, byteArrayOf(0, 0, 0, 0))
            w.seal()
            checkThrows<GolfException>("already sealed") { w.seal() }
            checkThrows<GolfException>("already sealed") { w.append(2UL, byteArrayOf(0, 0, 0, 0)) }
            passed++
        }

        suite("empty seal rejected") {
            checkThrows<GolfException>("no records") { GolfWriter(WriterConfig(recordValueSize = 4)).seal() }
            passed++
        }

        suite("corruption detected") {
            fun freshImage(): ByteArray =
                GolfWriter(WriterConfig(recordValueSize = 4, compression = Compression.NONE, blockCapacity = 2)).let { w ->
                    (0 until 6).forEach { w.append((it * 100L).toULong(), makeValue(it, 4)) }
                    w.seal()
                }

            // Block corruption trips the lazy per-block CRC at query time.
            val image = freshImage().also { it[70] = (it[70].toInt() xor 1).toByte() }
            val reader = GolfReader.fromBytes(image)
            checkThrows<GolfException>("CRC") { reader.query(0UL, 10_000UL) }

            // Index corruption is caught immediately at open.
            val badIndex = freshImage().also { it[it.size - 40] = (it[it.size - 40].toInt() xor 0xFF).toByte() }
            checkThrows<GolfException>("index CRC") { GolfReader.fromBytes(badIndex) }

            // Header corruption is caught immediately at open.
            val badHeader = freshImage().also { it[14] = (it[14].toInt() xor 0xFF).toByte() }
            checkThrows<GolfException>("header CRC") { GolfReader.fromBytes(badHeader) }

            // Truncating the tail misaligns the footer — must fail loudly
            // (either "invalid footer magic" or "too small", both acceptable).
            val full = freshImage()
            checkThrows<GolfException>("") { GolfReader.fromBytes(full.copyOfRange(0, full.size - 20)) }
            checkThrows<GolfException>("too small") {
                GolfReader.fromBytes(full.copyOfRange(0, FIXED_HEADER_SIZE + FOOTER_SIZE - 1))
            }
            passed++
        }
    }
}

// ── Cross-language fixtures ────────────────────────────────────────────────

/**
 * Reads every generated fixture under `testdata/`, proving byte-level parity
 * with the other implementations. Zstd-compressed files are skipped because
 * this implementation does not bundle a Zstd decoder (matching TypeScript).
 */
private class FixtureCompatTests(private val dir: File) {
    private fun fixtures(): List<File> =
        (dir.listFiles() ?: emptyArray()).filter { it.extension == "golf" }.sortedBy { it.name }

    fun hasFixtures(): Boolean = fixtures().isNotEmpty()

    fun run() {
        suite("read all generated fixtures") {
            val readable = fixtures().filter { !it.name.contains("zstd") }
            check(readable.isNotEmpty(), "no fixtures generated yet")
            println("     compat fixtures: ${readable.joinToString(", ") { it.name }}")
            for (fixture in readable) {
                val reader = GolfReader.open(fixture)
                val all = reader.query(0UL, ULong.MAX_VALUE)
                checkEquals(
                    reader.descriptors.sumOf { it.recordCount },
                    reader.recordCount.toInt(),
                    "descriptor counts disagree with header (${fixture.name})",
                )
                checkEquals(all.size.toULong(), reader.recordCount, "full-range query lost records (${fixture.name})")

                if (all.isNotEmpty()) {
                    checkEquals(reader.timestampRange.start, all.first().timestamp, "${fixture.name} min ts")
                    checkEquals(reader.timestampRange.endInclusive, all.last().timestamp, "${fixture.name} max ts")
                }
            }
            passed++
        }

        suite("zstd fixture reports unsupported") {
            val zstd = fixtures().filter { it.name.contains("zstd") }
            if (zstd.isEmpty()) return@suite   // nothing to prove today
            val reader = GolfReader.open(zstd.first())
            checkThrows<GolfException>("zstd") { reader.query(0UL, ULong.MAX_VALUE) }
            passed++
        }

        suite("small fixture contents match generator contract") {
            // Known contents of `<lang>_small.golf`: 20 records at ts=i*1000,
            // value_size 8 with low byte equal to the record index.
            val langs = listOf("rust", "go", "py", "ts", "swift", "kotlin")
            for (lang in langs) {
                val f = File(dir, "${lang}_small.golf")
                if (!f.exists()) continue
                val reader = GolfReader.open(f)
                val all = reader.query(0UL, ULong.MAX_VALUE)
                checkEquals(20, all.size, lang)
                checkEquals(4, reader.header.blockCapacity, lang)
                checkEquals(Compression.NONE.code, reader.header.compression.code, lang)
                all.forEachIndexed { i, rec ->
                    checkEquals((i * 1000).toULong(), rec.timestamp, "$lang record $i")
                    checkEquals(i.toByte(), rec.value.first(), "$lang record $i value head")
                    check(rec.value.drop(1).all { it == 0.toByte() }, "$lang record $i zero padding")
                }
            }
            passed++
        }
    }
}
