// GolfTests.swift — unit tests plus cross-language fixture validation.

import XCTest
@testable import Golf

func makeValue(_ seed: Int, _ size: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: size)
    for i in 0..<size { buf[i] = UInt8((seed + i) & 0xFF) }
    return buf
}

final class CRC32CTests: XCTestCase {
    func testKnownAnswers() {
        // Standard CRC-32C check values (cross-checked against the Python
        // `crc32c` package).
        XCTAssertEqual(CRC32C.checksum([]), 0x0000_0000)
        XCTAssertEqual(CRC32C.checksum(Array("123456789".utf8)), 0xE306_9283)
        XCTAssertEqual(CRC32C.checksum(Array("a".utf8)), 0xC1D0_4330)
        XCTAssertEqual(CRC32C.checksum(Array("hello world".utf8)), 0xC994_65AA)
        XCTAssertEqual(
            CRC32C.checksum(Array("the quick brown fox jumps over the lazy dog".utf8)),
            0x3C18_F4D6)
    }

    func testSliceMatchesWhole() {
        let data = Array("the quick brown fox jumps over the lazy dog".utf8)
        XCTAssertEqual(CRC32C.checksum(data[4..<20]), CRC32C.checksum(Array(data[4..<20])))
    }
}

final class Lz4BlockTests: XCTestCase {
    private func deterministicBytes(_ n: Int, seed: Int = 12345) -> [UInt8] {
        var v = [UInt8](repeating: 0, count: n)
        var s = UInt64(seed)
        for i in 0..<n {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            // Mix in structure so matches exist at several offsets.
            v[i] = UInt8(truncatingIfNeeded: s >> 33)
            if i >= 17 && i % 5 == 0 { v[i] = v[i - 17] }
        }
        return v
    }

    private func assertRoundtrip(_ input: [UInt8]) {
        let compressed = Lz4Block.compress(input)
        XCTAssertLessThanOrEqual(compressed.count, Lz4Block.compressBound(input.count))
        let output = try! Lz4Block.decompress(compressed, outputSize: input.count)
        XCTAssertEqual(output, input)
    }

    func testRoundtripVariousSizes() {
        assertRoundtrip([])
        for n in [1, 2, 3, 4, 12, 13, 15, 16, 17, 100, 4096, 65537] {
            assertRoundtrip(deterministicBytes(n))
        }
    }

    func testRoundtripRLEPattern() {
        // Long run of a single byte exercises overlapping match copies.
        var rle = [UInt8](repeating: 7, count: 10_000)
        rle[500] = 9
        assertRoundtrip(rle)
    }

    func testRoundtripHighlyRepetitiveText() {
        let sentence = Array("the quick brown fox ".utf8)
        var text: [UInt8] = []
        for _ in 0..<600 { text.append(contentsOf: sentence) }
        let compressed = Lz4Block.compress(text)
        XCTAssertLessThan(compressed.count, text.count / 3,
                          "highly repetitive input should compress well")
        assertRoundtrip(text)
    }

    func testIncompressibleInputStaysValid() {
        // Pseudo-random bytes are effectively incompressible; the encoder must
        // still emit a decodable all-literals block.
        let random = deterministicBytes(50_000, seed: 999)
        let compressed = Lz4Block.compress(random)
        let output = try! Lz4Block.decompress(compressed, outputSize: random.count)
        XCTAssertEqual(output, random)
    }

    func testExtendedLengthEncodings() {
        // >14 leading literal bytes force literal-length extension bytes;
        // long non-repeating prefix then one long repeat forces both extensions.
        var input = deterministicBytes(3000, seed: 77)     // no 4-byte matches expected early...
        input.insert(contentsOf: Array("UNIQUE-LITERAL-HEADER-".utf8), at: 0)
        input.append(contentsOf: input[100..<2200])          // distant duplicate → offset ≤ 65535, len ≥ 16
        assertRoundtrip(input)

        // A single huge literal-only block also forces length extensions.
        assertRoundtrip(deterministicBytes(700, seed: 31))
    }

    func testCorruptPayloadThrows() {
        let valid = Lz4Block.compress(deterministicBytes(200))
        // Flip the first token: almost certainly corrupts the stream shape.
        var broken = valid
        broken[0] ^= 0xFF
        XCTAssertThrowsError(try Lz4Block.decompress(broken, outputSize: 200))
    }
}

final class WriterReaderTests: XCTestCase {
    private func build(
        _ pairs: [(UInt64, Int)], config: WriterConfig
    ) throws -> GolfReader {
        let w = GolfWriter(config: config)
        for (ts, seed) in pairs {
            try w.append(timestamp: ts, value: makeValue(seed, config.recordValueSize))
        }
        return try GolfReader(data: try w.seal())
    }

