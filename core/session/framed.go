// Package session implements the Conduit session layer in Go: framed
// connections, the pairing ceremony, HELLO negotiation, and the file/clipboard/
// notification capabilities — enough for a Go daemon to interoperate with the
// Apple apps over the real protocol.
package session

import (
	"sync"

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
func (f *FramedConn) Send(m wire.Message) error {
	f.sendMu.Lock()
	seq := f.nextSeq
	f.nextSeq++
	f.sendMu.Unlock()
	payload, err := wire.EncodeMessage(f.sessionID, seq, m)
	if err != nil {
		return err
	}
	return f.writeAll(wire.EncodeControl(payload))
}

func (f *FramedConn) SendChunk(c wire.ChunkFrame) error {
	return f.writeAll(wire.EncodeChunk(c))
}

func (f *FramedConn) writeAll(data []byte) error {
	f.sendMu.Lock()
	defer f.sendMu.Unlock()
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
