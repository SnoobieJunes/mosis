package session

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"

	"github.com/auston/conduit-core/identity"
	"github.com/auston/conduit-core/transport"
	"github.com/auston/conduit-core/wire"
)

// PeerStore holds pinned peers, persisted to a flat JSON file (matching Swift's
// "keep it boring" choice).
type PeerStore struct {
	mu    sync.Mutex
	path  string
	peers map[string]PinnedPeer
}

func LoadPeerStore(path string) *PeerStore {
	ps := &PeerStore{path: path, peers: map[string]PinnedPeer{}}
	if data, err := os.ReadFile(path); err == nil {
		var list []PinnedPeer
		if json.Unmarshal(data, &list) == nil {
			for _, p := range list {
				ps.peers[p.DeviceID] = p
			}
		}
	}
	return ps
}

func (ps *PeerStore) Upsert(p PinnedPeer) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	ps.peers[p.DeviceID] = p
	ps.persist()
}

func (ps *PeerStore) ByTLSKeyHash(hash []byte) (PinnedPeer, bool) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	want := hex.EncodeToString(hash)
	for _, p := range ps.peers {
		if hex.EncodeToString(p.TLSPubkeySHA256) == want {
			return p, true
		}
	}
	return PinnedPeer{}, false
}

func (ps *PeerStore) All() []PinnedPeer {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	out := make([]PinnedPeer, 0, len(ps.peers))
	for _, p := range ps.peers {
		out = append(out, p)
	}
	return out
}

// PinnedHashes is the current allow-set for the TLS listener.
func (ps *PeerStore) PinnedHashes() map[string]bool {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	out := map[string]bool{}
	for _, p := range ps.peers {
		out[hex.EncodeToString(p.TLSPubkeySHA256)] = true
	}
	return out
}

func (ps *PeerStore) persist() {
	list := make([]PinnedPeer, 0, len(ps.peers))
	for _, p := range ps.peers {
		list = append(list, p)
	}
	if data, err := json.MarshalIndent(list, "", "  "); err == nil {
		if ps.path != "" {
			_ = os.MkdirAll(filepath.Dir(ps.path), 0o700)
			_ = os.WriteFile(ps.path, data, 0o600)
		}
	}
}

// Node is a Conduit peer implemented in Go.
type Node struct {
	Name        string
	DeviceClass string
	AppVersion  string
	ID          identity.Identity
	TLS         identity.TLSMaterial
	Peers       *PeerStore
	Backend     *transport.Backend
	ReceiveDir  string

	// PairingEnabled gates whether inbound unpinned connections may pair.
	PairingEnabled bool
	Confirm        Confirm
	// Capabilities advertised in HELLO. Empty → the default set.
	Capabilities []string

	listener   *transport.Listener
	listenPort uint16
	handlers   Handlers

	// Registry so an inbound bulk connection (BULK_ATTACH) finds the receiver
	// that issued its one-time token in FILE_ACCEPT; and active links by device.
	bulkMu      sync.Mutex
	pendingBulk map[string]*fileReceiver
	activeLinks map[string]*Link
}

func (n *Node) registerBulkToken(token string, r *fileReceiver) {
	n.bulkMu.Lock()
	defer n.bulkMu.Unlock()
	if n.pendingBulk == nil {
		n.pendingBulk = map[string]*fileReceiver{}
	}
	n.pendingBulk[token] = r
}

func (n *Node) registerLink(deviceID string, l *Link) {
	n.bulkMu.Lock()
	defer n.bulkMu.Unlock()
	if n.activeLinks == nil {
		n.activeLinks = map[string]*Link{}
	}
	n.activeLinks[deviceID] = l
}

func (n *Node) unregisterLink(deviceID string) {
	n.bulkMu.Lock()
	defer n.bulkMu.Unlock()
	delete(n.activeLinks, deviceID)
}

// LinkFor returns the active session link for a device, if any.
func (n *Node) LinkFor(deviceID string) (*Link, bool) {
	n.bulkMu.Lock()
	defer n.bulkMu.Unlock()
	l, ok := n.activeLinks[deviceID]
	return l, ok
}

// SendNotificationTo mirrors a notification to a connected peer (Phase 4). It
// is a no-op if the peer doesn't advertise notify-show or has no live session.
func (n *Node) SendNotificationTo(deviceID, app, title, body, id string) error {
	l, ok := n.LinkFor(deviceID)
	if !ok || !l.HasCapabilityRemote(wire.CapNotifyShow) {
		return nil
	}
	return l.SendNotification(app, title, body, id)
}

