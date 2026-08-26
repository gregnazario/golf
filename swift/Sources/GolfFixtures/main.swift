// GolfFixtures/main.swift — regenerates the Swift-authored cross-language
// fixtures into the repo's testdata directory, byte-compatible with the
// fixtures produced by the other language generators.
//
// Usage: swift run GolfFixtures [output-dir]

import Foundation
import Golf

func makeValue(_ seed: Int, _ size: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: size)
    for i in 0..<size { buf[i] = UInt8((seed + i) & 0xFF) }
    return buf
}

let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: "../testdata", isDirectory: true)

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

do {
    // swift_small.golf: 20 records, no compression, value_size=8, block_capacity=4
    var w = GolfWriter(config: WriterConfig(
        recordValueSize: 8,
        tsResolution: .nanoseconds,
        compression: .none,
        blockCapacity: 4
    ))
    for i in 0..<20 {
        try w.append(timestamp: UInt64(i) * 1000, value: {
            var v = [UInt8](repeating: 0, count: 8)
            v[0] = UInt8(i)
            return v
        }())
    }
    try w.seal(to: outputDir.appendingPathComponent("swift_small.golf"))
    print("  swift_small.golf: 20 records, no compression")

    // swift_lz4.golf: 100 records, LZ4, value_size=16, block_capacity=8
    w = GolfWriter(config: WriterConfig(
        recordValueSize: 16,
        tsResolution: .microseconds,
        compression: .lz4,
        blockCapacity: 8
    ))
    for i in 0..<100 {
        var v = [UInt8](repeating: 0, count: 16)
        v[0] = UInt8(i & 0xFF)
        v[1] = UInt8((i >> 8) & 0xFF)
        try w.append(timestamp: UInt64(i) * 500, value: v)
    }
    try w.seal(to: outputDir.appendingPathComponent("swift_lz4.golf"))
    print("  swift_lz4.golf: 100 records, LZ4")

    // swift_metadata.golf: 10 records with header metadata
    w = GolfWriter(config: WriterConfig(
        recordValueSize: 8,
        tsResolution: .nanoseconds,
        compression: .none,
        blockCapacity: 4,
        metadata: [
            MetadataEntry(key: "source", value: "swift-generator"),
            MetadataEntry(key: "version", value: "0.1.0"),
        ]
    ))
    for i in 0..<10 {
        var v = [UInt8](repeating: 0, count: 8)
        v[0] = UInt8(i)
        try w.append(timestamp: UInt64(i) * 1000, value: v)
    }
    try w.seal(to: outputDir.appendingPathComponent("swift_metadata.golf"))
    print("  swift_metadata.golf: 10 records, with metadata")

    // swift_rle.golf: 300 records of all-zero values -- worst-case LZ4 input
    // whose blocks would end inside a match without the final-5-literals
    // rule. Read back by the Python suite (liblz4) as an independent decoder
    // oracle for this encoder.
    w = GolfWriter(config: WriterConfig(
        recordValueSize: 16,
        tsResolution: .microseconds,
        compression: .lz4,
        blockCapacity: 8
    ))
    for i in 0..<300 {
        try w.append(timestamp: UInt64(i) * 250, value: [UInt8](repeating: 0, count: 16))
    }
    try w.seal(to: outputDir.appendingPathComponent("swift_rle.golf"))
    print("  swift_rle.golf: 300 records, LZ4 all-zero (decoder oracle)")
} catch {
    FileHandle.standardError.write(Data("fixture generation failed: \(error)\n".utf8))
    exit(1)
}

print("Generated Swift fixtures in \(outputDir.path)")
