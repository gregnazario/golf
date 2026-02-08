// Package golf implements the .golf indexed storage file format.
//
// Golf files are read-only, indexed binary files optimized for range queries
// over time-series keys with small fixed-size record values.
package golf

import (
	"encoding/binary"
	"fmt"
	"hash/crc32"
)

// Format constants
const (
	FixedHeaderSize     = 64
	BlockDescriptorSize = 40
	FooterSize          = 32
	FormatVersion       = 1
)

var (
	HeaderMagic    = [4]byte{'G', 'O', 'L', 'F'}
	FooterMagicVal = [4]byte{'F', 'L', 'O', 'G'}
	// CRC32C (Castagnoli) table
	crc32cTable = crc32.MakeTable(crc32.Castagnoli)
)

// TimestampResolution indicates the unit of timestamp values.
type TimestampResolution uint8

const (
	TsNanoseconds  TimestampResolution = 0
	TsMicroseconds TimestampResolution = 1
	TsMilliseconds TimestampResolution = 2
)

// Compression indicates the block compression codec.
type Compression uint8

const (
	CompressionNone Compression = 0
	CompressionLz4  Compression = 1
	CompressionZstd Compression = 2
)

// Header represents the fixed header of a golf file.
type Header struct {
	Version         uint16
	Flags           uint16
	RecordValueSize uint32
	TsResolution    TimestampResolution
	Compression     Compression
	BlockCapacity   uint32
	MinTimestamp     uint64
	MaxTimestamp     uint64
	RecordCount     uint64
	MetadataLength  uint32
}

// MetadataEntry is a key-value metadata pair.
type MetadataEntry struct {
	Key   string
	Value string
}

// BlockDescriptor describes a single compressed data block.
type BlockDescriptor struct {
	MinTs            uint64
	MaxTs            uint64
	BlockOffset      uint64
	CompressedSize   uint32
	UncompressedSize uint32
	RecordCount      uint32
	BlockCRC         uint32
}

// Record is a single timestamp + value pair.
type Record struct {
	Timestamp uint64
	Value     []byte
}

// Footer represents the file footer.
type Footer struct {
	IndexOffset uint64
	BlockCount  uint64
	IndexCRC    uint32
}

// crc32c computes the CRC-32C (Castagnoli) checksum.
func computeCRC32C(data []byte) uint32 {
	return crc32.Checksum(data, crc32cTable)
}

// EncodeHeader encodes a Header into exactly 64 bytes.
func EncodeHeader(h *Header) [FixedHeaderSize]byte {
	var buf [FixedHeaderSize]byte
	copy(buf[0:4], HeaderMagic[:])
	binary.LittleEndian.PutUint16(buf[4:6], h.Version)
	binary.LittleEndian.PutUint16(buf[6:8], h.Flags)
	binary.LittleEndian.PutUint32(buf[8:12], h.RecordValueSize)
	buf[12] = byte(h.TsResolution)
	buf[13] = byte(h.Compression)
	binary.LittleEndian.PutUint32(buf[14:18], h.BlockCapacity)
	// 18..28 reserved (zeros)
	binary.LittleEndian.PutUint64(buf[28:36], h.MinTimestamp)
	binary.LittleEndian.PutUint64(buf[36:44], h.MaxTimestamp)
	binary.LittleEndian.PutUint64(buf[44:52], h.RecordCount)
	binary.LittleEndian.PutUint32(buf[52:56], h.MetadataLength)
	crc := computeCRC32C(buf[0:56])
	binary.LittleEndian.PutUint32(buf[56:60], crc)
	// 60..64 padding (zeros)
	return buf
}

