package screencast

import (
	"bytes"
	"testing"

	"github.com/auston/conduit-core/wire"
)

// Hand-built NALs: type in the low 5 bits of the first byte. Slice payloads
// get a 0x80 second byte where the test needs first_mb_in_slice == 0.
func nal(nalType byte, payload ...byte) []byte {
	return append([]byte{nalType & 0x1F}, payload...)
}

func annexB(startCode []byte, nals ...[]byte) []byte {
	var out []byte
	for _, n := range nals {
		out = append(out, startCode...)
		out = append(out, n...)
	}
	return out
}

var (
	code3 = []byte{0, 0, 1}
	code4 = []byte{0, 0, 0, 1}
)

func TestScannerSplitsNALsAcrossChunkBoundaries(t *testing.T) {
	stream := annexB(code4, nal(nalSPS, 0xAA), nal(nalPPS, 0xBB), nal(nalSliceIDR, 0x80, 0x01))
	stream = append(stream, annexB(code3, nal(nalSliceNonIDR, 0x80, 0x02))...)

	// Feed one byte at a time — the cruellest chunking.
	var s annexBScanner
	var got [][]byte
	for _, b := range stream {
		got = append(got, s.append([]byte{b})...)
	}
	if last, ok := s.flush(); ok {
		got = append(got, last)
	}
	want := [][]byte{nal(nalSPS, 0xAA), nal(nalPPS, 0xBB), nal(nalSliceIDR, 0x80, 0x01), nal(nalSliceNonIDR, 0x80, 0x02)}
	if len(got) != len(want) {
		t.Fatalf("got %d NALs, want %d", len(got), len(want))
	}
	for i := range want {
		if !bytes.Equal(got[i], want[i]) {
			t.Fatalf("NAL %d = %x, want %x", i, got[i], want[i])
		}
	}
}

func TestScannerDropsGarbageBeforeFirstStartCode(t *testing.T) {
	var s annexBScanner
	stream := append([]byte{0xDE, 0xAD, 0xBE, 0xEF}, annexB(code4, nal(nalSPS, 0x01), nal(nalPPS, 0x02))...)
	got := s.append(stream)
	if len(got) != 1 || h264NALType(got[0]) != nalSPS {
		t.Fatalf("expected exactly the SPS, got %v", got)
	}
}

func TestAssemblerFramesOnAUDAndExtractsParamSets(t *testing.T) {
	var a auAssembler
	// NB: a real NAL never ends in 0x00 (rbsp_stop_one_bit) — the scanner
	// trims trailing zeros, so test NALs must honour that too.
	sps, pps := nal(nalSPS, 0x64, 0x2A), nal(nalPPS, 0xEB)
	idr := nal(nalSliceIDR, 0x88, 0x11, 0x22)
	delta := nal(nalSliceNonIDR, 0x9A, 0x33)
	stream := annexB(code4, nal(nalAUD, 0xF0), sps, pps, idr)
	stream = append(stream, annexB(code4, nal(nalAUD, 0xF0), delta)...)

	aus := a.appendStream(stream)
	final, ok := a.finish() // EOF flushes the delta AU
	if !ok {
		t.Fatalf("finish flushed nothing")
	}
	aus = append(aus, final...)
	if len(aus) != 2 {
		t.Fatalf("got %d AUs, want 2", len(aus))
	}
	key := aus[0]
	if !key.IsKeyframe {
		t.Fatalf("first AU should be a keyframe")
	}
	if len(key.ParameterSets) != 2 ||
		!bytes.Equal(key.ParameterSets[0], sps) || !bytes.Equal(key.ParameterSets[1], pps) {
		t.Fatalf("keyframe parameter sets wrong: %x", key.ParameterSets)
	}
	// Sample data: the IDR only (SPS/PPS/AUD stripped), AVCC-packed.
	if !bytes.Equal(key.AVCC, avccFromNALs([][]byte{idr})) {
		t.Fatalf("keyframe AVCC = %x", key.AVCC)
	}
	if aus[1].IsKeyframe || len(aus[1].ParameterSets) != 0 {
		t.Fatalf("delta AU mislabeled: %+v", aus[1])
	}
	if !bytes.Equal(aus[1].AVCC, avccFromNALs([][]byte{delta})) {
		t.Fatalf("delta AVCC = %x", aus[1].AVCC)
	}
}

