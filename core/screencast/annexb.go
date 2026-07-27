// Package screencast implements Linux screen sharing for the Go core: X11
// capture and an X11 viewer window, with H.264 encode/decode delegated to an
// ffmpeg child process over pipes (a documented runtime dependency, probed
// honestly at startup — never assumed).
//
// The wire convention is fixed by the Swift implementation and
// docs/protocol.md: SCREEN_FRAME data is paramCount|len|bytes...|sampleData,
// where sampleData is an AVCC elementary stream (every NAL 4-byte
// big-endian length-prefixed) and the parameter sets are RAW NAL units (no
// start codes, no length prefixes) travelling with EVERY keyframe. ffmpeg
// speaks Annex B on both ends, so this file is the translation layer between
// the two, plus the access-unit framing an undelimited byte stream needs.
package screencast

import "encoding/binary"

// H.264 NAL unit types (ITU-T H.264 §7.4.1).
const (
	nalSliceNonIDR = 1
	nalSliceIDR    = 5
	nalSEI         = 6
	nalSPS         = 7
	nalPPS         = 8
	nalAUD         = 9
)

func h264NALType(nal []byte) int {
	if len(nal) == 0 {
		return -1
	}
	return int(nal[0] & 0x1F)
}

// isVCL reports whether a NAL carries picture slice data.
func isVCL(t int) bool { return t >= 1 && t <= 5 }

// annexBScanner splits an incoming Annex B byte stream into NAL units. Start
// codes may be 3 or 4 bytes; trailing zero bytes before the next start code
// are stripped, which is spec-correct (rbsp_stop_one_bit guarantees a NAL
// never legally ends in 0x00; leftover zeros are start-code prefix bytes or
// cabac_zero_words padding).
type annexBScanner struct {
	buf []byte
	// Set once the first start code is seen; bytes before it are garbage
	// (or an ffmpeg banner that escaped -loglevel error) and are dropped.
	synced bool
}

// append adds stream bytes and returns every COMPLETE NAL unit — a NAL is
// complete only when the start code of its successor has been seen. The final
// NAL of a stream is only returned by flush at EOF.
func (s *annexBScanner) append(p []byte) [][]byte {
	s.buf = append(s.buf, p...)
	var nals [][]byte

	for {
		start := findStartCode(s.buf)
		if start < 0 {
			// No start code at all. Keep a small tail (a code could straddle
			// the chunk boundary); drop the rest if we've never synced.
			if !s.synced && len(s.buf) > 3 {
				s.buf = s.buf[len(s.buf)-3:]
			}
			return nals
		}
		if !s.synced {
			s.buf = s.buf[start:]
			s.synced = true
			start = 0
		}
		codeLen := startCodeLen(s.buf[start:])
		next := findStartCode(s.buf[start+codeLen:])
		if next < 0 {
			return nals // current NAL still incomplete
		}
		nalEnd := start + codeLen + next
		nal := trimTrailingZeros(s.buf[start+codeLen : nalEnd])
		if len(nal) > 0 {
			nals = append(nals, append([]byte(nil), nal...))
		}
		s.buf = s.buf[nalEnd:]
	}
}

// flush returns the trailing NAL after the stream ends (EOF), if any.
func (s *annexBScanner) flush() ([]byte, bool) {
	if !s.synced {
		return nil, false
	}
	codeLen := startCodeLen(s.buf)
	if codeLen == 0 || len(s.buf) <= codeLen {
		return nil, false
	}
	nal := trimTrailingZeros(s.buf[codeLen:])
	s.buf = nil
	if len(nal) == 0 {
		return nil, false
	}
	return append([]byte(nil), nal...), true
}

// findStartCode returns the index of the first 00 00 01 (reported at the
// leading zero of a 4-byte 00 00 00 01 form), or -1.
func findStartCode(b []byte) int {
	for i := 0; i+2 < len(b); i++ {
		if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 {
			// Fold a preceding zero into the code (4-byte form).
			if i > 0 && b[i-1] == 0 {
				return i - 1
			}
			return i
		}
	}
	return -1
}

func startCodeLen(b []byte) int {
	if len(b) >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1 {
		return 4
	}
	if len(b) >= 3 && b[0] == 0 && b[1] == 0 && b[2] == 1 {
		return 3
	}
	return 0
}

func trimTrailingZeros(b []byte) []byte {
	end := len(b)
	for end > 0 && b[end-1] == 0 {
		end--
	}
	return b[:end]
}

// AccessUnit is one encoded picture ready for the wire: sample NALs already
// AVCC-packed, parameter sets separated out the way the protocol ships them.
type AccessUnit struct {
	IsKeyframe bool
	// SPS then PPS, raw NALs — populated only on keyframes (matching the
	// Swift encoder, which pulls them off the format description per keyframe).
	ParameterSets [][]byte
	// AVCC sample data: slice + SEI NALs, 4-byte BE length prefixes. SPS/PPS
	// and AUD are stripped — VideoToolbox builds its decoder from the
	// parameter sets in the format description and does not expect them
	// in-band in an AVCC sample.
	AVCC []byte
}