// DecodeHeader decodes a Header from exactly 64 bytes.
func DecodeHeader(buf [FixedHeaderSize]byte) (*Header, error) {
	if buf[0] != 'G' || buf[1] != 'O' || buf[2] != 'L' || buf[3] != 'F' {
		return nil, fmt.Errorf("invalid header magic")
	}
	version := binary.LittleEndian.Uint16(buf[4:6])
	if version != FormatVersion {
		return nil, fmt.Errorf("unsupported version: %d", version)
	}

	storedCRC := binary.LittleEndian.Uint32(buf[56:60])
	computedCRC := computeCRC32C(buf[0:56])
	if storedCRC != computedCRC {
		return nil, fmt.Errorf("header CRC mismatch: expected %#010x, got %#010x", computedCRC, storedCRC)
	}

	return &Header{
		Version:         version,
		Flags:           binary.LittleEndian.Uint16(buf[6:8]),
		RecordValueSize: binary.LittleEndian.Uint32(buf[8:12]),
		TsResolution:    TimestampResolution(buf[12]),
		Compression:     Compression(buf[13]),
		BlockCapacity:   binary.LittleEndian.Uint32(buf[14:18]),
		MinTimestamp:     binary.LittleEndian.Uint64(buf[28:36]),
		MaxTimestamp:     binary.LittleEndian.Uint64(buf[36:44]),
		RecordCount:      binary.LittleEndian.Uint64(buf[44:52]),
		MetadataLength:  binary.LittleEndian.Uint32(buf[52:56]),
	}, nil
}

// EncodeMetadata encodes metadata entries into bytes.
func EncodeMetadata(entries []MetadataEntry) []byte {
	var buf []byte
	for _, e := range entries {
		kb := []byte(e.Key)
		vb := []byte(e.Value)
		b := make([]byte, 2)
		binary.LittleEndian.PutUint16(b, uint16(len(kb)))
		buf = append(buf, b...)
		buf = append(buf, kb...)
		binary.LittleEndian.PutUint16(b, uint16(len(vb)))
		buf = append(buf, b...)
		buf = append(buf, vb...)
	}
	return buf
}

// DecodeMetadata decodes metadata entries from bytes.
func DecodeMetadata(data []byte) ([]MetadataEntry, error) {
	var entries []MetadataEntry
	for len(data) > 0 {
		if len(data) < 2 {
			return nil, fmt.Errorf("truncated metadata key length")
		}
		keyLen := int(binary.LittleEndian.Uint16(data[0:2]))
		data = data[2:]
		if len(data) < keyLen {
			return nil, fmt.Errorf("truncated metadata key")
		}
		key := string(data[:keyLen])
		data = data[keyLen:]

		if len(data) < 2 {
			return nil, fmt.Errorf("truncated metadata value length")
		}
		valLen := int(binary.LittleEndian.Uint16(data[0:2]))
		data = data[2:]
		if len(data) < valLen {
			return nil, fmt.Errorf("truncated metadata value")
		}
		value := string(data[:valLen])
		data = data[valLen:]

		entries = append(entries, MetadataEntry{Key: key, Value: value})
	}
	return entries, nil
}

// EncodeBlockDescriptor encodes a BlockDescriptor into 40 bytes.
func EncodeBlockDescriptor(d *BlockDescriptor) [BlockDescriptorSize]byte {
	var buf [BlockDescriptorSize]byte
	binary.LittleEndian.PutUint64(buf[0:8], d.MinTs)
	binary.LittleEndian.PutUint64(buf[8:16], d.MaxTs)
	binary.LittleEndian.PutUint64(buf[16:24], d.BlockOffset)
	binary.LittleEndian.PutUint32(buf[24:28], d.CompressedSize)
	binary.LittleEndian.PutUint32(buf[28:32], d.UncompressedSize)
	binary.LittleEndian.PutUint32(buf[32:36], d.RecordCount)
	binary.LittleEndian.PutUint32(buf[36:40], d.BlockCRC)
	return buf
}

