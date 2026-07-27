package screencast

import (
	"math"
	"testing"
)

func approx(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

// Mirrors the Swift ScreenGeometryTests cases so both viewers un-letterbox
// identically.
func TestVideoRectLetterboxing(t *testing.T) {
	// 16:9 stream in a 4:3 container: bars top and bottom.
	x, y, w, h := VideoRect(400, 300, 1920, 1080)
	if !approx(x, 0) || !approx(w, 400) || !approx(h, 225) || !approx(y, 37.5) {
		t.Fatalf("16:9 in 4:3: got (%v,%v,%v,%v)", x, y, w, h)
	}
	// 4:3 stream in a 16:9 container: bars left and right.
	x, y, w, h = VideoRect(1920, 1080, 800, 600)
	if !approx(y, 0) || !approx(h, 1080) || !approx(w, 1440) || !approx(x, 240) {
		t.Fatalf("4:3 in 16:9: got (%v,%v,%v,%v)", x, y, w, h)
	}
	// Exact aspect match: no bars.
	x, y, w, h = VideoRect(960, 540, 1920, 1080)
	if !approx(x, 0) || !approx(y, 0) || !approx(w, 960) || !approx(h, 540) {
		t.Fatalf("matched aspect: got (%v,%v,%v,%v)", x, y, w, h)
	}
}

func TestNormalizeCenterAndBars(t *testing.T) {
	// Dead center always maps to (0.5, 0.5).
	nx, ny, ok := Normalize(200, 150, 400, 300, 1920, 1080)
	if !ok || !approx(nx, 0.5) || !approx(ny, 0.5) {
		t.Fatalf("center: %v %v %v", nx, ny, ok)
	}
	// A point in the top letterbox bar is NOT a position on the picture.
	if _, _, ok := Normalize(200, 10, 400, 300, 1920, 1080); ok {
		t.Fatalf("letterbox bar should not normalize")
	}
	// Degenerate container.
	if _, _, ok := Normalize(0, 0, 0, 0, 1920, 1080); ok {
		t.Fatalf("degenerate container should not normalize")
	}
	// Picture corners map to 0/1 exactly.
	nx, ny, ok = Normalize(0, 37.5, 400, 300, 1920, 1080)
	if !ok || !approx(nx, 0) || !approx(ny, 0) {
		t.Fatalf("top-left of picture: %v %v %v", nx, ny, ok)
	}
}

func TestDeltaInSourcePixels(t *testing.T) {
	dx, dy := Delta(0.25, 0.5, 0.75, 0.25, 1920, 1080)
	if !approx(dx, 960) || !approx(dy, -270) {
		t.Fatalf("delta: %v %v", dx, dy)
	}
}

func TestFitClampsAndRoundsEven(t *testing.T) {
	w, h := fit(2560, 1440, 1920, 1080)
	if w != 1920 || h != 1080 {
		t.Fatalf("downscale: %dx%d", w, h)
	}
	// Never upscale.
	w, h = fit(1280, 720, 1920, 1080)
	if w != 1280 || h != 720 {
		t.Fatalf("no-upscale: %dx%d", w, h)
	}
	// Odd sources round to even (codec requirement).
	w, h = fit(1367, 769, 1367, 769)
	if w%2 != 0 || h%2 != 0 {
		t.Fatalf("odd dims survived: %dx%d", w, h)
	}
}
