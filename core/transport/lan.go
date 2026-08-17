// Package transport is the Go LAN backend: TLS 1.3 over TCP with mandatory
// mutual certificates verified by pinned public-key hash only (spec §7). No
// plaintext path exists, matching Swift's LANBackend.
package transport

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/auston/conduit-core/identity"
)

// PinPolicy decides whether a presented peer TLS key is acceptable.
type PinPolicy struct {
	// AcceptAny is pairing mode: any key is allowed and its hash is reported
	// for the out-of-band cross-check. Off = only pinned keys pass.
	AcceptAny bool
	Pinned    map[string]bool // hex(sha256(x9.63 pubkey)) → allowed
}

func (p PinPolicy) allow(hashHex string) bool {
	if p.AcceptAny {
		return true
	}
	return p.Pinned[hashHex]
}

// Conn is an authenticated byte stream; PeerKeyHash is the pinned identity of
// the far side, extracted from the handshake.
type Conn struct {
	net.Conn
	PeerKeyHash []byte
}

// Backend holds this device's TLS identity and mints pinned client/server conns.
type Backend struct {
	material identity.TLSMaterial
	cert     tls.Certificate
}

func NewBackend(material identity.TLSMaterial) (*Backend, error) {
	cert := tls.Certificate{
		Certificate: [][]byte{material.CertDER},
		PrivateKey:  material.Priv,
	}
	return &Backend{material: material, cert: cert}, nil
}

// peerKeyHashFromState returns the pinned hash of the peer leaf certificate.
func peerKeyHashFromState(state tls.ConnectionState) ([]byte, error) {
	if len(state.PeerCertificates) == 0 {
		return nil, errors.New("no peer certificate")
	}
	leaf := state.PeerCertificates[0]
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, errors.New("peer key is not EC")
	}
	return identity.PublicKeyHashX963(pub), nil
}

func makeVerify(policy PinPolicy) func([][]byte, [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		if len(rawCerts) == 0 {
			return errors.New("no peer certificate")
		}
		cert, err := x509.ParseCertificate(rawCerts[0])
		if err != nil {
			return err
		}
		pub, ok := cert.PublicKey.(*ecdsa.PublicKey)
		if !ok {
			return errors.New("peer key is not EC")
		}
		hash := identity.PublicKeyHashX963(pub)
		hashHex := fmt.Sprintf("%x", hash)
		if !policy.allow(hashHex) {
			return fmt.Errorf("peer key %s not pinned", hashHex)
		}
		return nil
	}
}

// Dial opens a pinned TLS connection to host:port.
//
// Latency parity note: Go's net.TCPConn ships with TCP_NODELAY on and (since
// Go 1.23) keepalives enabled by default, matching the Swift backend's
// explicit noDelay/keepalive and the Android transport's tcpNoDelay=true —
// no per-socket tuning is needed here.
func (b *Backend) Dial(host string, port uint16, policy PinPolicy) (*Conn, error) {
	cfg := &tls.Config{
		Certificates:          []tls.Certificate{b.cert},
		MinVersion:            tls.VersionTLS13,
		InsecureSkipVerify:    true, // chain verification replaced by pinning
		VerifyPeerCertificate: makeVerify(policy),
	}
	raw, err := tls.Dial("tcp", net.JoinHostPort(host, fmt.Sprintf("%d", port)), cfg)
	if err != nil {
		return nil, err
	}
	if err := raw.Handshake(); err != nil {
		raw.Close()
		return nil, err
	}
	hash, err := peerKeyHashFromState(raw.ConnectionState())
	if err != nil {
		raw.Close()
		return nil, err
	}
	return &Conn{Conn: raw, PeerKeyHash: hash}, nil
}

// Listener accepts pinned TLS connections. policyFn is consulted per handshake
// so pairing mode and newly pinned peers take effect immediately.
type Listener struct {
	ln net.Listener
}