// DecodeBlockDescriptor decodes a BlockDescriptor from 40 bytes.
func DecodeBlockDescriptor(buf [BlockDescriptorSize]byte) BlockDescriptor {
	return BlockDescriptor{
		MinTs:            binary.LittleEndian.Uint64(buf[0:8]),
		MaxTs:            binary.LittleEndian.Uint64(buf[8:16]),
		BlockOffset:      binary.LittleEndian.Uint64(buf[16:24]),
		CompressedSize:   binary.LittleEndian.Uint32(buf[24:28]),
		UncompressedSize: binary.LittleEndian.Uint32(buf[28:32]),
		RecordCount:      binary.LittleEndian.Uint32(buf[32:36]),
		BlockCRC:         binary.LittleEndian.Uint32(buf[36:40]),
	}
}

// EncodeFooter encodes a Footer into 32 bytes.
func EncodeFooter(f *Footer) [FooterSize]byte {
	var buf [FooterSize]byte
	binary.LittleEndian.PutUint64(buf[0:8], f.IndexOffset)
	binary.LittleEndian.PutUint64(buf[8:16], f.BlockCount)
	binary.LittleEndian.PutUint32(buf[16:20], f.IndexCRC)
	copy(buf[20:24], FooterMagicVal[:])
	crc := computeCRC32C(buf[0:24])
	binary.LittleEndian.PutUint32(buf[24:28], crc)
	// 28..32 padding (zeros)
	return buf
}

// DecodeFooter decodes a Footer from 32 bytes.
func DecodeFooter(buf [FooterSize]byte) (*Footer, error) {
	if buf[20] != 'F' || buf[21] != 'L' || buf[22] != 'O' || buf[23] != 'G' {
		return nil, fmt.Errorf("invalid footer magic")
	}
	storedCRC := binary.LittleEndian.Uint32(buf[24:28])
	computedCRC := computeCRC32C(buf[0:24])
	if storedCRC != computedCRC {
		return nil, fmt.Errorf("footer CRC mismatch: expected %#010x, got %#010x", computedCRC, storedCRC)
	}
	return &Footer{
		IndexOffset: binary.LittleEndian.Uint64(buf[0:8]),
		BlockCount:  binary.LittleEndian.Uint64(buf[8:16]),
		IndexCRC:    binary.LittleEndian.Uint32(buf[16:20]),
	}, nil
}

// SerializeBlock serializes records into a flat byte array.
func SerializeBlock(records []Record, recordValueSize uint32) []byte {
	recordSize := 8 + int(recordValueSize)
	buf := make([]byte, len(records)*recordSize)
	for i, r := range records {
		off := i * recordSize
		binary.LittleEndian.PutUint64(buf[off:off+8], r.Timestamp)
		copy(buf[off+8:off+recordSize], r.Value)
	}
	return buf
}

// ParseRecords parses records from an uncompressed block buffer.
func ParseRecords(data []byte, recordValueSize uint32) []Record {
	recordSize := 8 + int(recordValueSize)
	count := len(data) / recordSize
	records := make([]Record, count)
	for i := 0; i < count; i++ {
		off := i * recordSize
		ts := binary.LittleEndian.Uint64(data[off : off+8])
		val := make([]byte, recordValueSize)
		copy(val, data[off+8:off+recordSize])
		records[i] = Record{Timestamp: ts, Value: val}
	}
	return records
}

// FindFirstBlock binary-searches for the first block where max_ts >= target.
func FindFirstBlock(descriptors []BlockDescriptor, target uint64) int {
	lo, hi := 0, len(descriptors)
	for lo < hi {
		mid := lo + (hi-lo)/2
		if descriptors[mid].MaxTs < target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(descriptors) {
		return lo
	}
	return -1
}

// FindLastBlock binary-searches for the last block where min_ts <= target.
func FindLastBlock(descriptors []BlockDescriptor, target uint64) int {
	lo, hi := 0, len(descriptors)
	for lo < hi {
		mid := lo + (hi-lo)/2
		if descriptors[mid].MinTs <= target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return -1
	}
	return lo - 1
}