    func testRoundtripNoCompression() throws {
        let pairs = (0..<10).map { (UInt64($0) * 1000, $0) }   // already sorted
        let reader = try build(pairs, config: WriterConfig(
            recordValueSize: 16, compression: .none, blockCapacity: 4))

        XCTAssertEqual(reader.recordCount, 10)
        XCTAssertEqual(reader.timestampRange, 0...9000)
        XCTAssertTrue(reader.metadata.isEmpty)
        XCTAssertEqual(reader.descriptors.count, 3)             // ceil(10/4)

        let all = try reader.query(start: 0, end: 9000)
        XCTAssertEqual(all.count, 10)
        for (i, rec) in all.enumerated() {
            XCTAssertEqual(rec.timestamp, UInt64(i) * 1000)
            XCTAssertEqual(rec.value, makeValue(i, 16))
        }
        // Narrow inner range hits boundary narrowing logic.
        XCTAssertEqual(try reader.query(start: 2500, end: 5500).map(\.timestamp),
                       [3000, 4000, 5000])
        // Point queries behave as degenerate ranges.
        XCTAssertEqual(try reader.query(start: 4000, end: 4000).count, 1)
        // Out-of-range results are empty from either side.
        XCTAssertEqual(try reader.query(start: 20000, end: 30000).count, 0)
        XCTAssertEqual(try reader.query(start: 12000, end: UInt64.max).count, 0)
    }

    func testRoundtripLZ4WithUnsortedAppendsAndDuplicates() throws {
        var pairs: [(UInt64, Int)] = [
            (50, 11), (10, 12), (30, 13), (30, 14),      // duplicate timestamp 30
            (90, 15), (70, 16),
        ]
        pairs.shuffle()
        let reader = try build(pairs, config: WriterConfig(
            recordValueSize: 8, compression: .lz4, blockCapacity: 3))

        let all = try reader.query(start: 0, end: .max)
        XCTAssertEqual(all.map(\.timestamp), [10, 30, 30, 50, 70, 90], "records must come back sorted")

        // Duplicates both survive queries; their relative tie order is unspecified.
        let duplicates = all.filter { $0.timestamp == 30 }
        XCTAssertEqual(duplicates.count, 2)
        XCTAssertEqual(Set(duplicates.map { $0.value }), Set([makeValue(13, 8), makeValue(14, 8)]))
        XCTAssertEqual(try reader.query(start: 30, end: 30).count, 2)
    }

    func testMetadataSurvivesSealOpen() throws {
        let meta = [MetadataEntry(key: "source", value: "swift"),
                    MetadataEntry(key: "scene", value: "integration")]
        let reader = try build([(1, 1)], config: WriterConfig(
            recordValueSize: 4, compression: .none, blockCapacity: 10, metadata: meta))
        XCTAssertEqual(reader.metadata, meta)
    }

    func testSingleRecordFile() throws {
        let reader = try build([(42, 5)], config: WriterConfig(recordValueSize: 4, compression: .none))
        XCTAssertEqual(try reader.query(start: 41, end: 43).first?.value, makeValue(5, 4))
    }

    func testAppendValidationErrors() {
        let w = GolfWriter(config: WriterConfig(recordValueSize: 4))
        XCTAssertThrowsError(try w.append(timestamp: 1, value: [0, 0, 0])) { err in
            XCTAssertEqual(err as? GolfError, .valueSizeMismatch(expected: 4, actual: 3))
        }
        XCTAssertNoThrow(try w.append(timestamp: 1, value: [0, 0, 0, 0]))
        _ = try! w.seal()
        XCTAssertThrowsError(try w.seal()) { XCTAssertEqual($0 as? GolfError, .writerAlreadySealed) }
        XCTAssertThrowsError(try w.append(timestamp: 2, value: [0, 0, 0, 0])) { err in
            XCTAssertEqual(err as? GolfError, .writerAlreadySealed)
        }
    }

    func testEmptySealRejected() {
        let w = GolfWriter(config: WriterConfig(recordValueSize: 4))
        XCTAssertThrowsError(try w.seal()) { XCTAssertEqual($0 as? GolfError, .noRecords) }
    }

    func testCorruptionDetected() throws {
        // A fresh image per scenario: seal() is one-shot by design.
        func freshImage() throws -> [UInt8] {
            let w = GolfWriter(config: WriterConfig(recordValueSize: 4, compression: .none, blockCapacity: 2))
            for i in 0..<6 { try w.append(timestamp: UInt64(i) * 100, value: makeValue(i, 4)) }
            return try w.seal()
        }

        // Data-block corruption trips the lazy per-block CRC at query time
        // (open only validates footer/index/header checksums).
        var image = try freshImage()
        image[70] ^= 0x01                        // inside first block data
        let reader = try GolfReader(data: image)
        XCTAssertThrowsError(try reader.query(start: 0, end: 10_000))

        // Index corruption IS detected at open via the index CRC.
        var badIndex = try freshImage()
        badIndex[badIndex.count - 40] ^= 0xFF    // first descriptor byte
        XCTAssertThrowsError(try GolfReader(data: badIndex))

        // Header-field corruption IS detected at open via the header CRC.
        var badHeader = try freshImage()
        badHeader[14] ^= 0xFF                    // block_capacity field
        XCTAssertThrowsError(try GolfReader(data: badHeader))

        // Truncated footer region.
        XCTAssertThrowsError(try GolfReader(data: Array(image.prefix(image.count - 20))))
    }

