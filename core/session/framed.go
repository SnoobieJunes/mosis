// Package session implements the Conduit session layer in Go: framed
// connections, the pairing ceremony, HELLO negotiation, and the file/clipboard/
// notification capabilities — enough for a Go daemon to interoperate with the
// Apple apps over the real protocol.
package session

import (
	"sync"
	"time"

	"github.com/auston/conduit-core/transport"
	"github.com/auston/conduit-core/wire"
)

// FramedConn adds Conduit TLV framing and envelope sequencing to a byte stream.
type FramedConn struct {
	conn      *transport.Conn
	reader    wire.FrameReader
	pending   []wire.Frame
	sessionID string
	nextSeq   uint64
	sendMu    sync.Mutex
	readBuf   [64 * 1024]byte
}

func NewFramedConn(conn *transport.Conn) *FramedConn {
	return &FramedConn{conn: conn}
}

func (f *FramedConn) PeerKeyHash() []byte { return f.conn.PeerKeyHash }

func (f *FramedConn) RemoteHost() string {
	if addr := f.conn.RemoteAddr(); addr != nil {
		host, _, err := splitHostPort(addr.String())
		if err == nil {
			return host
		}
	}
	return ""
}

func (f *FramedConn) SetSessionID(id string) { f.sessionID = id }
func (f *FramedConn) SessionID() string      { return f.sessionID }

// NextFrame returns the next complete frame, blocking until one is available.
func (f *FramedConn) NextFrame() (wire.Frame, bool, error) {
	for len(f.pending) == 0 {
		n, err := f.conn.Read(f.readBuf[:])
		if n > 0 {
			frames, ferr := f.reader.Append(f.readBuf[:n])
			if ferr != nil {
				return wire.Frame{}, false, ferr
			}
			f.pending = append(f.pending, frames...)
		}
		if err != nil {
			if len(f.pending) > 0 {
				break
			}
			return wire.Frame{}, false, err
		}
	}
	frame := f.pending[0]
	f.pending = f.pending[1:]
	return frame, true, nil
}

// Send encodes and writes one control message, assigning the next seq.
//
// Allocate-and-write is ONE critical section (2026-08-17). It used to take
// sendMu to bump nextSeq, release it, encode, then take it again to write — so
// two concurrent senders could get seq 1 and 2 and then write them in the other
// order. The frames themselves never interleaved (writeAll holds the lock for a
// whole frame), but the envelope seq did go backwards on the wire, which the
// peer is entitled to treat as a protocol violation. Every capability that
// sends from its own goroutine — screen ACKs, file progress, input, clipboard —
// shares one of these.
func (f *FramedConn) Send(m wire.Message) error {
	f.sendMu.Lock()
	defer f.sendMu.Unlock()
	payload, err := wire.EncodeMessage(f.sessionID, f.nextSeq, m)
	if err != nil {
		// Do not burn a seq on a message that never reached the wire.
		return err
	}
	f.nextSeq++
	return f.writeLocked(wire.EncodeControl(payload))
}

func (f *FramedConn) SendChunk(c wire.ChunkFrame) error {
	return f.writeAll(wire.EncodeChunk(c))
}

func (f *FramedConn) writeAll(data []byte) error {
	f.sendMu.Lock()
	defer f.sendMu.Unlock()
	return f.writeLocked(data)
}

// WriteTimeout bounds a single frame write.
//
// Added 2026-08-17. There was no deadline anywhere in the send path, so a peer
// that stopped reading — a viewer whose window froze, a phone that slept, a
// process suspended in a debugger — filled the socket buffer and then blocked
// the writer forever *while holding sendMu*. On the control-lane screen
// fallback that meant one stalled viewer wedged the whole link: no clipboard, no
// input, no file acks, and no PONG, so the far end eventually declared the
// session dead for the wrong reason. A peer that cannot absorb one frame in
// this long is gone, and the screen path already knows how to demote or stop
// when a send fails.
const WriteTimeout = 10 * time.Second

// writeLocked requires sendMu to be held by the caller.
func (f *FramedConn) writeLocked(data []byte) error {
	if err := f.conn.SetWriteDeadline(time.Now().Add(WriteTimeout)); err != nil {
		return err
	}
	defer func() { _ = f.conn.SetWriteDeadline(time.Time{}) }()
	for len(data) > 0 {
		n, err := f.conn.Write(data)
		if err != nil {
			return err
		}
		data = data[n:]
	}
	return nil
}

func (f *FramedConn) Close() error { return f.conn.Close() }