// Handlers are optional callbacks for received capability messages/events.
type Handlers struct {
	OnFileReceived func(path string, offer wire.FileOfferBody)
	OnClipboard    func(fromDeviceID string, body wire.ClipboardPushBody)
	OnNotification func(fromDeviceID string, body wire.NotificationBody)
	OnPaired       func(PinnedPeer)
	OnSessionReady func(deviceID string, remote wire.HelloBody)
	OnInput        func(deviceID string, ev wire.InputEventBody)
	Log            func(string)
}

func (n *Node) logf(format string, args ...interface{}) {
	if n.handlers.Log != nil {
		n.handlers.Log(fmt.Sprintf(format, args...))
	}
}

func (n *Node) SetHandlers(h Handlers) { n.handlers = h }

func (n *Node) ListenPort() uint16 { return n.listenPort }

// Start begins listening; policy is pinned unless PairingEnabled is set.
func (n *Node) Start() error {
	var err error
	n.Backend, err = transport.NewBackend(n.TLS)
	if err != nil {
		return err
	}
	ln, port, err := n.Backend.Listen(func() transport.PinPolicy {
		if n.PairingEnabled {
			return transport.PinPolicy{AcceptAny: true}
		}
		return transport.PinPolicy{Pinned: n.Peers.PinnedHashes()}
	})
	if err != nil {
		return err
	}
	n.listener = ln
	n.listenPort = port
	go n.acceptLoop()
	return nil
}

func (n *Node) Close() {
	if n.listener != nil {
		n.listener.Close()
	}
}

func (n *Node) acceptLoop() {
	for {
		conn, err := n.listener.Accept()
		if err != nil {
			return
		}
		go n.routeInbound(NewFramedConn(conn))
	}
}

func (n *Node) routeInbound(framed *FramedConn) {
	frame, ok, err := framed.NextFrame()
	if err != nil || !ok || frame.Kind != wire.KindControl {
		framed.Close()
		return
	}
	env, msg, err := wire.DecodeMessage(frame.Control)
	if err != nil {
		framed.Close()
		return
	}
	switch msg.Type {
	case wire.TypeHello:
		n.adoptInboundSession(framed, msg.Body.(wire.HelloBody), env)
	case wire.TypePairRequest:
		if !n.PairingEnabled {
			_ = framed.Send(wire.Message{Type: wire.TypePairReject, Body: wire.PairRejectBody{Reason: "pairing disabled"}})
			framed.Close()
			return
		}
		peer, err := n.RespondPairing(framed, msg.Body.(wire.PairBody), env.SessionID, n.confirmOrReject())
		framed.Close()
		if err == nil && n.handlers.OnPaired != nil {
			n.handlers.OnPaired(peer)
		}
	case wire.TypeBulkAttach:
		n.attachFileBulk(framed, msg.Body.(wire.BulkAttachBody))
	default:
		framed.Close()
	}
}

func (n *Node) confirmOrReject() Confirm {
	if n.Confirm != nil {
		return n.Confirm
	}
	return func(PairPrompt) bool { return false }
}

// Dial + pair: initiate pairing with a peer at host:port.
func (n *Node) Pair(host string, port uint16) (PinnedPeer, error) {
	conn, err := n.Backend.Dial(host, port, transport.PinPolicy{AcceptAny: true})
	if err != nil {
		return PinnedPeer{}, err
	}
	framed := NewFramedConn(conn)
	defer framed.Close()
	peer, err := n.InitiatePairing(framed, n.confirmOrReject())
	if err == nil && n.handlers.OnPaired != nil {
		n.handlers.OnPaired(peer)
	}
	return peer, err
}

func (n *Node) localHello() wire.HelloBody {
	caps := n.Capabilities
	if len(caps) == 0 {
		caps = []string{wire.CapFile, wire.CapClipboard, wire.CapNotifySource}
	}
	port := n.listenPort
	return wire.HelloBody{
		Identity:      n.ID.DeviceID(),
		Name:          n.Name,
		DeviceClass:   n.DeviceClass,
		AppVersion:    n.AppVersion,
		Pubkey:        n.ID.Pub,
		Capabilities:  caps,
		PlatformWalls: []string{},
		ListenPort:    &port,
	}
}

func newSessionID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func randToken() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func splitHostPort(addr string) (string, string, error) {
	return net.SplitHostPort(addr)
}
