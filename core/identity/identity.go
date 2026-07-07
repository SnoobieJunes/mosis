// Package identity implements Conduit's device identity, pairing math, and TLS
// material in Go, matching the Swift implementation byte-for-byte so the two
// interoperate and share the golden vectors (docs/protocol.md §Security).
package identity

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
)

var tlsBindingContext = []byte("conduit-tls-binding-v1")

// Identity is a device's long-term Ed25519 keypair (spec §5.2).
type Identity struct {
	Priv ed25519.PrivateKey
	Pub  ed25519.PublicKey
}

func Generate() (Identity, error) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		return Identity{}, err
	}
	return Identity{Priv: priv, Pub: pub}, nil
}

// FromSeed builds an identity from a 32-byte Ed25519 seed (for vectors/tests).
func FromSeed(seed []byte) Identity {
	priv := ed25519.NewKeyFromSeed(seed)
	return Identity{Priv: priv, Pub: priv.Public().(ed25519.PublicKey)}
}

// DeviceID is the lowercase hex SHA-256 of the raw public key.
func DeviceID(pubkey []byte) string {
	sum := sha256.Sum256(pubkey)
	return hex.EncodeToString(sum[:])
}

func (id Identity) DeviceID() string {
	return DeviceID(id.Pub)
}

// SignTLSBinding proves this identity owns a TLS key (docs/adr/0002).
func (id Identity) SignTLSBinding(tlsPublicKeyHash []byte) []byte {
	msg := append(append([]byte(nil), tlsBindingContext...), tlsPublicKeyHash...)
	return ed25519.Sign(id.Priv, msg)
}

// VerifyTLSBinding checks a binding signature against a public key.
func VerifyTLSBinding(sig, tlsPublicKeyHash, pubkey []byte) bool {
	if len(pubkey) != ed25519.PublicKeySize {
		return false
	}
	msg := append(append([]byte(nil), tlsBindingContext...), tlsPublicKeyHash...)
	return ed25519.Verify(ed25519.PublicKey(pubkey), msg, sig)
}
