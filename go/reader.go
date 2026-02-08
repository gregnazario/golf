package golf

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
)

// GolfReader reads .golf files using standard I/O.
type GolfReader struct {
	rs          io.ReadSeeker
	Header      Header
	Metadata    []MetadataEntry
	Descriptors []BlockDescriptor
}

// OpenReader opens a golf file from a ReadSeeker.
func OpenReader(rs io.ReadSeeker) (*GolfReader, error) {
	// Get file size
	size, err := rs.Seek(0, io.SeekEnd)
	if err != nil {
		return nil, err
	}
	if size < int64(FixedHeaderSize+FooterSize) {
		return nil, fmt.Errorf("file too small: %d bytes", size)
	}

	// Read footer
	if _, err := rs.Seek(-int64(FooterSize), io.SeekEnd); err != nil {
		return nil, err
	}
	var footerBuf [FooterSize]byte
	if _, err := io.ReadFull(rs, footerBuf[:]); err != nil {
		return nil, fmt.Errorf("read footer: %w", err)
	}
	footer, err := DecodeFooter(footerBuf)
	if err != nil {
		return nil, err
	}

	// Read block index
	indexSize := int(footer.BlockCount) * BlockDescriptorSize
	if _, err := rs.Seek(int64(footer.IndexOffset), io.SeekStart); err != nil {
		return nil, err
	}
	indexBuf := make([]byte, indexSize)
	if _, err := io.ReadFull(rs, indexBuf); err != nil {
		return nil, fmt.Errorf("read block index: %w", err)
	}
	actualCRC := computeCRC32C(indexBuf)
	if actualCRC != footer.IndexCRC {
		return nil, fmt.Errorf("block index CRC mismatch: expected %#010x, got %#010x",
			footer.IndexCRC, actualCRC)
	}
	var descriptors []BlockDescriptor
	for i := 0; i < int(footer.BlockCount); i++ {
		start := i * BlockDescriptorSize
		var dbuf [BlockDescriptorSize]byte
		copy(dbuf[:], indexBuf[start:start+BlockDescriptorSize])
		descriptors = append(descriptors, DecodeBlockDescriptor(dbuf))
	}

	// Read header
	if _, err := rs.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	var headerBuf [FixedHeaderSize]byte
	if _, err := io.ReadFull(rs, headerBuf[:]); err != nil {
		return nil, fmt.Errorf("read header: %w", err)
	}
	header, err := DecodeHeader(headerBuf)
	if err != nil {
		return nil, err
	}

	// Read metadata
	var metadata []MetadataEntry
	if header.MetadataLength > 0 {
		metaBuf := make([]byte, header.MetadataLength)
		if _, err := io.ReadFull(rs, metaBuf); err != nil {
			return nil, fmt.Errorf("read metadata: %w", err)
		}
		metadata, err = DecodeMetadata(metaBuf)
		if err != nil {
			return nil, err
		}
	}

	return &GolfReader{
		rs:          rs,
		Header:      *header,
		Metadata:    metadata,
		Descriptors: descriptors,
	}, nil
}

// OpenFile opens a golf file from a filesystem path.
func OpenFile(path string) (*GolfReader, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	return OpenReader(f)
}

// Query returns records in the inclusive timestamp range [startTs, endTs].
func (r *GolfReader) Query(startTs, endTs uint64) ([]Record, error) {
	firstIdx := FindFirstBlock(r.Descriptors, startTs)
	if firstIdx < 0 {
		return nil, nil
	}
	lastIdx := FindLastBlock(r.Descriptors, endTs)
	if lastIdx < 0 {
		return nil, nil
	}
	if firstIdx > lastIdx {
		return nil, nil
	}

	recordSize := 8 + int(r.Header.RecordValueSize)
	var results []Record

	for bi := firstIdx; bi <= lastIdx; bi++ {
		desc := &r.Descriptors[bi]

		// Read compressed block
		if _, err := r.rs.Seek(int64(desc.BlockOffset), io.SeekStart); err != nil {
			return nil, err
		}
		compressed := make([]byte, desc.CompressedSize)
		if _, err := io.ReadFull(r.rs, compressed); err != nil {
			return nil, fmt.Errorf("read block: %w", err)
		}

		// Decompress
		raw, err := DecompressBlock(compressed, r.Header.Compression, int(desc.UncompressedSize))
		if err != nil {
			return nil, err
		}

		// Verify CRC
		actualCRC := computeCRC32C(raw)
		if actualCRC != desc.BlockCRC {
			return nil, fmt.Errorf("block CRC mismatch: expected %#010x, got %#010x",
				desc.BlockCRC, actualCRC)
		}

		count := int(desc.RecordCount)
		recStart := 0
		recEnd := count - 1

		if bi == firstIdx {
			recStart = binarySearchFirst(raw, recordSize, count, startTs)
		}
		if bi == lastIdx {
			recEnd = binarySearchLast(raw, recordSize, count, endTs)
		}

		if recStart <= recEnd && recEnd < count {
			for i := recStart; i <= recEnd; i++ {
				off := i * recordSize
				ts := binary.LittleEndian.Uint64(raw[off : off+8])
				if ts >= startTs && ts <= endTs {
					val := make([]byte, r.Header.RecordValueSize)
					copy(val, raw[off+8:off+recordSize])
					results = append(results, Record{Timestamp: ts, Value: val})
				}
			}
		}
	}

	return results, nil
}

