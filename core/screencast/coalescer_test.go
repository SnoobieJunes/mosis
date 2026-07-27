package screencast

import (
	"testing"

	"github.com/auston/conduit-core/wire"
)

// The deterministic tests drive flushMotion directly (no ticker), the same
// trick that keeps the Swift InputCoalescerTests un-flaky.
func collectorCoalescer() (*Coalescer, *[]wire.InputEventBody) {
	events := &[]wire.InputEventBody{}
	c := &Coalescer{sink: func(ev wire.InputEventBody) { *events = append(*events, ev) }}
	return c, events
}

func TestMotionSumsAcrossATick(t *testing.T) {
	c, events := collectorCoalescer()
	c.Move(3, -1)
	c.Move(2, 4)
	c.flushMotion()
	if len(*events) != 1 {
		t.Fatalf("want 1 coalesced move, got %d", len(*events))
	}
	ev := (*events)[0]
	if ev.Kind != "move" || *ev.Dx != 5 || *ev.Dy != 3 || ev.Nx != nil {
		t.Fatalf("bad move: %+v", ev)
	}
}

// Zero net motion emits nothing — the trailing-edge-flush behavior the Swift
// suite pins with the same +5/−5 case.
func TestZeroNetMotionEmitsNothing(t *testing.T) {
	c, events := collectorCoalescer()
	c.Move(5, 0)
	c.Move(-5, 0)
	c.flushMotion()
	if len(*events) != 0 {
		t.Fatalf("zero net motion leaked %d events", len(*events))
	}
}

// Absolute positions keep the LATEST (the pointer passed through the first),
// while the deltas still sum for old receivers (ADR 0015).
func TestAbsoluteKeepsLatestPositionAndSumsDeltas(t *testing.T) {
	c, events := collectorCoalescer()
	c.MoveAbsolute(0.2, 0.2, 10, 10, "sess-1")
	c.MoveAbsolute(0.6, 0.7, 15, 5, "sess-1")
	c.flushMotion()
	if len(*events) != 1 {
		t.Fatalf("want 1 move, got %d", len(*events))
	}
	ev := (*events)[0]
	if *ev.Nx != 0.6 || *ev.Ny != 0.7 || *ev.Dx != 25 || *ev.Dy != 15 || *ev.ScreenSessionID != "sess-1" {
		t.Fatalf("bad absolute move: %+v", ev)
	}
	if ev.Dx == nil || ev.Dy == nil {
		t.Fatalf("ADR 0015: nx/ny without dx/dy must never leave the coalescer")
	}
}

// A relative move after an absolute one supersedes the aim point.
func TestRelativeMoveSupersedesAbsolute(t *testing.T) {
	c, events := collectorCoalescer()
	c.MoveAbsolute(0.5, 0.5, 1, 1, "sess-1")
	c.Move(2, 2)
	c.flushMotion()
	ev := (*events)[0]
	if ev.Nx != nil || ev.ScreenSessionID != nil {
		t.Fatalf("stale aim point leaked: %+v", ev)
	}
	if *ev.Dx != 3 || *ev.Dy != 3 {
		t.Fatalf("deltas lost: %+v", ev)
	}
}

// Discrete events flush pending motion FIRST — a click never overtakes the
// motion that positioned the cursor.
func TestDiscreteFlushesMotionFirst(t *testing.T) {
	c, events := collectorCoalescer()
	c.MoveAbsolute(0.5, 0.5, 4, 4, "sess-1")
	name, action := "left", "down"
	c.Discrete(wire.InputEventBody{Kind: "click", Button: &name, Action: &action})
	if len(*events) != 2 {
		t.Fatalf("want move+click, got %d events", len(*events))
	}
	if (*events)[0].Kind != "move" || (*events)[1].Kind != "click" {
		t.Fatalf("order wrong: %v then %v", (*events)[0].Kind, (*events)[1].Kind)
	}
}

func TestScrollAccumulates(t *testing.T) {
	c, events := collectorCoalescer()
	c.Scroll(0, 40)
	c.Scroll(0, 40)
	c.flushMotion()
	if len(*events) != 1 || *(*events)[0].Dy != 80 || (*events)[0].Kind != "scroll" {
		t.Fatalf("scroll: %+v", *events)
	}
}