// A keyframe must carry parameter sets even when x264 does NOT repeat the
// headers at that IDR — the cache is what makes mid-stream joins work.
func TestAssemblerAttachesCachedParamSetsToLaterKeyframes(t *testing.T) {
	var a auAssembler
	sps, pps := nal(nalSPS, 0x64), nal(nalPPS, 0xEB)
	stream := annexB(code4,
		nal(nalAUD, 0xF0), sps, pps, nal(nalSliceIDR, 0x80, 0x01),
		nal(nalAUD, 0xF0), nal(nalSliceNonIDR, 0x80, 0x02),
		nal(nalAUD, 0xF0), nal(nalSliceIDR, 0x80, 0x03), // headers NOT repeated
	)
	aus := a.appendStream(stream)
	final, ok := a.finish()
	if !ok || len(aus) != 2 {
		t.Fatalf("got %d AUs + finish %v, want 2 + final", len(aus), ok)
	}
	last := final[0]
	if !last.IsKeyframe || len(last.ParameterSets) != 2 {
		t.Fatalf("second keyframe lost its cached parameter sets: %+v", last)
	}
}

// A stream with NO AUDs at all (an x264 build that ignores aud=1) must still
// frame on the fallback boundary: a slice with first_mb_in_slice == 0.
func TestAssemblerFallsBackToSliceBoundaries(t *testing.T) {
	var a auAssembler
	stream := annexB(code4,
		nal(nalSPS, 0x64), nal(nalPPS, 0xEB),
		nal(nalSliceIDR, 0x80, 0x01),
		nal(nalSliceNonIDR, 0x80, 0x02), // new picture, no AUD
		nal(nalSliceNonIDR, 0x80, 0x03), // another
	)
	aus := a.appendStream(stream)
	final, ok := a.finish()
	if !ok {
		t.Fatalf("finish flushed nothing")
	}
	aus = append(aus, final...)
	// The scanner holds the last NAL until EOF, so the split lands as one AU
	// from the stream plus two at finish — three pictures total either way.
	if len(aus) != 3 {
		t.Fatalf("got %d AUs, want 3", len(aus))
	}
	if !aus[0].IsKeyframe || aus[1].IsKeyframe || aus[2].IsKeyframe {
		t.Fatalf("AU keyframe flags wrong: %v %v %v", aus[0].IsKeyframe, aus[1].IsKeyframe, aus[2].IsKeyframe)
	}
}

func TestAVCCAnnexBRoundTrip(t *testing.T) {
	nals := [][]byte{nal(nalSliceIDR, 0x80, 0x01, 0x02), nal(nalSEI, 0x05)}
	avcc := avccFromNALs(nals)
	back := annexBFromAVCC(avcc)
	if !bytes.Equal(back, annexBFromNALs(nals)) {
		t.Fatalf("round trip: %x != %x", back, annexBFromNALs(nals))
	}
}

// Tolerance rules must match ScreenDecoder.kt: non-AVCC input passes through
// unchanged; truncation costs the tail, not an error. (The passthrough only
// catches 3-byte start codes — a 4-byte 00 00 00 01 parses as AVCC length 1
// in the Kotlin original too. Real sources send AVCC, so fidelity to the
// fleet's behavior beats fixing a case no peer produces.)
func TestAVCCToleranceMatchesKotlin(t *testing.T) {
	raw := annexB(code3, nal(nalSliceIDR, 0x80, 0x01))
	if !bytes.Equal(annexBFromAVCC(raw), raw) {
		t.Fatalf("already-Annex-B input should pass through unchanged")
	}
	one := avccFromNALs([][]byte{nal(nalSliceIDR, 0x80, 0x01)})
	truncated := append(append([]byte{}, one...), 0x00, 0x00, 0x00, 0xFF, 0x01)
	got := annexBFromAVCC(truncated)
	if !bytes.Equal(got, annexBFromNALs([][]byte{nal(nalSliceIDR, 0x80, 0x01)})) {
		t.Fatalf("truncated input should keep the valid prefix, got %x", got)
	}
	short := []byte{0x01, 0x02}
	if !bytes.Equal(annexBFromAVCC(short), short) {
		t.Fatalf("tiny input passes through")
	}
}

// The assembler's output must survive the frozen wire packing unchanged.
func TestAccessUnitSurvivesWirePacking(t *testing.T) {
	sps, pps := nal(nalSPS, 0x64, 0x01), nal(nalPPS, 0xEB, 0x02)
	idr := nal(nalSliceIDR, 0x80, 0xAA, 0xBB)
	frame := wire.EncodedVideoFrame{
		IsKeyframe:    true,
		ParameterSets: [][]byte{sps, pps},
		SampleData:    avccFromNALs([][]byte{idr}),
	}
	packed := wire.PackScreenFrame(frame)
	back, err := wire.UnpackScreenFrame(packed, true)
	if err != nil {
		t.Fatalf("unpack: %v", err)
	}
	if len(back.ParameterSets) != 2 || !bytes.Equal(back.ParameterSets[0], sps) ||
		!bytes.Equal(back.ParameterSets[1], pps) || !bytes.Equal(back.SampleData, frame.SampleData) {
		t.Fatalf("wire round trip mangled the frame")
	}
}
