package session

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/auston/conduit-core/identity"
)

// identityBundle is the on-disk form (a boring JSON blob; the daemon has no
// keychain). Ed25519 seed + TLS cert DER + EC private key (PKCS#8).
type identityBundle struct {
	Ed25519Seed []byte `json:"ed25519_seed"`
	TLSCertDER  []byte `json:"tls_cert_der"`
	TLSKeyPKCS8 []byte `json:"tls_key_pkcs8"`
	Name        string `json:"name"`
}

// LoadIdentity reads a persisted identity + TLS material.
func LoadIdentity(path string) (identity.Identity, identity.TLSMaterial, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return identity.Identity{}, identity.TLSMaterial{}, err
	}
	var b identityBundle
	if err := json.Unmarshal(data, &b); err != nil {
		return identity.Identity{}, identity.TLSMaterial{}, err
	}
	id := identity.FromSeed(b.Ed25519Seed)
	keyAny, err := x509.ParsePKCS8PrivateKey(b.TLSKeyPKCS8)
	if err != nil {
		return identity.Identity{}, identity.TLSMaterial{}, err
	}
	ecKey, ok := keyAny.(*ecdsa.PrivateKey)
	if !ok {
		return identity.Identity{}, identity.TLSMaterial{}, errors.New("stored TLS key is not EC")
	}
	tls := identity.TLSMaterial{
		CertDER:    b.TLSCertDER,
		Priv:       ecKey,
		PubkeyHash: identity.PublicKeyHashX963(&ecKey.PublicKey),
	}
	return id, tls, nil
}

// CreateIdentity mints and persists a new identity + TLS material.
func CreateIdentity(path, name string) (identity.Identity, identity.TLSMaterial, error) {
	id, err := identity.Generate()
	if err != nil {
		return identity.Identity{}, identity.TLSMaterial{}, err
	}
	tls, err := identity.GenerateTLSMaterial("conduit-" + id.DeviceID()[:16])
	if err != nil {
		return identity.Identity{}, identity.TLSMaterial{}, err
	}
	pkcs8, err := x509.MarshalPKCS8PrivateKey(tls.Priv)
	if err != nil {
		return identity.Identity{}, identity.TLSMaterial{}, err
	}
	b := identityBundle{
		Ed25519Seed: id.Priv.Seed(),
		TLSCertDER:  tls.CertDER,
		TLSKeyPKCS8: pkcs8,
		Name:        name,
	}
	data, err := json.MarshalIndent(b, "", "  ")
	if err != nil {
		return identity.Identity{}, identity.TLSMaterial{}, err
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return identity.Identity{}, identity.TLSMaterial{}, err
	}
	return id, tls, nil
}
