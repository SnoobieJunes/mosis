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

func (b *Backend) Listen(policyFn func() PinPolicy) (*Listener, uint16, error) {
	tcpLn, err := net.Listen("tcp", ":0")
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

// Accept returns the next authenticated inbound connection.
func (l *Listener) Accept() (*Conn, error) {
	raw, err := l.ln.Accept()
	if err != nil {
		return nil, err
	}
	tlsConn := raw.(*tls.Conn)
	if err := tlsConn.Handshake(); err != nil {
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