func binarySearchFirst(data []byte, recordSize, count int, target uint64) int {
	lo, hi := 0, count
	for lo < hi {
		mid := lo + (hi-lo)/2
		ts := binary.LittleEndian.Uint64(data[mid*recordSize : mid*recordSize+8])
		if ts < target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

func binarySearchLast(data []byte, recordSize, count int, target uint64) int {
	lo, hi := 0, count
	for lo < hi {
		mid := lo + (hi-lo)/2
		ts := binary.LittleEndian.Uint64(data[mid*recordSize : mid*recordSize+8])
		if ts <= target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return 0
	}
	return lo - 1
}

// MmapGolfReader reads .golf files using memory-mapped I/O.
type MmapGolfReader struct {
	data        []byte
	Header      Header
	Metadata    []MetadataEntry
	Descriptors []BlockDescriptor
	file        *os.File
}

// OpenMmap opens a golf file using memory-mapped I/O.
func OpenMmap(path string) (*MmapGolfReader, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	size := info.Size()
	if size < int64(FixedHeaderSize+FooterSize) {
		f.Close()
		return nil, fmt.Errorf("file too small: %d bytes", size)
	}

	// Read the whole file into memory (portable mmap alternative)
	data := make([]byte, size)
	if _, err := io.ReadFull(f, data); err != nil {
		f.Close()
		return nil, err
	}

	// Parse footer
	footerStart := len(data) - FooterSize
	var footerBuf [FooterSize]byte
	copy(footerBuf[:], data[footerStart:])
	footer, err := DecodeFooter(footerBuf)
	if err != nil {
		f.Close()
		return nil, err
	}

	// Parse block index
	indexStart := int(footer.IndexOffset)
	indexEnd := indexStart + int(footer.BlockCount)*BlockDescriptorSize
	indexBuf := data[indexStart:indexEnd]
	actualCRC := computeCRC32C(indexBuf)
	if actualCRC != footer.IndexCRC {
		f.Close()
		return nil, fmt.Errorf("block index CRC mismatch")
	}
	var descriptors []BlockDescriptor
	for i := 0; i < int(footer.BlockCount); i++ {
		start := i * BlockDescriptorSize
		var dbuf [BlockDescriptorSize]byte
		copy(dbuf[:], indexBuf[start:start+BlockDescriptorSize])
		descriptors = append(descriptors, DecodeBlockDescriptor(dbuf))
	}

	// Parse header
	var headerBuf [FixedHeaderSize]byte
	copy(headerBuf[:], data[0:FixedHeaderSize])
	header, err := DecodeHeader(headerBuf)
	if err != nil {
		f.Close()
		return nil, err
	}

	var metadata []MetadataEntry
	if header.MetadataLength > 0 {
		metaBuf := data[FixedHeaderSize : FixedHeaderSize+int(header.MetadataLength)]
		metadata, err = DecodeMetadata(metaBuf)
		if err != nil {
			f.Close()
			return nil, err
		}
	}

	return &MmapGolfReader{
		data:        data,
		Header:      *header,
		Metadata:    metadata,
		Descriptors: descriptors,
		file:        f,
	}, nil
}

// Close closes the underlying file.
func (r *MmapGolfReader) Close() error {
	return r.file.Close()
}

// Query returns records in the inclusive timestamp range [startTs, endTs].
func (r *MmapGolfReader) Query(startTs, endTs uint64) ([]Record, error) {
	firstIdx := FindFirstBlock(r.Descriptors, startTs)
	if firstIdx < 0 {
		return nil, nil
	}
	lastIdx := FindLastBlock(r.Descriptors, endTs)
	if lastIdx < 0 {
		return nil, nil
	}
	if firstIdx > lastIdx {
		return nil, nil
	}

	recordSize := 8 + int(r.Header.RecordValueSize)
	var results []Record

	for bi := firstIdx; bi <= lastIdx; bi++ {
		desc := &r.Descriptors[bi]

		compressed := r.data[desc.BlockOffset : desc.BlockOffset+uint64(desc.CompressedSize)]

		raw, err := DecompressBlock(compressed, r.Header.Compression, int(desc.UncompressedSize))
		if err != nil {
			return nil, err
		}

		actualCRC := computeCRC32C(raw)
		if actualCRC != desc.BlockCRC {
			return nil, fmt.Errorf("block CRC mismatch")
		}

		count := int(desc.RecordCount)
		recStart := 0
		recEnd := count - 1

		if bi == firstIdx {
			recStart = binarySearchFirst(raw, recordSize, count, startTs)
		}
		if bi == lastIdx {
			recEnd = binarySearchLast(raw, recordSize, count, endTs)
		}

		if recStart <= recEnd && recEnd < count {
			for i := recStart; i <= recEnd; i++ {
				off := i * recordSize
				ts := binary.LittleEndian.Uint64(raw[off : off+8])
				if ts >= startTs && ts <= endTs {
					val := make([]byte, r.Header.RecordValueSize)
					copy(val, raw[off+8:off+recordSize])
					results = append(results, Record{Timestamp: ts, Value: val})
				}
			}
		}
	}

	return results, nil
}