// ListenPortEnv pins the listen port instead of taking an ephemeral one.
// Ephemeral is right on a LAN with discovery, but wrong behind a port map: a
// container or a hand-punched firewall rule has to know the number in advance.
// Unset or unparseable keeps the ephemeral default.
const ListenPortEnv = "CONDUIT_LISTEN_PORT"

func listenAddr() string {
	raw := os.Getenv(ListenPortEnv)
	if raw == "" {
		return ":0"
	}
	port, err := strconv.Atoi(raw)
	if err != nil || port < 1 || port > 65535 {
		return ":0"
	}
	return ":" + strconv.Itoa(port)
}

func (b *Backend) Listen(policyFn func() PinPolicy) (*Listener, uint16, error) {
	tcpLn, err := net.Listen("tcp", listenAddr())
	if err != nil {
		return nil, 0, err
	}
	port := uint16(tcpLn.Addr().(*net.TCPAddr).Port)
	cfg := &tls.Config{
		Certificates: []tls.Certificate{b.cert},
		MinVersion:   tls.VersionTLS13,
		ClientAuth:   tls.RequireAnyClientCert,
		VerifyPeerCertificate: func(rawCerts [][]byte, chains [][]*x509.Certificate) error {
			return makeVerify(policyFn())(rawCerts, chains)
		},
	}
	tlsLn := tls.NewListener(tcpLn, cfg)
	return &Listener{ln: tlsLn}, port, nil
}

// HandshakeTimeout bounds how long an inbound peer may take to complete the TLS
// handshake. A peer that opens TCP and then says nothing is otherwise
// indistinguishable from a slow one, and used to block the whole listener.
const HandshakeTimeout = 10 * time.Second

// AcceptRaw returns the next inbound connection with its handshake NOT yet run.
//
// Split out from Accept on 2026-08-17. The handshake used to run inside the
// accept path, and the accept path is a single loop (session.Node.acceptLoop),
// so one peer that connected and never sent a ClientHello blocked every
// subsequent connection — with no deadline, indefinitely. Worse, a handshake
// error surfaced as an Accept error, and the loop treats an Accept error as
// "listener is gone" and returns: a single malformed connection stopped the
// daemon from ever accepting again.
//
// Callers must run Authenticate on the result, off the accept loop.
func (l *Listener) AcceptRaw() (net.Conn, error) {
	return l.ln.Accept()
}

// Authenticate completes the TLS handshake on a connection from AcceptRaw and
// extracts the pinned peer key. Safe to call from a per-connection goroutine.
func Authenticate(raw net.Conn) (*Conn, error) {
	tlsConn, ok := raw.(*tls.Conn)
	if !ok {
		raw.Close()
		return nil, errors.New("transport: inbound connection is not TLS")
	}
	// The deadline covers the handshake only; it is cleared afterwards so it
	// cannot expire mid-session.
	if err := tlsConn.SetDeadline(time.Now().Add(HandshakeTimeout)); err != nil {
		tlsConn.Close()
		return nil, err
	}
	if err := tlsConn.Handshake(); err != nil {
		tlsConn.Close()
		return nil, err
	}
	if err := tlsConn.SetDeadline(time.Time{}); err != nil {
		tlsConn.Close()
		return nil, err
	}
	hash, err := peerKeyHashFromState(tlsConn.ConnectionState())
	if err != nil {
		tlsConn.Close()
		return nil, err
	}
	return &Conn{Conn: tlsConn, PeerKeyHash: hash}, nil
}

// Accept returns the next authenticated inbound connection. Convenience for
// tests and single-connection tools; servers should use AcceptRaw +
// Authenticate so one stalled peer cannot hold up the listener.
func (l *Listener) Accept() (*Conn, error) {
	raw, err := l.AcceptRaw()
	if err != nil {
		return nil, err
	}
	return Authenticate(raw)
}

func (l *Listener) Close() error { return l.ln.Close() }

// PinHash formats a key hash for a PinPolicy set.
func PinHash(hash []byte) string {
	sum := hash
	if len(sum) != sha256.Size {
		s := sha256.Sum256(hash)
		sum = s[:]
	}
	return fmt.Sprintf("%x", sum)
}
