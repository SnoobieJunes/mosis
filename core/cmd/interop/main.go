// Command interop is a scriptable Go node used by the cross-implementation
// interop test (tools/conformance) and by hand. It drives one Go node through
// pair / connect / send-file / send-clipboard against a Swift (or Go) peer,
// printing machine-readable lines the Swift test asserts on.
//
// Modes:
//
//	interop listen  --state DIR --receive DIR [--pair]
//	    Start a node, print "LISTEN <port> <deviceID> <tlsKeyHex>", then serve.
//	    With --pair, accept pairing (auto-confirm) and print "PAIRED <deviceID>".
//	interop pair    --state DIR --host H --port P
//	    Dial and pair (auto-confirm); print "PAIRED <deviceID> <code>".
//	interop send    --state DIR --host H --port P --peer ID --file PATH
//	    Connect to a pinned peer and send a file; print "SENT" or "ERR ...".
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/auston/conduit-core/identity"
	"github.com/auston/conduit-core/session"
	"github.com/auston/conduit-core/wire"
)

func main() {
	if len(os.Args) < 2 {
		fatal("usage: interop <listen|pair|send> ...")
	}
	mode := os.Args[1]
	fs := flag.NewFlagSet(mode, flag.ExitOnError)
	state := fs.String("state", "", "state dir (identity, peers)")
	receive := fs.String("receive", "", "receive dir")
	host := fs.String("host", "127.0.0.1", "peer host")
	port := fs.Int("port", 0, "peer port")
	peerID := fs.String("peer", "", "pinned peer device id")
	file := fs.String("file", "", "file to send")
	pair := fs.Bool("pair", false, "accept pairing")
	notify := fs.Bool("notify", false, "on session ready, mirror a test notification")
	_ = fs.Parse(os.Args[2:])

	node := mustNode(*state, *receive)
	node.Confirm = func(p session.PairPrompt) bool {
		fmt.Printf("PROMPT %s %s %s\n", p.Code, p.WordA, p.WordB)
		return true
	}

	switch mode {
	case "listen":
		node.PairingEnabled = *pair
		node.SetHandlers(session.Handlers{
			OnPaired: func(p session.PinnedPeer) { fmt.Printf("PAIRED %s\n", p.DeviceID) },
			OnFileReceived: func(path string, o wire.FileOfferBody) {
				fmt.Printf("RECEIVED %s %d %s\n", filepath.Base(path), o.Size, o.SHA256)
			},
			OnClipboard: func(from string, b wire.ClipboardPushBody) { fmt.Printf("CLIPBOARD %s\n", string(b.Data)) },
			OnSessionReady: func(id string, h wire.HelloBody) {
				fmt.Printf("READY %s\n", id)
				if *notify {
					// Mirror a notification to the peer (Go sources, Swift shows).
					go func() {
						_ = node.SendNotificationTo(id, "Mail", "New message", "from the Go daemon", "n1")
						fmt.Printf("NOTIFIED %s\n", id)
					}()
				}
			},
			Log: func(s string) { fmt.Fprintf(os.Stderr, "log: %s\n", s) },
		})
		if err := node.Start(); err != nil {
			fatal("start: %v", err)
		}
		fmt.Printf("LISTEN %d %s %x\n", node.ListenPort(), node.ID.DeviceID(), node.TLS.PubkeyHash)
		os.Stdout.Sync()
		// Serve until stdin closes.
		bufio.NewReader(os.Stdin).ReadString('\n')

	case "pair":
		if err := node.Start(); err != nil {
			fatal("start: %v", err)
		}
		peer, err := node.Pair(*host, uint16(*port))
		if err != nil {
			fatal("pair: %v", err)
		}
		fmt.Printf("PAIRED %s\n", peer.DeviceID)

	case "send":
		node.SetHandlers(session.Handlers{Log: func(s string) { fmt.Fprintf(os.Stderr, "log: %s\n", s) }})
		if err := node.Start(); err != nil {
			fatal("start: %v", err)
		}
		var peer session.PinnedPeer
		found := false
		for _, p := range node.Peers.All() {
			if p.DeviceID == *peerID {
				peer, found = p, true
			}
		}
		if !found {
			fatal("peer %s not pinned", *peerID)
		}
		link, err := node.Connect(peer, *host, uint16(*port))
		if err != nil {
			fatal("connect: %v", err)
		}
		if err := link.SendFile(*file); err != nil {
			fatal("send: %v", err)
		}
		fmt.Println("SENT")

	default:
		fatal("unknown mode %s", mode)
	}
}

func mustNode(stateDir, receiveDir string) *session.Node {
	if stateDir == "" {
		fatal("--state required")
	}
	os.MkdirAll(stateDir, 0o700)
	if receiveDir != "" {
		os.MkdirAll(receiveDir, 0o755)
	}
	id, tls := loadOrCreateIdentity(stateDir)
	return &session.Node{
		Name:        "Go Daemon",
		DeviceClass: "desktop",
		AppVersion:  "interop",
		ID:          id,
		TLS:         tls,
		Peers:       session.LoadPeerStore(filepath.Join(stateDir, "peers.json")),
		ReceiveDir:  receiveDir,
	}
}

func fatal(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "ERR "+format+"\n", args...)
	fmt.Printf("ERR "+format+"\n", args...)
	os.Exit(1)
}

// identity persistence for the CLI (a boring JSON blob under the state dir).
func loadOrCreateIdentity(stateDir string) (identity.Identity, identity.TLSMaterial) {
	id, tls, err := session.LoadIdentity(filepath.Join(stateDir, "identity.json"))
	if err == nil {
		return id, tls
	}
	id, tls, err = session.CreateIdentity(filepath.Join(stateDir, "identity.json"), "Go Daemon")
	if err != nil {
		fatal("identity: %v", err)
	}
	return id, tls
}
