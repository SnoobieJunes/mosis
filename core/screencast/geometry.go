package screencast

// Geometry for turning a pointer position in the viewer window into a
// position on the source's screen. A direct port of the Swift
// ScreenGeometry (apple/.../ScreenGeometry.swift) so both viewers un-letterbox
// identically; the Swift tests' cases are mirrored in geometry_test.go.

// VideoRect is the rectangle the picture occupies inside a container of
// containerW×containerH when a stream of contentW×contentH is drawn
// aspect-fit (letterboxed).
func VideoRect(containerW, containerH float64, contentW, contentH int) (x, y, w, h float64) {
	if containerW <= 0 || containerH <= 0 || contentW <= 0 || contentH <= 0 {
		return 0, 0, max0(containerW), max0(containerH)
	}
	contentAspect := float64(contentW) / float64(contentH)
	containerAspect := containerW / containerH
	if containerAspect > contentAspect {
		// Container wider than the picture: bars left and right.
		w = containerH * contentAspect
		return (containerW - w) / 2, 0, w, containerH
	}
	h = containerW / contentAspect
	return 0, (containerH - h) / 2, containerW, h
}

// Normalize maps a container-space point (top-left origin) to a 0…1 position
// on the source. Returns ok=false for a point in the letterbox bars — a tap
// there is not a tap on anything, and clamping it to an edge would silently
// click whatever lives at the source's border.
func Normalize(x, y, containerW, containerH float64, contentW, contentH int) (nx, ny float64, ok bool) {
	rx, ry, rw, rh := VideoRect(containerW, containerH, contentW, contentH)
	if rw <= 0 || rh <= 0 {
		return 0, 0, false
	}
	nx = (x - rx) / rw
	ny = (y - ry) / rh
	if nx < 0 || nx > 1 || ny < 0 || ny > 1 {
		return 0, 0, false
	}
	return nx, ny, true
}

// Delta is the motion between two normalized positions expressed in the
// SOURCE's own pixels — the space the receiver adds it to. Sent alongside
// nx/ny so a receiver that ignores absolute coordinates still tracks the
// pointer (ADR 0015's load-bearing rule).
func Delta(fromNX, fromNY, toNX, toNY float64, contentW, contentH int) (dx, dy float64) {
	return (toNX - fromNX) * float64(contentW), (toNY - fromNY) * float64(contentH)
}

func max0(v float64) float64 {
	if v < 0 {
		return 0
	}
	return v
}
