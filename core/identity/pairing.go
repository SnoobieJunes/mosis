package identity

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

var pairingContext = []byte("conduit-pairing-v1")

// pairingMaterial = SHA256(context | min(pubA,pubB) | max(pubA,pubB)).
func pairingMaterial(pubA, pubB []byte) []byte {
	low, high := pubA, pubB
	if bytes.Compare(pubA, pubB) > 0 {
		low, high = pubB, pubA
	}
	h := sha256.New()
	h.Write(pairingContext)
	h.Write(low)
	h.Write(high)
	return h.Sum(nil)
}

// VerificationCode is the 6-digit confirm code, zero-padded (docs/adr/0004).
func VerificationCode(pubA, pubB []byte) string {
	m := pairingMaterial(pubA, pubB)
	v := binary.BigEndian.Uint32(m[0:4])
	return fmt.Sprintf("%06d", v%1_000_000)
}

// VerificationWords is the word pair from bytes 4 and 5 of the material.
func VerificationWords(pubA, pubB []byte) (string, string) {
	m := pairingMaterial(pubA, pubB)
	return Wordlist[m[4]], Wordlist[m[5]]
}
