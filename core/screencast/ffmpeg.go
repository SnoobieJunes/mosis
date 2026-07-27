package screencast

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// ffmpeg is the codec engine, exec'd as a child process with raw frames over
// pipes. Chosen over cgo bindings so `GOOS=linux CGO_ENABLED=0 go build`
// cross-compiles from any dev machine; the price is a runtime dependency,
// which is therefore probed honestly (a missing ffmpeg means the capability
// is not advertised, not that it fails at first use).

// FindFFmpeg locates a usable ffmpeg with an H.264 encoder. Returns the
// binary path, or "" and a human-readable reason.
func FindFFmpeg() (string, string) {
	path, err := exec.LookPath("ffmpeg")
	if err != nil {
		return "", "ffmpeg not found in PATH (install it: apt/dnf/pacman ffmpeg)"
	}
	out, err := runQuick(path, "-hide_banner", "-encoders")
	if err != nil {
		return "", fmt.Sprintf("ffmpeg at %s failed to run: %v", path, err)
	}
	if !strings.Contains(out, "libx264") && !strings.Contains(out, " h264") {
		return "", fmt.Sprintf("ffmpeg at %s has no H.264 encoder (needs libx264)", path)
	}
	return path, ""
}

// DecoderCodecs reports which of the wire codecs this ffmpeg can decode.
// H.264/HEVC decoders are built into libavcodec on every normal build, but
// "every normal build" is an assumption, so it is checked, not trusted.
func DecoderCodecs(ffmpeg string) []string {
	out, err := runQuick(ffmpeg, "-hide_banner", "-decoders")
	if err != nil {
		return nil
	}
	var codecs []string
	if strings.Contains(out, " h264") {
		codecs = append(codecs, "h264")
	}
	if strings.Contains(out, " hevc") {
		codecs = append(codecs, "hevc")
	}
	return codecs
}

func runQuick(bin string, args ...string) (string, error) {
	cmd := exec.Command(bin, args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	done := make(chan error, 1)
	if err := cmd.Start(); err != nil {
		return "", err
	}
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return buf.String(), err
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		<-done
		return "", fmt.Errorf("timed out")
	}
}

// stderrTail keeps the last chunk of a child's stderr so a dead ffmpeg can be
// reported with its actual complaint instead of "exit status 1".
type stderrTail struct {
	mu  sync.Mutex
	buf []byte
}

func (t *stderrTail) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > 2048 {
		t.buf = t.buf[len(t.buf)-2048:]
	}
	return len(p), nil
}

func (t *stderrTail) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return strings.TrimSpace(string(t.buf))
}
