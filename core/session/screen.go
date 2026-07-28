package session

import (
	"github.com/auston/conduit-core/wire"
)

// Screen-lane session glue (spec §9 Phase 3, docs/protocol.md "Screen
// sharing"). This file is the session-layer plumbing only — the capture/encode/
// decode engines live in package screencast, above this. The shape mirrors
// file.go's bulk-lane pattern: a one-time token registered on the Node lets an
// inbound connection whose first frame is SCREEN_ATTACH find the viewer that
// minted the token. The attach rides a pinned TLS connection (pairing mode is
// never allowed to reach routeInbound's attach case), so the token is a session
// binding on top of transport auth, not a substitute for it — same trust story
// as the Swift side.

// SendScreen writes one encoded video frame (kind 0x03) on this connection.
func (f *FramedConn) SendScreen(s wire.ScreenFrame) error {
	return f.writeAll(wire.EncodeScreen(s))
}

// ScreenAttachHandler adopts an inbound screen bulk lane. Return true to keep
// the connection (the handler owns it from then on, including Close); false
// closes it — the refusal a viewer gives an attach it doesn't recognise.
type ScreenAttachHandler func(framed *FramedConn, attach wire.ScreenAttachBody) bool

// RegisterScreenAttach binds a one-time bulk token (from a SCREEN_OFFER this
// node received) to a handler for the source's reverse-dialed lane.
func (n *Node) RegisterScreenAttach(token string, h ScreenAttachHandler) {
	n.bulkMu.Lock()
	defer n.bulkMu.Unlock()
	if n.pendingScreen == nil {
		n.pendingScreen = map[string]ScreenAttachHandler{}
	}
	n.pendingScreen[token] = h
}

// UnregisterScreenAttach forgets a token (share ended, or was never attached).
func (n *Node) UnregisterScreenAttach(token string) {
	n.bulkMu.Lock()
	defer n.bulkMu.Unlock()
	delete(n.pendingScreen, token)
}

func (n *Node) attachScreenLane(framed *FramedConn, attach wire.ScreenAttachBody) {
	n.bulkMu.Lock()
	h := n.pendingScreen[attach.BulkToken]
	// Single-use: a second attach with the same token is refused, matching the
	// one-time-token rule for file bulk lanes.
	if h != nil {
		delete(n.pendingScreen, attach.BulkToken)
	}
	n.bulkMu.Unlock()
	// Say which refusal it was. A dropped lane is otherwise invisible from this
	// side and shows up only as the source's "closed before it carried frames",
	// which names the symptom and not one of the three distinct causes.
	switch {
	case attach.BulkToken == "":
		n.logf("screen attach refused: no bulk token")
	case h == nil:
		n.logf("screen attach refused: unknown or already-used token")
	case !h(framed, attach):
		n.logf("screen attach refused: viewer declined (screen session %q)", attach.ScreenSessionID)
	default:
		return
	}
	framed.Close()
}

// OpenLane dials a dedicated pinned connection to a peer's listener — the
// reverse dial a screen source makes to the viewer (and the same primitive a
// future dedicated input lane would use). The caller owns the connection.
func (n *Node) OpenLane(peer PinnedPeer, host string, port uint16) (*FramedConn, error) {
	conn, err := n.Backend.Dial(host, port, transportPolicyFor(peer))
	if err != nil {
		return nil, err
	}
	framed := NewFramedConn(conn)
	framed.SetSessionID(newSessionID())
	return framed, nil
}

// Send exposes control-message sending on the session link, for engines built
// above the session layer (screencast source/viewer, input control).
func (l *Link) Send(m wire.Message) error { return l.framed.Send(m) }

// SendScreenFrame sends a screen frame over the SESSION link — the
// control-lane fallback every implementation supports when the reverse dial
// can't land (the seam that fails on real networks; see loop-state.md).
func (l *Link) SendScreenFrame(s wire.ScreenFrame) error { return l.framed.SendScreen(s) }

// RemoteHost is the peer's address on this session, for reverse dials.
func (l *Link) RemoteHost() string { return l.framed.RemoteHost() }
