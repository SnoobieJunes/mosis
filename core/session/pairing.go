package session

import (
	"encoding/hex"
	"errors"
	"strings"

	"github.com/auston/conduit-core/identity"
	"github.com/auston/conduit-core/wire"
)

// PinnedPeer is a paired device (spec §7): identity pinned at pairing.
type PinnedPeer struct {
	DeviceID        string `json:"device_id"`
	Name            string `json:"name"`
	DeviceClass     string `json:"device_class"`
	Ed25519Pubkey   []byte `json:"ed25519_pubkey"`
	TLSPubkeySHA256 []byte `json:"tls_pubkey_sha256"`
}

// PairPrompt is what both screens must show and the user cross-checks.
type PairPrompt struct {
	Code       string
	WordA      string
	WordB      string
	RemoteName string
}

var (
	ErrIdentityMismatch  = errors.New("identity does not match pubkey")
	ErrInvalidBinding    = errors.New("invalid TLS binding signature")
	ErrTLSKeySubstituted = errors.New("presented TLS key does not match signed binding")
	ErrPeerRejected      = errors.New("peer rejected pairing")
)

// localPairBody builds this device's PAIR_REQUEST/PAIR_RESPONSE body.
func (n *Node) localPairBody() wire.PairBody {
	return wire.PairBody{
		Identity:        n.ID.DeviceID(),
		Name:            n.Name,
		DeviceClass:     n.DeviceClass,
		Pubkey:          n.ID.Pub,
		TLSPubkeySHA256: hex.EncodeToString(n.TLS.PubkeyHash),
		BindingSig:      n.ID.SignTLSBinding(n.TLS.PubkeyHash),
	}
}

// validateRemote checks a remote pair body against the presented TLS key.
func validateRemote(remote wire.PairBody, connKeyHash []byte) error {
	if identity.DeviceID(remote.Pubkey) != remote.Identity {
		return ErrIdentityMismatch
	}
	claimed, err := hex.DecodeString(remote.TLSPubkeySHA256)
	if err != nil || !identity.VerifyTLSBinding(remote.BindingSig, claimed, remote.Pubkey) {
		return ErrInvalidBinding
	}
	if connKeyHash == nil || hex.EncodeToString(connKeyHash) != remote.TLSPubkeySHA256 {
		return ErrTLSKeySubstituted
	}
	return nil
}

func pinnedFrom(remote wire.PairBody) PinnedPeer {
	tlsHash, _ := hex.DecodeString(remote.TLSPubkeySHA256)
	return PinnedPeer{
		DeviceID:        remote.Identity,
		Name:            remote.Name,
		DeviceClass:     remote.DeviceClass,
		Ed25519Pubkey:   remote.Pubkey,
		TLSPubkeySHA256: tlsHash,
	}
}

func promptFrom(localPub, remotePub []byte, remoteName string) PairPrompt {
	code := identity.VerificationCode(localPub, remotePub)
	wA, wB := identity.VerificationWords(localPub, remotePub)
	return PairPrompt{Code: code, WordA: wA, WordB: wB, RemoteName: remoteName}
}

// Confirm is the out-of-band decision callback: show the prompt, return accept.
type Confirm func(PairPrompt) bool

// InitiatePairing runs the initiator side over an accept-any connection.
func (n *Node) InitiatePairing(framed *FramedConn, confirm Confirm) (PinnedPeer, error) {
	framed.SetSessionID(newSessionID())
	local := n.localPairBody()
	if err := framed.Send(wire.Message{Type: wire.TypePairRequest, Body: local}); err != nil {
		return PinnedPeer{}, err
	}
	remote, err := expectPair(framed, wire.TypePairResponse)
	if err != nil {
		return PinnedPeer{}, err
	}
	return n.completePairing(framed, local, remote, confirm)
}

// RespondPairing runs the responder side; the caller already read the request.
func (n *Node) RespondPairing(framed *FramedConn, request wire.PairBody, requestSession string, confirm Confirm) (PinnedPeer, error) {
	framed.SetSessionID(requestSession)
	local := n.localPairBody()
	if err := framed.Send(wire.Message{Type: wire.TypePairResponse, Body: local}); err != nil {
		return PinnedPeer{}, err
	}
	return n.completePairing(framed, local, request, confirm)
}

func (n *Node) completePairing(framed *FramedConn, local, remote wire.PairBody, confirm Confirm) (PinnedPeer, error) {
	if err := validateRemote(remote, framed.PeerKeyHash()); err != nil {
		_ = framed.Send(wire.Message{Type: wire.TypePairReject, Body: wire.PairRejectBody{Reason: "validation failed"}})
		return PinnedPeer{}, err
	}
	prompt := promptFrom(local.Pubkey, remote.Pubkey, remote.Name)
	if !confirm(prompt) {
		_ = framed.Send(wire.Message{Type: wire.TypePairReject, Body: wire.PairRejectBody{Reason: "declined"}})
		return PinnedPeer{}, errors.New("declined locally")
	}
	if err := framed.Send(wire.Message{Type: wire.TypePairConfirm, Body: struct{}{}}); err != nil {
		return PinnedPeer{}, err
	}
	if err := expectConfirm(framed); err != nil {
		return PinnedPeer{}, err
	}
	peer := pinnedFrom(remote)
	n.Peers.Upsert(peer)
	return peer, nil
}

func expectPair(framed *FramedConn, want wire.MessageType) (wire.PairBody, error) {
	for {
		frame, ok, err := framed.NextFrame()
		if err != nil || !ok {
			return wire.PairBody{}, errors.New("connection lost during pairing")
		}
		if frame.Kind != wire.KindControl {
			continue
		}
		_, msg, err := wire.DecodeMessage(frame.Control)
		if err != nil {
			return wire.PairBody{}, err
		}
		switch msg.Type {
		case want:
			return msg.Body.(wire.PairBody), nil
		case wire.TypePairReject:
			return wire.PairBody{}, ErrPeerRejected
		default:
			if msg.Body == nil {
				continue // unknown type: ignore
			}
			return wire.PairBody{}, errors.New("unexpected message during pairing: " + string(msg.Type))
		}
	}
}

func expectConfirm(framed *FramedConn) error {
	for {
		frame, ok, err := framed.NextFrame()
		if err != nil || !ok {
			return errors.New("connection lost awaiting confirm")
		}
		if frame.Kind != wire.KindControl {
			continue
		}
		_, msg, err := wire.DecodeMessage(frame.Control)
		if err != nil {
			return err
		}
		switch msg.Type {
		case wire.TypePairConfirm:
			return nil
		case wire.TypePairReject:
			return ErrPeerRejected
		default:
			if msg.Body == nil {
				continue
			}
		}
	}
}

func isPairMessage(t wire.MessageType) bool {
	return strings.HasPrefix(string(t), "PAIR_")
}
