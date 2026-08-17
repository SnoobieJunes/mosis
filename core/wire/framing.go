package wire

import (
	"encoding/binary"
	"errors"
)

// TLV framing (spec §5.4): kind u8, length u32be, payload.
const (
	KindControl     byte = 0x01
	KindFileChunk   byte = 0x02
	KindScreenFrame byte = 0x03

	chunkHeaderSize       = 25 // uuid(16) + seq(8) + flags(1)
	screenFrameHeaderSize = 15 // sessionId(2) + seq(4) + flags(1) + pts(8)

	MaxControlPayload = 1 << 20
	MaxChunkData      = 2 << 20
	MaxScreenData     = 4 << 20
)

var (
	ErrOversizedFrame  = errors.New("oversized frame")
	ErrMalformedChunk  = errors.New("malformed chunk frame")
	ErrMalformedScreen = errors.New("malformed screen frame")
)

// ChunkFrame is a file-transfer bulk frame (kind 0x02).
type ChunkFrame struct {
	FileID [16]byte
	Seq    uint64
	IsLast bool
	Data   []byte
}

// ScreenFrame is an encoded video frame (kind 0x03).
type ScreenFrame struct {
	SessionID  uint16
	Seq        uint32
	IsKeyframe bool
	PtsMillis  uint64
	Data       []byte
}

// Frame is one parsed frame: exactly one field is non-nil / set by Kind.
type Frame struct {
	Kind    byte
	Control []byte
	Chunk   *ChunkFrame
	Screen  *ScreenFrame
}

func EncodeControl(json []byte) []byte {
	out := make([]byte, 5+len(json))
	out[0] = KindControl
	binary.BigEndian.PutUint32(out[1:5], uint32(len(json)))
	copy(out[5:], json)
	return out
}

func EncodeChunk(c ChunkFrame) []byte {
	payloadLen := chunkHeaderSize + len(c.Data)
	out := make([]byte, 5+payloadLen)
	out[0] = KindFileChunk
	binary.BigEndian.PutUint32(out[1:5], uint32(payloadLen))
	copy(out[5:21], c.FileID[:])
	binary.BigEndian.PutUint64(out[21:29], c.Seq)
	if c.IsLast {
		out[29] = 1
	}
	copy(out[30:], c.Data)
	return out
}

func EncodeScreen(s ScreenFrame) []byte {
	payloadLen := screenFrameHeaderSize + len(s.Data)
	out := make([]byte, 5+payloadLen)
	out[0] = KindScreenFrame
	binary.BigEndian.PutUint32(out[1:5], uint32(payloadLen))
	binary.BigEndian.PutUint16(out[5:7], s.SessionID)
	binary.BigEndian.PutUint32(out[7:11], s.Seq)
	if s.IsKeyframe {
		out[11] = 1
	}
	binary.BigEndian.PutUint64(out[12:20], s.PtsMillis)
	copy(out[20:], s.Data)
	return out
}

func decodeChunk(payload []byte) (*ChunkFrame, error) {
	if len(payload) < chunkHeaderSize {
		return nil, ErrMalformedChunk
	}
	c := &ChunkFrame{}
	copy(c.FileID[:], payload[0:16])
	c.Seq = binary.BigEndian.Uint64(payload[16:24])
	c.IsLast = payload[24] != 0
	c.Data = append([]byte(nil), payload[chunkHeaderSize:]...)
	return c, nil
}

func decodeScreen(payload []byte) (*ScreenFrame, error) {
	if len(payload) < screenFrameHeaderSize {
		return nil, ErrMalformedScreen
	}
	s := &ScreenFrame{}
	s.SessionID = binary.BigEndian.Uint16(payload[0:2])
	s.Seq = binary.BigEndian.Uint32(payload[2:6])
	s.IsKeyframe = payload[6] != 0
	s.PtsMillis = binary.BigEndian.Uint64(payload[7:15])
	s.Data = append([]byte(nil), payload[screenFrameHeaderSize:]...)
	return s, nil
}

// FrameReader incrementally parses frames from arbitrary byte segments.
// Unknown kinds are skipped (forward compatibility), matching Swift.
type FrameReader struct {
	buf            []byte
	SkippedUnknown int
}

func (r *FrameReader) Append(data []byte) ([]Frame, error) {
	r.buf = append(r.buf, data...)
	var frames []Frame
	maxAllowed := MaxControlPayload
	if MaxChunkData+chunkHeaderSize > maxAllowed {
		maxAllowed = MaxChunkData + chunkHeaderSize
	}
	if MaxScreenData+screenFrameHeaderSize > maxAllowed {
		maxAllowed = MaxScreenData + screenFrameHeaderSize
	}
	for {
		if len(r.buf) < 5 {
			break
		}
		kind := r.buf[0]
		length := int(binary.BigEndian.Uint32(r.buf[1:5]))
		if length > maxAllowed {
			return frames, ErrOversizedFrame
		}
		if len(r.buf) < 5+length {
			break
		}
		payload := append([]byte(nil), r.buf[5:5+length]...)
		r.buf = r.buf[5+length:]

		// maxAllowed above is only the shared ceiling: it lets a file chunk ride
		// in at the screen frame's 4 MiB limit, twice the 2 MiB the protocol
		// documents for chunks. Hold each kind to its own cap (2026-08-17;
		// Swift and Kotlin do the same).
		switch kind {
		case KindControl:
			if length > MaxControlPayload {
				return frames, ErrOversizedFrame
			}
			frames = append(frames, Frame{Kind: kind, Control: payload})
		case KindFileChunk:
			if length > MaxChunkData+chunkHeaderSize {
				return frames, ErrOversizedFrame
			}
			c, err := decodeChunk(payload)
			if err != nil {
				return frames, err
			}
			frames = append(frames, Frame{Kind: kind, Chunk: c})
		case KindScreenFrame:
			if length > MaxScreenData+screenFrameHeaderSize {
				return frames, ErrOversizedFrame
			}
			s, err := decodeScreen(payload)
			if err != nil {
				return frames, err
			}
			frames = append(frames, Frame{Kind: kind, Screen: s})
		default:
			r.SkippedUnknown++
		}
	}
	return frames, nil
}
