package screencast

import (
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sync"

	"github.com/auston/conduit-core/wire"
)

// Decoder wraps one ffmpeg process: wire frames (AVCC + raw parameter sets)
// converted to Annex B on stdin, raw BGRA frames out on stdout.
//
// Width/Height come from the SCREEN_OFFER and size the output reads; a source
// whose coded stream disagrees with its own offer would misalign the raw
// output (garbage picture, no crash). All three existing sources put the true
// encoded dimensions in the offer, so this is trusted the same way the Swift
// and Android decoders trust it.
type DecoderConfig struct {
	FFmpegPath string
	Codec      string // "h264" or "hevc" from the offer
	Width      int
	Height     int
}

type Decoder struct {
	cfg    DecoderConfig
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stderr *stderrTail
	out    chan []byte

	writeMu     sync.Mutex
	closed      bool
	sawKeyframe bool
	closeOnce   sync.Once
	errMu       sync.Mutex
	runErr      error
}

// MaxDecodeDimension bounds the frame size a peer's SCREEN_OFFER may ask this
// decoder to allocate: 16384 is above any real display and below anything that
// would allocate a gigabyte per frame (16384×16384×4 ≈ 1 GiB, so this is the
// ceiling, not a target).
const MaxDecodeDimension = 16384

func StartDecoder(cfg DecoderConfig) (*Decoder, error) {
	// Width/Height arrive verbatim from a peer's SCREEN_OFFER and size every
	// allocation and read below. Unvalidated until 2026-08-17: zero made
	// frameSize 0, so io.ReadFull returned instantly and readLoop span forever
	// shovelling empty frames at 100% CPU; negative panicked make() with
	// "makeslice: len out of range". A paired peer should not be able to do
	// either by sending one message.
	if cfg.Width <= 0 || cfg.Height <= 0 ||
		cfg.Width > MaxDecodeDimension || cfg.Height > MaxDecodeDimension {
		return nil, fmt.Errorf("decoder: offered frame size %dx%d is out of range (1..%d)",
			cfg.Width, cfg.Height, MaxDecodeDimension)
	}
	demux := "h264"
	if cfg.Codec == "hevc" {
		demux = "hevc"
	}
	args := []string{
		"-hide_banner", "-loglevel", "error",
		// Low-latency flags, chosen by EXPERIMENT against ffmpeg 8.1.2, not
		// folklore: `-fflags nobuffer` makes the forced-h264 pipe demuxer
		// emit ZERO frames, and `-probesize 32 -analyzeduration 0` makes it
		// packetize at raw read boundaries (mid-NAL truncation errors the
		// moment a read pauses inside a NAL). Default probing completes on
		// the first keyframe because Submit writes whole access units, so
		// the first frame still comes out promptly — verified with paused
		// AU-aligned writes and with 1.4 MB AUs spanning 22 pipe buffers.
		"-flags", "low_delay",
		"-f", demux, "-i", "pipe:0",
		"-an",
		// The stream is BT.709 by protocol rule (both Swift and this
		// package's encoder pin it); force the same matrix on the YUV→RGB
		// side or swscale quietly uses BT.601 and washes the colours out.
		"-vf", "scale=in_color_matrix=bt709:in_range=tv,format=bgra",
		"-f", "rawvideo", "pipe:1",
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
	d := &Decoder{cfg: cfg, cmd: cmd, stdin: stdin, stderr: stderr, out: make(chan []byte, 2)}
	go d.readLoop(stdout)
	return d, nil
}

// Submit feeds one wire frame. Frames before the first keyframe are dropped
// (only a keyframe carries the parameter sets the decoder configures from —
// same rule as the Swift and Android viewers). Returns whether it was fed.
func (d *Decoder) Submit(f wire.EncodedVideoFrame) (bool, error) {
	d.writeMu.Lock()
	defer d.writeMu.Unlock()
	if d.closed {
		return false, errors.New("decoder stopped")
	}
	if !d.sawKeyframe {
		if !f.IsKeyframe || len(f.ParameterSets) == 0 {
			return false, nil
		}
		d.sawKeyframe = true
	}
	var payload []byte
	if f.IsKeyframe && len(f.ParameterSets) > 0 {
		// A keyframe repeats its parameter sets in-band so the decoder can
		// resynchronise mid-stream — exactly what ScreenDecoder.kt does.
		payload = append(annexBFromNALs(f.ParameterSets), annexBFromAVCC(f.SampleData)...)
	} else {
		payload = annexBFromAVCC(f.SampleData)
	}
	if _, err := d.stdin.Write(payload); err != nil {
		return false, fmt.Errorf("decoder pipe: %w (ffmpeg: %s)", err, d.stderr.String())
	}
	return true, nil
}

// Frames yields decoded BGRA frames (Width*Height*4 bytes each). Closes when
// ffmpeg exits.
func (d *Decoder) Frames() <-chan []byte { return d.out }

func (d *Decoder) Err() error {
	d.errMu.Lock()
	defer d.errMu.Unlock()
	return d.runErr
}

func (d *Decoder) readLoop(stdout io.Reader) {
	defer close(d.out)
	frameSize := d.cfg.Width * d.cfg.Height * 4
	for {
		frame := make([]byte, frameSize)
		if _, err := io.ReadFull(stdout, frame); err != nil {
			waitErr := d.cmd.Wait()
			d.writeMu.Lock()
			wasStopped := d.closed
			d.writeMu.Unlock()
			if !wasStopped && !errors.Is(err, io.EOF) {
				d.errMu.Lock()
				d.runErr = fmt.Errorf("ffmpeg exited: %v (%s)", waitErr, d.stderr.String())
				d.errMu.Unlock()
			}
			return
		}
		// Live stream: drop the oldest queued frame rather than stall the
		// pipe — the same bufferingNewest policy the Swift pipeline uses.
		select {
		case d.out <- frame:
		default:
			select {
			case <-d.out:
			default:
			}
			select {
			case d.out <- frame:
			default:
			}
		}
	}
}

func (d *Decoder) Stop() {
	d.closeOnce.Do(func() {
		d.writeMu.Lock()
		d.closed = true
		d.writeMu.Unlock()
		_ = d.stdin.Close()
	})
}