// auAssembler groups the encoder's Annex B NAL stream into access units.
//
// ffmpeg is run with x264 `aud=1`, so every access unit begins with an Access
// Unit Delimiter — the AUD is the frame boundary. A defensive secondary rule
// (a slice with first_mb_in_slice == 0 after slice data has been seen) guards
// against a build that ignores the option. The cost of byte-stream framing is
// that an AU is only known complete when its successor begins: one frame
// interval of added latency, recorded in docs/plans/09.
type auAssembler struct {
	scanner  annexBScanner
	current  [][]byte // sample NALs of the AU being built
	curKey   bool
	sawSlice bool
	sps      [][]byte
	pps      [][]byte
}

// appendStream feeds encoder output bytes; returns every completed AccessUnit.
func (a *auAssembler) appendStream(p []byte) []AccessUnit {
	var out []AccessUnit
	for _, nal := range a.scanner.append(p) {
		if au, ok := a.take(nal); ok {
			out = append(out, au)
		}
	}
	return out
}

// finish flushes the final AU at stream EOF.
func (a *auAssembler) finish() ([]AccessUnit, bool) {
	var out []AccessUnit
	if nal, ok := a.scanner.flush(); ok {
		if au, done := a.take(nal); done {
			out = append(out, au)
		}
	}
	if au, ok := a.emit(); ok {
		out = append(out, au)
	}
	return out, len(out) > 0
}

// take consumes one NAL; returns a completed AU when this NAL begins the next.
// The encoder pipe reads its stream from byte zero (we spawned the process),
// so the first NAL always starts a valid AU — no mid-stream-join gate needed.
func (a *auAssembler) take(nal []byte) (AccessUnit, bool) {
	t := h264NALType(nal)
	switch {
	case t == nalAUD:
		return a.emit() // the AUD itself never ships
	case t == nalSPS:
		// Parameter sets are cached, not shipped in-band: the latest set is
		// attached to every keyframe AU whether or not x264 chose to repeat
		// headers at this IDR.
		a.sps = [][]byte{append([]byte(nil), nal...)}
		return AccessUnit{}, false
	case t == nalPPS:
		a.pps = [][]byte{append([]byte(nil), nal...)}
		return AccessUnit{}, false
	case isVCL(t):
		var flushed AccessUnit
		var ok bool
		if a.sawSlice && firstMBInSliceZero(nal) {
			// New picture began without an AUD — the fallback boundary for an
			// x264 build that ignores aud=1.
			flushed, ok = a.emit()
		}
		a.sawSlice = true
		if t == nalSliceIDR {
			a.curKey = true
		}
		a.current = append(a.current, nal)
		return flushed, ok
	default: // SEI and anything else rides inside the AU
		a.current = append(a.current, nal)
		return AccessUnit{}, false
	}
}

func (a *auAssembler) emit() (AccessUnit, bool) {
	if !a.sawSlice || len(a.current) == 0 {
		a.current = nil
		a.sawSlice = false
		a.curKey = false
		return AccessUnit{}, false
	}
	au := AccessUnit{IsKeyframe: a.curKey, AVCC: avccFromNALs(a.current)}
	if a.curKey {
		au.ParameterSets = append(append([][]byte{}, a.sps...), a.pps...)
	}
	a.current = nil
	a.sawSlice = false
	a.curKey = false
	return au, true
}

// firstMBInSliceZero: for slice NALs, first_mb_in_slice is the first ue(v)
// field of the header; value 0 encodes as a single '1' bit, so the byte after
// the NAL header has its MSB set exactly when this slice starts a picture.
func firstMBInSliceZero(nal []byte) bool {
	return len(nal) >= 2 && nal[1]&0x80 != 0
}

// avccFromNALs packs raw NALs as AVCC (u32be length + bytes each).
func avccFromNALs(nals [][]byte) []byte {
	total := 0
	for _, n := range nals {
		total += 4 + len(n)
	}
	out := make([]byte, 0, total)
	var l [4]byte
	for _, n := range nals {
		binary.BigEndian.PutUint32(l[:], uint32(len(n)))
		out = append(out, l[:]...)
		out = append(out, n...)
	}
	return out
}

var annexBStartCode = []byte{0, 0, 0, 1}

// annexBFromNALs prefixes each raw NAL with a 4-byte start code.
func annexBFromNALs(nals [][]byte) []byte {
	total := 0
	for _, n := range nals {
		total += 4 + len(n)
	}
	out := make([]byte, 0, total)
	for _, n := range nals {
		out = append(out, annexBStartCode...)
		out = append(out, n...)
	}
	return out
}

// annexBFromAVCC converts 4-byte-length-prefixed sample data to Annex B.
// Mirrors the Android decoder's tolerance rules exactly: input that does not
// parse as AVCC is returned unchanged (a raw Annex B source still plays), and
// malformed input is truncated at the last valid NAL — one corrupt frame
// should cost one frame, not the stream.
func annexBFromAVCC(data []byte) []byte {
	if len(data) < 4 {
		return data
	}
	out := make([]byte, 0, len(data)+16)
	offset := 0
	for offset+4 <= len(data) {
		length := int(binary.BigEndian.Uint32(data[offset : offset+4]))
		if length <= 0 || offset+4+length > len(data) {
			if len(out) == 0 {
				return data
			}
			return out
		}
		out = append(out, annexBStartCode...)
		out = append(out, data[offset+4:offset+4+length]...)
		offset += 4 + length
	}
	return out
}
