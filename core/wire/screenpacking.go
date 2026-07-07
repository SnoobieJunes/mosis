package wire

import (
	"encoding/binary"
	"errors"
)

// EncodedVideoFrame mirrors the Swift type: codec parameter sets travel with
// every keyframe; the sample data is the elementary stream.
type EncodedVideoFrame struct {
	IsKeyframe    bool
	ParameterSets [][]byte
	SampleData    []byte
}

const maxParameterSets = 8

var (
	ErrScreenTruncated  = errors.New("truncated packed screen frame")
	ErrTooManyParamSets = errors.New("too many parameter sets")
)

// PackScreenFrame serializes a frame into the ScreenFrame.Data blob:
// paramCount u8 | [len u32be | bytes]... | sampleData.
func PackScreenFrame(f EncodedVideoFrame) []byte {
	var out []byte
	count := len(f.ParameterSets)
	if count > maxParameterSets {
		count = maxParameterSets
	}
	out = append(out, byte(count))
	for i := 0; i < count; i++ {
		var lenBuf [4]byte
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(f.ParameterSets[i])))
		out = append(out, lenBuf[:]...)
		out = append(out, f.ParameterSets[i]...)
	}
	out = append(out, f.SampleData...)
	return out
}

// UnpackScreenFrame parses the ScreenFrame.Data blob.
func UnpackScreenFrame(data []byte, isKeyframe bool) (EncodedVideoFrame, error) {
	if len(data) < 1 {
		return EncodedVideoFrame{}, ErrScreenTruncated
	}
	count := int(data[0])
	if count > maxParameterSets {
		return EncodedVideoFrame{}, ErrTooManyParamSets
	}
	cursor := 1
	sets := make([][]byte, 0, count)
	for i := 0; i < count; i++ {
		if cursor+4 > len(data) {
			return EncodedVideoFrame{}, ErrScreenTruncated
		}
		l := int(binary.BigEndian.Uint32(data[cursor : cursor+4]))
		cursor += 4
		if cursor+l > len(data) {
			return EncodedVideoFrame{}, ErrScreenTruncated
		}
		sets = append(sets, append([]byte(nil), data[cursor:cursor+l]...))
		cursor += l
	}
	return EncodedVideoFrame{
		IsKeyframe:    isKeyframe,
		ParameterSets: sets,
		SampleData:    append([]byte(nil), data[cursor:]...),
	}, nil
}
