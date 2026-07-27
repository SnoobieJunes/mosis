package screencast

import (
	"testing"
	"time"

	"github.com/auston/conduit-core/wire"
)

// These tests run the REAL ffmpeg (found on PATH) — they are what "the codec
// layer works" means on this machine. They skip, loudly, where ffmpeg is
// absent rather than faking the interesting part.

func requireFFmpeg(t *testing.T) string {
	t.Helper()
	path, reason := FindFFmpeg()
	if path == "" {
		t.Skipf("skipping real-ffmpeg test: %s", reason)
	}
	return path
}

// solidBGRA returns a frame of one colour (b, g, r).
func solidBGRA(w, h int, b, g, r byte) []byte {
	frame := make([]byte, w*h*4)
	for i := 0; i < len(frame); i += 4 {
		frame[i], frame[i+1], frame[i+2], frame[i+3] = b, g, r, 0xFF
	}
	return frame
}

func TestEncodePipeProducesWireShapedFrames(t *testing.T) {
	ffmpeg := requireFFmpeg(t)
	const w, h, n = 320, 240, 30
	enc, err := StartEncoder(EncoderConfig{
		FFmpegPath: ffmpeg, InputWidth: w, InputHeight: h,
		OutputWidth: w, OutputHeight: h, FPS: 15, BitrateBps: 1_000_000,
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	type result struct {
		aus []EncodedAU
	}
	done := make(chan result, 1)
	go func() {
		var r result
		for au := range enc.Frames() {
			r.aus = append(r.aus, au)
		}
		done <- r
	}()
	for i := 0; i < n; i++ {
		if err := enc.WriteFrame(solidBGRA(w, h, 200, 50, 100), uint64(i*66)); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
	}
	enc.Stop()
	var r result
	select {
	case r = <-done:
	case <-time.After(30 * time.Second):
		t.Fatalf("encoder did not drain")
	}
	if err := enc.Err(); err != nil {
		t.Fatalf("encoder error: %v", err)
	}
	// zerolatency is 1-in/1-out: every fed frame must come back out.
	if len(r.aus) != n {
		t.Fatalf("fed %d frames, got %d access units", n, len(r.aus))
	}
	first := r.aus[0].Frame
	if !first.IsKeyframe {
		t.Fatalf("first AU is not a keyframe")
	}
	if len(first.ParameterSets) < 2 {
		t.Fatalf("keyframe has %d parameter sets, want SPS+PPS", len(first.ParameterSets))
	}
	if h264NALType(first.ParameterSets[0]) != nalSPS || h264NALType(first.ParameterSets[1]) != nalPPS {
		t.Fatalf("parameter sets are not SPS,PPS: types %d,%d",
			h264NALType(first.ParameterSets[0]), h264NALType(first.ParameterSets[1]))
	}
	// Sample data must be valid AVCC with no in-band SPS/PPS/AUD (the
	// VideoToolbox convention the wire pins).
	for i, au := range r.aus {
		nals := avccNALs(t, au.Frame.SampleData)
		if len(nals) == 0 {
			t.Fatalf("AU %d has no sample NALs", i)
		}
		for _, nl := range nals {
			switch h264NALType(nl) {
			case nalSPS, nalPPS, nalAUD:
				t.Fatalf("AU %d leaks NAL type %d into sample data", i, h264NALType(nl))
			}
		}
	}
	// PTS pairing survives the pipe.
	if r.aus[0].PtsMillis != 0 || r.aus[n-1].PtsMillis != uint64((n-1)*66) {
		t.Fatalf("pts drifted: first %d last %d", r.aus[0].PtsMillis, r.aus[n-1].PtsMillis)
	}
	// The keyframe cadence promise (≤2 s GOP → ≤30 frames at 15 fps).
	sawSecondKey := false
	for _, au := range r.aus[1:] {
		if au.Frame.IsKeyframe {
			sawSecondKey = true
			if len(au.Frame.ParameterSets) < 2 {
				t.Fatalf("later keyframe travelled without parameter sets")
			}
		}
	}
	_ = sawSecondKey // 30 frames at g=30 may or may not include the second IDR; presence isn't guaranteed here
}

func avccNALs(t *testing.T, data []byte) [][]byte {
	t.Helper()
	var nals [][]byte
	for off := 0; off < len(data); {
		if off+4 > len(data) {
			t.Fatalf("truncated AVCC length at %d", off)
		}
		l := int(uint32(data[off])<<24 | uint32(data[off+1])<<16 | uint32(data[off+2])<<8 | uint32(data[off+3]))
		if l <= 0 || off+4+l > len(data) {
			t.Fatalf("bad AVCC length %d at %d (of %d)", l, off, len(data))
		}
		nals = append(nals, data[off+4:off+4+l])
		off += 4 + l
	}
	return nals
}

// The full codec loop: synthetic frames → encode → wire pack/unpack → decode →
// pixels compared. This is the strongest claim this Mac can make about the
// codec layer; what it cannot claim is anything about X11 (device-gated).
func TestEncodeDecodeRoundTripRecoversPixels(t *testing.T) {
	ffmpeg := requireFFmpeg(t)
	const w, h, n = 320, 240, 20
	enc, err := StartEncoder(EncoderConfig{
		FFmpegPath: ffmpeg, InputWidth: w, InputHeight: h,
		OutputWidth: w, OutputHeight: h, FPS: 10, BitrateBps: 2_000_000,
	})
	if err != nil {
		t.Fatalf("encoder: %v", err)
	}
	dec, err := StartDecoder(DecoderConfig{FFmpegPath: ffmpeg, Codec: "h264", Width: w, Height: h})
	if err != nil {
		t.Fatalf("decoder: %v", err)
	}
	decoded := make(chan []byte, n+4)
	go func() {
		for f := range dec.Frames() {
			decoded <- f
		}
		close(decoded)
	}()
	go func() {
		for au := range enc.Frames() {
			// Through the FROZEN wire packing both ways, so the decode side
			// consumes exactly what a remote peer would.
			packed := wire.PackScreenFrame(au.Frame)
			back, err := wire.UnpackScreenFrame(packed, au.Frame.IsKeyframe)
			if err != nil {
				t.Errorf("unpack: %v", err)
				return
			}
			if _, err := dec.Submit(back); err != nil {
				t.Errorf("submit: %v", err)
				return
			}
		}
		dec.Stop()
	}()
	want := solidBGRA(w, h, 200, 50, 100)
	for i := 0; i < n; i++ {
		if err := enc.WriteFrame(want, uint64(i*100)); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	enc.Stop()

	var frames [][]byte
	deadline := time.After(30 * time.Second)
	for {
		select {
		case f, ok := <-decoded:
			if !ok {
				goto drained
			}
			frames = append(frames, f)
		case <-deadline:
			t.Fatalf("decoder produced %d frames before stalling", len(frames))
		}
	}
drained:
	if err := dec.Err(); err != nil {
		t.Fatalf("decoder died: %v", err)
	}
	// The decoder channel drops oldest under pressure; the count bound is
	// therefore ≥ n-4, not == n.
	if len(frames) < n-4 {
		t.Fatalf("decoded %d of %d frames", len(frames), n)
	}
	last := frames[len(frames)-1]
	if len(last) != w*h*4 {
		t.Fatalf("decoded frame is %d bytes, want %d", len(last), w*h*4)
	}
	// BT.709 both ways: a solid colour must come back close (the failure mode
	// this guards is a 601/709 mismatch, which shifts channels by 15–30).
	var db, dg, dr int64
	pixels := int64(w * h)
	for i := 0; i < len(last); i += 4 {
		db += abs64(int64(last[i]) - int64(want[i]))
		dg += abs64(int64(last[i+1]) - int64(want[i+1]))
		dr += abs64(int64(last[i+2]) - int64(want[i+2]))
	}
	if db/pixels > 10 || dg/pixels > 10 || dr/pixels > 10 {
		t.Fatalf("colour drifted: mean |Δ| B=%d G=%d R=%d (BT.601/709 mismatch?)",
			db/pixels, dg/pixels, dr/pixels)
	}
}

func TestDecoderDropsDeltasBeforeFirstKeyframe(t *testing.T) {
	ffmpeg := requireFFmpeg(t)
	dec, err := StartDecoder(DecoderConfig{FFmpegPath: ffmpeg, Codec: "h264", Width: 64, Height: 64})
	if err != nil {
		t.Fatalf("decoder: %v", err)
	}
	defer dec.Stop()
	fed, err := dec.Submit(wire.EncodedVideoFrame{IsKeyframe: false, SampleData: []byte{0, 0, 0, 1, 0x41}})
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	if fed {
		t.Fatalf("a delta before any keyframe must be dropped, not fed")
	}
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}
