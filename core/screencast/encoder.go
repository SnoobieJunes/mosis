package screencast

import (
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sync"

	"github.com/auston/conduit-core/wire"
)

// Encoder wraps one ffmpeg process: raw frames in on stdin, an Annex B H.264
// stream out on stdout, reframed into wire EncodedVideoFrames.
//
// Two ffmpeg-CLI limitations shape everything above this:
//   - bitrate cannot be changed mid-run, and
//   - a keyframe cannot be forced on demand.
//
// Both are therefore implemented by the Source as a rate-limited encoder
// RESTART (fresh process → immediate IDR with fresh SPS/PPS), with a ≤2 s GOP
// as the floor the protocol requires ("keyframe at least every 2 s"). A
// restart costs a brief stall (~50–200 ms process spawn), which is the honest
// price of not linking libx264 — recorded in docs/plans/09.
type EncoderConfig struct {
	FFmpegPath  string
	InputWidth  int
	InputHeight int
	// Raw input pixel format: "bgra" (tests, synthetic sources) or "bgr0"
	// (X11 ZPixmap depth-24, alpha byte undefined).
	InputPixFmt  string
	OutputWidth  int
	OutputHeight int
	FPS          int
	BitrateBps   int
}

// EncodedAU is one encoded access unit with its capture timestamp.
type EncodedAU struct {
	Frame     wire.EncodedVideoFrame
	PtsMillis uint64
}

type Encoder struct {
	cfg    EncoderConfig
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stderr *stderrTail
	out    chan EncodedAU
	// Capture timestamps queued at WriteFrame, popped one per AU: x264 with
	// zerolatency is 1-in/1-out, so the pairing holds. Guarded because feeder
	// and reader are different goroutines.
	ptsMu    sync.Mutex
	ptsQueue []uint64
	lastPts  uint64

	closeOnce sync.Once
	writeMu   sync.Mutex
	closed    bool
	// Err is set (before out closes) when ffmpeg died unexpectedly.
	errMu  sync.Mutex
	runErr error
}

// StartEncoder launches ffmpeg. The returned encoder's Frames channel closes
// when the process exits (after Stop, or on crash — check Err then).
func StartEncoder(cfg EncoderConfig) (*Encoder, error) {
	if cfg.InputPixFmt == "" {
		cfg.InputPixFmt = "bgra"
	}
	if cfg.FPS <= 0 {
		cfg.FPS = 30
	}
	gop := cfg.FPS * 2 // protocol: keyframe at least every 2 s
	args := []string{
		"-hide_banner", "-loglevel", "error",
		"-f", "rawvideo",
		"-pixel_format", cfg.InputPixFmt,
		"-video_size", fmt.Sprintf("%dx%d", cfg.InputWidth, cfg.InputHeight),
		"-framerate", fmt.Sprintf("%d", cfg.FPS),
		"-i", "pipe:0",
		"-an",
		// Scale to the offered dimensions AND pin the RGB→YUV matrix to
		// BT.709 in one filter — swscale defaults to BT.601, which is the
		// washed-out-colours pitfall the spec calls out.
		"-vf", fmt.Sprintf("scale=%d:%d:out_color_matrix=bt709:out_range=tv:flags=bilinear,format=yuv420p",
			cfg.OutputWidth, cfg.OutputHeight),
		"-c:v", "libx264",
		"-preset", "veryfast",
		"-tune", "zerolatency", // no B-frames, no lookahead: 1-in/1-out
		"-colorspace", "bt709", "-color_primaries", "bt709",
		"-color_trc", "bt709", "-color_range", "tv",
		"-b:v", fmt.Sprintf("%d", cfg.BitrateBps),
		"-maxrate", fmt.Sprintf("%d", cfg.BitrateBps),
		"-bufsize", fmt.Sprintf("%d", cfg.BitrateBps/2),
		"-g", fmt.Sprintf("%d", gop),
		// aud=1 puts an Access Unit Delimiter before every frame — the
		// boundary auAssembler frames the byte stream on.
		"-x264-params", "aud=1",
		"-f", "h264", "pipe:1",
	}
	cmd := exec.Command(cfg.FFmpegPath, args...)
	stderr := &stderrTail{}
	cmd.Stderr = stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("ffmpeg start: %w", err)
	}
	e := &Encoder{cfg: cfg, cmd: cmd, stdin: stdin, stderr: stderr, out: make(chan EncodedAU, 4)}
	go e.readLoop(stdout)
	return e, nil
}

