package session

import (
	"bytes"
	"crypto/rand"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/auston/conduit-core/identity"
	"github.com/auston/conduit-core/wire"
)

func newTestNode(t *testing.T, name string) *Node {
	t.Helper()
	dir := t.TempDir()
	id, tls, err := CreateIdentity(filepath.Join(dir, "id.json"), name)
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	return &Node{
		Name: name, DeviceClass: "desktop", AppVersion: "test",
		ID: id, TLS: tls,
		Peers:      LoadPeerStore(filepath.Join(dir, "peers.json")),
		ReceiveDir: filepath.Join(dir, "recv"),
	}
}

// Go↔Go: pair, connect, transfer a file with hash verification, exchange
// clipboard + notification. Validates the whole Go session stack before it is
// asked to interoperate with Swift.
func TestGoToGoPairAndTransfer(t *testing.T) {
	a := newTestNode(t, "A") // initiator / sender
	b := newTestNode(t, "B") // listener / receiver

	received := make(chan wire.FileOfferBody, 1)
	clip := make(chan string, 1)
	note := make(chan wire.NotificationBody, 1)
	b.SetHandlers(Handlers{
		OnFileReceived: func(path string, o wire.FileOfferBody) { received <- o },
		OnClipboard:    func(_ string, body wire.ClipboardPushBody) { clip <- string(body.Data) },
		OnNotification: func(_ string, body wire.NotificationBody) { note <- body },
	})
	a.Confirm = func(PairPrompt) bool { return true }
	b.Confirm = func(PairPrompt) bool { return true }

	if err := b.Start(); err != nil {
		t.Fatalf("b.Start: %v", err)
	}
	defer b.Close()
	if err := a.Start(); err != nil {
		t.Fatalf("a.Start: %v", err)
	}
	defer a.Close()

	// Pair (B accepts, A initiates).
	b.PairingEnabled = true
	peerFromA, err := a.Pair("127.0.0.1", b.ListenPort())
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	b.PairingEnabled = false
	if peerFromA.DeviceID != b.ID.DeviceID() {
		t.Fatalf("A pinned wrong device")
	}
	// Both sides must have pinned each other with matching pairing codes.
	if VerificationCodeMatch(a, b) == false {
		t.Fatalf("pairing codes differ")
	}

	// Connect A→B and send a 3 MiB random file.
	peer := b.ID.DeviceID()
	var bPeer PinnedPeer
	for _, p := range a.Peers.All() {
		if p.DeviceID == peer {
			bPeer = p
		}
	}
	link, err := a.Connect(bPeer, "127.0.0.1", b.ListenPort())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}

	srcPath, wantSHA := makeRandomFile(t, 3)
	if err := link.SendFile(srcPath); err != nil {
		t.Fatalf("send file: %v", err)
	}
	select {
	case o := <-received:
		if o.SHA256 != wantSHA {
			t.Fatalf("received hash mismatch")
		}
		// The file landed in B's receive dir with the right bytes.
		got := filepath.Join(b.ReceiveDir, o.Name)
		if !bytes.Equal(readFile(t, got), readFile(t, srcPath)) {
			t.Fatalf("received bytes differ")
		}
	case <-time.After(15 * time.Second):
		t.Fatalf("file not received")
	}

	// Clipboard A→B.
	if err := link.SendClipboardText("hello from go"); err != nil {
		t.Fatalf("clipboard: %v", err)
	}
	select {
	case got := <-clip:
		if got != "hello from go" {
			t.Fatalf("clipboard mismatch: %q", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("clipboard not received")
	}

	// Notification A→B (Phase 4 capability).
	if err := link.SendNotification("Mail", "New message", "from Leroy", "n1"); err != nil {
		t.Fatalf("notify: %v", err)
	}
	select {
	case got := <-note:
		if got.Title != "New message" || got.AppName != "Mail" {
			t.Fatalf("notification mismatch: %+v", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("notification not received")
	}
}

// VerificationCodeMatch confirms both nodes derive the same pairing code.
func VerificationCodeMatch(a, b *Node) bool {
	ca := identity.VerificationCode(a.ID.Pub, b.ID.Pub)
	cb := identity.VerificationCode(b.ID.Pub, a.ID.Pub)
	return ca == cb
}

func makeRandomFile(t *testing.T, mib int) (string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "data.bin")
	buf := make([]byte, mib*1024*1024)
	rand.Read(buf)
	if err := os.WriteFile(path, buf, 0o644); err != nil {
		t.Fatal(err)
	}
	sum, _, err := sha256File(path)
	if err != nil {
		t.Fatal(err)
	}
	return path, sum
}

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
