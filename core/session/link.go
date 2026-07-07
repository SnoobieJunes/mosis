package session

import (
	"encoding/hex"

	"github.com/auston/conduit-core/identity"
	"github.com/auston/conduit-core/transport"
	"github.com/auston/conduit-core/wire"
)

// Link is a live session with one pinned peer after HELLO negotiation.
type Link struct {
	node     *Node
	framed   *FramedConn
	peer     PinnedPeer
	remote   wire.HelloBody
	caps     map[string]bool
	receiver *fileReceiver
	sender   *fileSender
}

func (n *Node) newLink(framed *FramedConn, peer PinnedPeer, remote wire.HelloBody) *Link {
	caps := map[string]bool{}
	local := map[string]bool{wire.CapFile: true, wire.CapClipboard: true, wire.CapNotifySource: true}
	for _, c := range remote.Capabilities {
		if local[c] {
			caps[c] = true
		}
	}
	l := &Link{node: n, framed: framed, peer: peer, remote: remote, caps: caps}
	l.receiver = newFileReceiver(n, l)
	l.sender = newFileSender(n, l)
	return l
}

// adoptInboundSession: responder side of HELLO (the router already read HELLO).
func (n *Node) adoptInboundSession(framed *FramedConn, hello wire.HelloBody, env wire.Envelope) {
	peer, ok := n.Peers.ByTLSKeyHash(framed.PeerKeyHash())
	if !ok {
		n.logf("HELLO from unpinned TLS key; closing")
		framed.Close()
		return
	}
	if err := validateHello(hello, peer); err != nil {
		n.logf("HELLO validation failed: %v", err)
		framed.Close()
		return
	}
	framed.SetSessionID(env.SessionID)
	if err := framed.Send(wire.Message{Type: wire.TypeHelloAck, Body: n.localHello()}); err != nil {
		framed.Close()
		return
	}
	link := n.newLink(framed, peer, hello)
	n.registerLink(peer.DeviceID, link)
	if n.handlers.OnSessionReady != nil {
		n.handlers.OnSessionReady(peer.DeviceID, hello)
	}
	link.run()
	n.unregisterLink(peer.DeviceID)
}

// Connect: initiator side — dial a pinned peer, send HELLO, await HELLO_ACK.
func (n *Node) Connect(peer PinnedPeer, host string, port uint16) (*Link, error) {
	conn, err := n.Backend.Dial(host, port, transportPolicyFor(peer))
	if err != nil {
		return nil, err
	}
	framed := NewFramedConn(conn)
	framed.SetSessionID(newSessionID())
	if err := framed.Send(wire.Message{Type: wire.TypeHello, Body: n.localHello()}); err != nil {
		framed.Close()
		return nil, err
	}
	ack, err := expectHelloAck(framed)
	if err != nil {
		framed.Close()
		return nil, err
	}
	if err := validateHello(ack, peer); err != nil {
		framed.Close()
		return nil, err
	}
	link := n.newLink(framed, peer, ack)
	n.registerLink(peer.DeviceID, link)
	if n.handlers.OnSessionReady != nil {
		n.handlers.OnSessionReady(peer.DeviceID, ack)
	}
	go func() {
		link.run()
		n.unregisterLink(peer.DeviceID)
	}()
	return link, nil
}

func expectHelloAck(framed *FramedConn) (wire.HelloBody, error) {
	for {
		frame, ok, err := framed.NextFrame()
		if err != nil || !ok {
			return wire.HelloBody{}, err
		}
		if frame.Kind != wire.KindControl {
			continue
		}
		_, msg, err := wire.DecodeMessage(frame.Control)
		if err != nil {
			return wire.HelloBody{}, err
		}
		if msg.Type == wire.TypeHelloAck {
			return msg.Body.(wire.HelloBody), nil
		}
		if msg.Body == nil {
			continue // unknown: ignore
		}
	}
}

func validateHello(hello wire.HelloBody, peer PinnedPeer) error {
	if identity.DeviceID(hello.Pubkey) != hello.Identity {
		return ErrIdentityMismatch
	}
	if hello.Identity != peer.DeviceID {
		return ErrIdentityMismatch
	}
	return nil
}

func transportPolicyFor(peer PinnedPeer) transport.PinPolicy {
	return transport.PinPolicy{Pinned: map[string]bool{
		hex.EncodeToString(peer.TLSPubkeySHA256): true,
	}}
}

// run is the read loop dispatching capability messages.
func (l *Link) run() {
	for {
		frame, ok, err := l.framed.NextFrame()
		if err != nil || !ok {
			return
		}
		switch frame.Kind {
		case wire.KindControl:
			_, msg, err := wire.DecodeMessage(frame.Control)
			if err != nil {
				continue
			}
			l.handle(msg)
		case wire.KindFileChunk:
			l.receiver.handleChunk(*frame.Chunk)
		}
	}
}

func (l *Link) handle(msg wire.Message) {
	switch msg.Type {
	case wire.TypePing:
		body := msg.Body.(wire.PingBody)
		_ = l.framed.Send(wire.Message{Type: wire.TypePong, Body: wire.PingBody{Nonce: body.Nonce, T: body.T}})
	case wire.TypeClipboardPush:
		if l.node.handlers.OnClipboard != nil {
			l.node.handlers.OnClipboard(l.peer.DeviceID, msg.Body.(wire.ClipboardPushBody))
		}
	case wire.TypeNotification:
		if l.node.handlers.OnNotification != nil {
			l.node.handlers.OnNotification(l.peer.DeviceID, msg.Body.(wire.NotificationBody))
		}
	case wire.TypeFileOffer:
		l.receiver.handleOffer(msg.Body.(wire.FileOfferBody))
	case wire.TypeFileAccept, wire.TypeFileReject, wire.TypeFileAck:
		l.sender.handle(msg)
	case wire.TypeInputEvent:
		if l.node.handlers.OnInput != nil {
			l.node.handlers.OnInput(l.peer.DeviceID, msg.Body.(wire.InputEventBody))
		}
	}
}

// Public capability sends.

func (l *Link) SendClipboardText(text string) error {
	return l.framed.Send(wire.Message{Type: wire.TypeClipboardPush, Body: wire.ClipboardPushBody{
		Mime: "text/plain;charset=utf-8", Data: []byte(text),
	}})
}

func (l *Link) SendNotification(app, title, body, id string) error {
	return l.framed.Send(wire.Message{Type: wire.TypeNotification, Body: wire.NotificationBody{
		AppName: app, Title: title, Body: body, ID: id,
	}})
}

func (l *Link) HasCapability(c string) bool { return l.caps[c] }

// HasCapabilityRemote checks the REMOTE peer's advertised capabilities, not the
// intersection — for direction-specific capabilities like notify-show (spec §4).
func (l *Link) HasCapabilityRemote(c string) bool {
	for _, rc := range l.remote.Capabilities {
		if rc == c {
			return true
		}
	}
	return false
}

func (l *Link) Peer() PinnedPeer       { return l.peer }
func (l *Link) Remote() wire.HelloBody { return l.remote }
