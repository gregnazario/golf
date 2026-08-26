// GenerateFixtures.kt — regenerates the Kotlin-authored cross-language
// fixtures into the repo's testdata directory, byte-compatible with the
// fixtures produced by the other language generators.
//
// Usage: java -cp golf-generator.jar golf.GenerateFixturesKt [output-dir]

package golf

import java.io.File

private fun makeValue(seed: Int, size: Int): ByteArray {
    val buf = ByteArray(size)
    for (i in 0 until size) buf[i] = ((seed + i) and 0xFF).toByte()
    return buf
}

fun main(args: Array<String>) {
    val outputDir = File(args.firstOrNull() ?: "../testdata")
    outputDir.mkdirs()

    // kotlin_small.golf: 20 records, no compression, value_size=8, block_capacity=4
    run {
        val w = GolfWriter(
            WriterConfig(
                recordValueSize = 8,
                tsResolution = TimestampResolution.NANOSECONDS,
                compression = Compression.NONE,
                blockCapacity = 4,
            ),
        )
        for (i in 0 until 20) {
            val v = ByteArray(8); v[0] = i.toByte()
            w.append((i * 1000L).toULong(), v)
        }
        w.sealTo(File(outputDir, "kotlin_small.golf"))
        println("  kotlin_small.golf: 20 records, no compression")
    }

    // kotlin_lz4.golf: 100 records, LZ4, value_size=16, block_capacity=8
    run {
        val w = GolfWriter(
            WriterConfig(
                recordValueSize = 16,
                tsResolution = TimestampResolution.MICROSECONDS,
                compression = Compression.LZ4,
                blockCapacity = 8,
            ),
        )
        for (i in 0 until 100) {
            val v = ByteArray(16)
            v[0] = (i and 0xFF).toByte()
            v[1] = ((i shr 8) and 0xFF).toByte()
            w.append((i * 500L).toULong(), v)
        }
        w.sealTo(File(outputDir, "kotlin_lz4.golf"))
        println("  kotlin_lz4.golf: 100 records, LZ4")
    }

    // kotlin_metadata.golf: 10 records with header metadata
    run {
        val w = GolfWriter(
            WriterConfig(
                recordValueSize = 8,
                tsResolution = TimestampResolution.NANOSECONDS,
                compression = Compression.NONE,
                blockCapacity = 4,
                metadata = listOf(
                    MetadataEntry("source", "kotlin-generator"),
                    MetadataEntry("version", "0.1.0"),
                ),
            ),
        )
        for (i in 0 until 10) {
            val v = ByteArray(8); v[0] = i.toByte()
            w.append((i * 1000L).toULong(), v)
        }
        w.sealTo(File(outputDir, "kotlin_metadata.golf"))
        println("  kotlin_metadata.golf: 10 records, with metadata")
    }

    // kotlin_rle.golf: 300 records of all-zero values -- worst-case LZ4 input
    // whose blocks would end inside a match without the final-5-literals
    // rule. Read back by the Python suite (liblz4) as an independent decoder
    // oracle for this encoder.
    run {
        val w = GolfWriter(
            WriterConfig(
                recordValueSize = 16,
                tsResolution = TimestampResolution.MICROSECONDS,
                compression = Compression.LZ4,
                blockCapacity = 8,
            ),
        )
        for (i in 0 until 300) {
            w.append((i * 250L).toULong(), ByteArray(16))
        }
        w.sealTo(File(outputDir, "kotlin_rle.golf"))
        println("  kotlin_rle.golf: 300 records, LZ4 all-zero (decoder oracle)")
    }

    println("Generated Kotlin fixtures in ${outputDir.absolutePath}")
}