    func testWrongMagicRejected() throws {
        let w = GolfWriter(config: WriterConfig(recordValueSize: 4))
        try w.append(timestamp: 1, value: [0, 0, 0, 0])
        var image = try w.seal()
        image[0] = UInt8(ascii: "X")             // GOLF → XOLF: bad magic beats CRC
        XCTAssertThrowsError(try GolfReader(data: image)) { err in
            XCTAssertEqual(err as? GolfError, .invalidMagic("header"))
        }

        // Garbage input that still claims footer magic fails elsewhere safely.
        XCTAssertThrowsError(try GolfReader(data: [UInt8](repeating: 0, count: 96)))
    }
}

/// Reads every generated fixture under `testdata/`, proving byte-level parity
/// with the other implementations. Zstd-compressed files are skipped because
/// this implementation does not bundle a Zstd decoder (matching TypeScript).
final class FixtureCompatTests: XCTestCase {
    static let testDataDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()               // .../swift/Tests/GolfTests
        .deletingLastPathComponent()               // .../swift/Tests
        .deletingLastPathComponent()               // .../swift
        .deletingLastPathComponent()               // repo root
        .appendingPathComponent("testdata", isDirectory: true)

    private func existingFixtures() -> [URL] {
        let names = try? FileManager.default.contentsOfDirectory(
            at: Self.testDataDir, includingPropertiesForKeys: nil)
        return (names ?? []).filter { $0.pathExtension == "golf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testReadAllGeneratedFixtures() throws {
        let fixtures = existingFixtures().filter {
            !$0.lastPathComponent.contains("zstd")
        }
        print("compat fixtures found: \(fixtures.map(\.lastPathComponent))")
        XCTAssertFalse(fixtures.isEmpty, "run `testdata/run_compat_tests.sh` once to generate fixtures")

        for fixture in fixtures {
            let reader = try GolfReader(contentsOf: fixture)
            let all = try reader.query(start: 0, end: UInt64.max)
            XCTAssertEqual(Int(reader.recordCount), reader.descriptors.reduce(0) { $0 + $1.recordCount },
                           "descriptor counts disagree with header (\(fixture.lastPathComponent))")
            XCTAssertEqual(UInt64(all.count), reader.recordCount,
                           "full-range query lost records (\(fixture.lastPathComponent))")

            if !all.isEmpty {
                XCTAssertEqual(reader.timestampRange.lowerBound, all.first!.timestamp)
                XCTAssertEqual(reader.timestampRange.upperBound, all.last!.timestamp)
            }
        }
    }

    func testZstdFixtureReportsUnsupported() throws {
        let zstdFixtures = existingFixtures().filter { $0.lastPathComponent.contains("zstd") }
        guard let fixture = zstdFixtures.first else { return }
        // Opening succeeds (header/index/footer stay valid); the failure is
        // deferred to block decompression, mirroring the TypeScript behavior.
        let reader = try GolfReader(contentsOf: fixture)
        XCTAssertThrowsError(try reader.query(start: 0, end: UInt64.max)) { err in
            guard let golfErr = err as? GolfError else {
                return XCTFail("expected GolfError, got \(err)")
            }
            guard case let GolfError.compressionError(message) = golfErr else {
                return XCTFail("expected unsupported-compression error, got \(golfErr)")
            }
            XCTAssertTrue(message.lowercased().contains("zstd"))
        }
    }

    /// Known contents of `<lang>_small.golf` generators: 20 records at ts=i*1000,
    /// value_size 8 with the low byte equal to the record index.
    func testSmallFixtureContentsMatchGeneratorContract() throws {
        for lang in ["rust", "go", "py", "ts", "swift", "kotlin"] {
            let url = Self.testDataDir.appendingPathComponent("\(lang)_small.golf")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let reader = try GolfReader(contentsOf: url)
            let all = try reader.query(start: 0, end: UInt64.max)
            XCTAssertEqual(all.count, 20, lang)
            XCTAssertEqual(reader.header.blockCapacity, 4, lang)
            XCTAssertEqual(reader.header.compression, .none, lang)
            for (i, rec) in all.enumerated() {
                XCTAssertEqual(rec.timestamp, UInt64(i) * 1000, "\(lang) record \(i)")
                XCTAssertEqual(rec.value.first, UInt8(i), "\(lang) record \(i)")
                XCTAssertEqual(Array(rec.value.dropFirst()), [UInt8](repeating: 0, count: 7),
                               "\(lang) record \(i)")
            }
        }
    }
}