// WriteFrame feeds one raw frame (InputWidth*InputHeight*4 bytes). Blocks
// while ffmpeg digests — callers that must not block (the capture tick) sit
// behind a drop-oldest channel, so a slow encoder drops frames rather than
// building latency.
func (e *Encoder) WriteFrame(raw []byte, ptsMillis uint64) error {
	want := e.cfg.InputWidth * e.cfg.InputHeight * 4
	if len(raw) != want {
		return fmt.Errorf("frame is %d bytes, want %d", len(raw), want)
	}
	e.writeMu.Lock()
	defer e.writeMu.Unlock()
	if e.closed {
		return errors.New("encoder stopped")
	}
	e.ptsMu.Lock()
	e.ptsQueue = append(e.ptsQueue, ptsMillis)
	if len(e.ptsQueue) > 256 { // paranoia bound; zerolatency delay is ~0–3 frames
		e.ptsQueue = e.ptsQueue[1:]
	}
	e.ptsMu.Unlock()
	_, err := e.stdin.Write(raw)
	if err != nil {
		return fmt.Errorf("encoder pipe: %w (ffmpeg: %s)", err, e.stderr.String())
	}
	return nil
}

func (e *Encoder) Frames() <-chan EncodedAU { return e.out }

// Err reports why the encoder died, once Frames has closed. Nil after a
// clean Stop.
func (e *Encoder) Err() error {
	e.errMu.Lock()
	defer e.errMu.Unlock()
	return e.runErr
}

func (e *Encoder) popPts() uint64 {
	e.ptsMu.Lock()
	defer e.ptsMu.Unlock()
	if len(e.ptsQueue) > 0 {
		p := e.ptsQueue[0]
		e.ptsQueue = e.ptsQueue[1:]
		e.lastPts = p
		return p
	}
	// Should not happen (1-in/1-out); degrade to monotonic rather than lie badly.
	e.lastPts += uint64(1000 / e.cfg.FPS)
	return e.lastPts
}

func (e *Encoder) readLoop(stdout io.Reader) {
	defer close(e.out)
	var asm auAssembler
	buf := make([]byte, 64*1024)
	for {
		n, err := stdout.Read(buf)
		if n > 0 {
			for _, au := range asm.appendStream(buf[:n]) {
				e.deliver(au)
			}
		}
		if err != nil {
			if aus, ok := asm.finish(); ok {
				for _, au := range aus {
					e.deliver(au)
				}
			}
			waitErr := e.cmd.Wait()
			e.writeMu.Lock()
			wasStopped := e.closed
			e.writeMu.Unlock()
			if !wasStopped {
				e.errMu.Lock()
				e.runErr = fmt.Errorf("ffmpeg exited: %v (%s)", waitErr, e.stderr.String())
				e.errMu.Unlock()
			}
			return
		}
	}
}

func (e *Encoder) deliver(au AccessUnit) {
	e.out <- EncodedAU{
		Frame: wire.EncodedVideoFrame{
			IsKeyframe:    au.IsKeyframe,
			ParameterSets: au.ParameterSets,
			SampleData:    au.AVCC,
		},
		PtsMillis: e.popPts(),
	}
}

// Stop closes stdin (ffmpeg drains and exits; Frames closes after the last
// AU) and reaps the process.
func (e *Encoder) Stop() {
	e.closeOnce.Do(func() {
		e.writeMu.Lock()
		e.closed = true
		e.writeMu.Unlock()
		_ = e.stdin.Close()
		// Wait is called by readLoop when stdout drains; nothing else to do.
	})
}
