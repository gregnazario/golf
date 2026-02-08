package golf

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"

	"github.com/klauspost/compress/zstd"
	"github.com/pierrec/lz4/v4"
)

// CompressBlock compresses raw block data using the specified codec.
func CompressBlock(data []byte, codec Compression) ([]byte, error) {
	switch codec {
	case CompressionNone:
		return data, nil
	case CompressionLz4:
		return compressLz4(data)
	case CompressionZstd:
		return compressZstd(data)
	default:
		return nil, fmt.Errorf("unsupported compression codec: %d", codec)
	}
}

// DecompressBlock decompresses block data using the specified codec.
func DecompressBlock(data []byte, codec Compression, uncompressedSize int) ([]byte, error) {
	switch codec {
	case CompressionNone:
		return data, nil
	case CompressionLz4:
		return decompressLz4(data, uncompressedSize)
	case CompressionZstd:
		return decompressZstd(data, uncompressedSize)
	default:
		return nil, fmt.Errorf("unsupported compression codec: %d", codec)
	}
}

// LZ4 block format with prepended size (matching lz4_flex::compress_prepend_size)
func compressLz4(data []byte) ([]byte, error) {
	maxSize := lz4.CompressBlockBound(len(data))
	// 4 bytes for uncompressed size prefix + compressed data
	buf := make([]byte, 4+maxSize)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(len(data)))

	n, err := lz4.CompressBlock(data, buf[4:], nil)
	if err != nil {
		return nil, fmt.Errorf("lz4 compress: %w", err)
	}
	if n == 0 {
		// Data was incompressible; store raw with size prefix
		copy(buf[4:], data)
		return buf[:4+len(data)], nil
	}
	return buf[:4+n], nil
}

func decompressLz4(data []byte, uncompressedSize int) ([]byte, error) {
	if len(data) < 4 {
		return nil, fmt.Errorf("lz4 data too short")
	}
	origSize := int(binary.LittleEndian.Uint32(data[0:4]))
	if origSize != uncompressedSize {
		return nil, fmt.Errorf("lz4 size mismatch: header=%d, expected=%d", origSize, uncompressedSize)
	}
	out := make([]byte, origSize)
	n, err := lz4.UncompressBlock(data[4:], out)
	if err != nil {
		return nil, fmt.Errorf("lz4 decompress: %w", err)
	}
	return out[:n], nil
}

func compressZstd(data []byte) ([]byte, error) {
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedDefault))
	if err != nil {
		return nil, err
	}
	defer encoder.Close()
	return encoder.EncodeAll(data, nil), nil
}

func decompressZstd(data []byte, uncompressedSize int) ([]byte, error) {
	decoder, err := zstd.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer decoder.Close()
	out, err := io.ReadAll(decoder)
	if err != nil {
		return nil, fmt.Errorf("zstd decompress: %w", err)
	}
	return out, nil
}
