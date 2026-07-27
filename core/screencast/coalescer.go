package screencast

import (
	"sync"
	"time"

	"github.com/auston/conduit-core/wire"
)

// Coalescer batches high-frequency pointer motion so the wire sees at most
// one move per tick, at the spec's 120 Hz ceiling ("Controllers batch motion
// at ≤120 Hz", docs/protocol.md). A port of the Swift InputCoalescer's
// semantics:
//
//   - relative deltas SUM across a tick;
//   - absolute positions keep the LATEST (two positions in one tick mean the
//     pointer passed through the first — summing would aim at neither) while
//     the accumulated delta still rides alongside for old receivers;
//   - discrete events (clicks, keys) flush pending motion first, so a click
//     can never overtake the motion that positioned the cursor.
type Coalescer struct {
	mu sync.Mutex
	// sendMu serializes delivery: without it, a tick could collect pending
	// motion, get descheduled before calling the sink, and lose the race to a
	// Discrete click — exactly the click-overtakes-motion ordering bug the
	// coalescer exists to prevent (the Swift actor gets this for free).
	sendMu sync.Mutex
	sink   func(wire.InputEventBody)

	moveDX, moveDY     float64
	hasMove            bool
	nx, ny             *float64
	screenSessionID    *string
	scrollDX, scrollDY float64
	hasScroll          bool

	stop chan struct{}
	wg   sync.WaitGroup
}

const coalescerTickHz = 120

// NewCoalescer starts the tick loop. The sink is called from the coalescer's
// goroutine (and from the caller's on discrete flushes) — it must be safe for
// that, which a FramedConn.Send (internally locked) is.
func NewCoalescer(sink func(wire.InputEventBody)) *Coalescer {
	c := &Coalescer{sink: sink, stop: make(chan struct{})}
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		t := time.NewTicker(time.Second / coalescerTickHz)
		defer t.Stop()
		for {
			select {
			case <-c.stop:
				return
			case <-t.C:
				c.flushMotion()
			}
		}
	}()
	return c
}

func (c *Coalescer) Stop() {
	close(c.stop)
	c.wg.Wait()
	c.mu.Lock()
	c.resetLocked()
	c.mu.Unlock()
}

func (c *Coalescer) resetLocked() {
	c.moveDX, c.moveDY, c.hasMove = 0, 0, false
	c.nx, c.ny, c.screenSessionID = nil, nil, nil
	c.scrollDX, c.scrollDY, c.hasScroll = 0, 0, false
}

// Move enqueues a relative pointer delta.
func (c *Coalescer) Move(dx, dy float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.moveDX += dx
	c.moveDY += dy
	c.hasMove = true
	// A relative move after an absolute one supersedes the aim point.
	c.nx, c.ny, c.screenSessionID = nil, nil, nil
}

// MoveAbsolute enqueues a position on a watched screen, plus the delta that
// got there for receivers that only understand deltas (ADR 0015).
func (c *Coalescer) MoveAbsolute(nx, ny, dx, dy float64, screenSessionID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.moveDX += dx
	c.moveDY += dy
	c.hasMove = true
	nxv, nyv := clamp01(nx), clamp01(ny)
	c.nx, c.ny = &nxv, &nyv
	if screenSessionID != "" {
		s := screenSessionID
		c.screenSessionID = &s
	} else {
		c.screenSessionID = nil
	}
}

func (c *Coalescer) Scroll(dx, dy float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.scrollDX += dx
	c.scrollDY += dy
	c.hasScroll = true
}

// Discrete sends a click/key event NOW, after flushing pending motion so
// ordering is guaranteed rather than hoped for.
func (c *Coalescer) Discrete(ev wire.InputEventBody) {
	c.flushMotion()
	c.sendMu.Lock()
	c.sink(ev)
	c.sendMu.Unlock()
}

func (c *Coalescer) flushMotion() {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	c.mu.Lock()
	var events []wire.InputEventBody
	if c.hasMove && (c.moveDX != 0 || c.moveDY != 0 || c.nx != nil) {
		dx, dy := c.moveDX, c.moveDY
		ev := wire.InputEventBody{Kind: "move", Dx: &dx, Dy: &dy}
		ev.Nx, ev.Ny, ev.ScreenSessionID = c.nx, c.ny, c.screenSessionID
		events = append(events, ev)
	}
	if c.hasScroll && (c.scrollDX != 0 || c.scrollDY != 0) {
		dx, dy := c.scrollDX, c.scrollDY
		events = append(events, wire.InputEventBody{Kind: "scroll", Dx: &dx, Dy: &dy})
	}
	c.resetLocked()
	c.mu.Unlock()
	for _, ev := range events {
		c.sink(ev)
	}
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}
