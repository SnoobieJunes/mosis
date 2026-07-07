package identity

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"time"
)

// TLSMaterial is a device's TLS half: a P-256 key in a long-lived self-signed
// certificate. The pinned value is SHA-256 over the public key in X9.63
// uncompressed form (0x04||X||Y), which is exactly what Apple's Security
// framework hashes — so Go and Swift compute the same tls_pubkey_sha256
// (docs/adr/0002).
type TLSMaterial struct {
	CertDER    []byte
	Priv       *ecdsa.PrivateKey
	PubkeyHash []byte
}

// PublicKeyHashX963 is the pinned identity of an EC public key.
func PublicKeyHashX963(pub *ecdsa.PublicKey) []byte {
	point := elliptic.Marshal(pub.Curve, pub.X, pub.Y) //nolint:staticcheck // X9.63 uncompressed, matches Apple
	sum := sha256.Sum256(point)
	return sum[:]
}

func GenerateTLSMaterial(commonName string) (TLSMaterial, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return TLSMaterial{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return TLSMaterial{}, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: commonName},
		NotBefore:             now.Add(-24 * time.Hour),
		NotAfter:              now.Add(20 * 365 * 24 * time.Hour),
		BasicConstraintsValid: true,
		IsCA:                  false,
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return TLSMaterial{}, err
	}
	return TLSMaterial{
		CertDER:    der,
		Priv:       priv,
		PubkeyHash: PublicKeyHashX963(&priv.PublicKey),
	}, nil
}
