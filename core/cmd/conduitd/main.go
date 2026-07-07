// Command conduitd is the Conduit daemon: a headless Go node for Windows,
// Linux, and macOS (spec §9 Phase 4 steps 3-4). It pairs with the Apple apps
// over LAN, receives files, mirrors sourced notifications to peers, and injects
// remote input where the platform supports it.
//
//	conduitd pair --host H --port P     pair with a peer (confirm the code)
//	conduitd run  [--pair]              run the daemon; --pair accepts new devices
//
// Config lives under ~/.config/conduit (or %APPDATA%\Conduit); received files
// land in ~/Downloads/Conduit.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/auston/conduit-core/platform"
	"github.com/auston/conduit-core/session"
	"github.com/auston/conduit-core/wire"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: conduitd <pair|run> [flags]")
		os.Exit(2)
	}
	mode := os.Args[1]
	fs := flag.NewFlagSet(mode, flag.ExitOnError)
	host := fs.String("host", "", "peer host (pair)")
	port := fs.Int("port", 0, "peer port (pair)")
	acceptPairing := fs.Bool("pair", false, "accept incoming pairing (run)")
	_ = fs.Parse(os.Args[2:])

	node, injector := buildNode()
	defer injector.Close()

	switch mode {
	case "pair":
		if *host == "" || *port == 0 {
			fatal("pair needs --host and --port")
		}
		node.Confirm = confirmInteractively
		if err := node.Start(); err != nil {
			fatal("start: %v", err)
		}
		peer, err := node.Pair(*host, uint16(*port))
		if err != nil {
			fatal("pair: %v", err)
		}
		fmt.Printf("Paired with %s (%s)\n", peer.Name, peer.DeviceID[:16])

	case "run":
		node.PairingEnabled = *acceptPairing
		node.Confirm = confirmInteractively
		node.SetHandlers(session.Handlers{
			OnPaired: func(p session.PinnedPeer) { fmt.Printf("Paired with %s\n", p.Name) },
			OnFileReceived: func(path string, o wire.FileOfferBody) {
				fmt.Printf("Received %s (%d bytes) → %s\n", o.Name, o.Size, path)
			},
			OnClipboard: func(_ string, b wire.ClipboardPushBody) { fmt.Printf("Clipboard: %s\n", string(b.Data)) },
			OnNotification: func(_ string, b wire.NotificationBody) {
				fmt.Printf("🔔 %s: %s — %s\n", b.AppName, b.Title, b.Body)
			},
			OnInput:        func(_ string, ev wire.InputEventBody) { _ = injector.Inject(ev) },
			OnSessionReady: func(id string, h wire.HelloBody) { fmt.Printf("Connected: %s\n", h.Name) },
			Log:            func(s string) { fmt.Fprintf(os.Stderr, "[log] %s\n", s) },
		})
		if err := node.Start(); err != nil {
			fatal("start: %v", err)
		}
		fmt.Printf("conduitd running as %q on %s\n", node.Name, runtime.GOOS)
		fmt.Printf("  listen port : %d\n", node.ListenPort())
		fmt.Printf("  device id   : %s\n", node.ID.DeviceID())
		fmt.Printf("  input inject: %s\n", injector.Backend())
		fmt.Printf("  paired peers: %d\n", len(node.Peers.All()))
		if node.PairingEnabled {
			fmt.Println("  pairing     : ACCEPTING new devices")
		}
		// Optional: mirror sourced OS notifications to all connected peers.
		src := platform.NewNotificationSource()
		if src.Start(func(n platform.Notification) {
			for _, p := range node.Peers.All() {
				_ = node.SendNotificationTo(p.DeviceID, n.AppName, n.Title, n.Body, n.ID)
			}
		}) {
			fmt.Println("  notify src  : watching OS notifications")
			defer src.Stop()
		}
		waitForSignal()

	default:
		fatal("unknown mode %q", mode)
	}
}

func buildNode() (*session.Node, platform.Injector) {
	cfgDir := configDir()
	os.MkdirAll(cfgDir, 0o700)
	id, tls, err := session.LoadIdentity(filepath.Join(cfgDir, "identity.json"))
	if err != nil {
		id, tls, err = session.CreateIdentity(filepath.Join(cfgDir, "identity.json"), hostname())
		if err != nil {
			fatal("identity: %v", err)
		}
	}
	injector := platform.NewInjector()
	caps := []string{wire.CapFile, wire.CapClipboard, wire.CapNotifySource}
	if injector.Available() {
		caps = append(caps, wire.CapInputInject)
	}
	node := &session.Node{
		Name:         hostname(),
		DeviceClass:  "desktop",
		AppVersion:   "conduitd-0.1",
		ID:           id,
		TLS:          tls,
		Peers:        session.LoadPeerStore(filepath.Join(cfgDir, "peers.json")),
		ReceiveDir:   receiveDir(),
		Capabilities: caps,
	}
	return node, injector
}

func confirmInteractively(p session.PairPrompt) bool {
	fmt.Printf("\nPairing with %s\n", p.RemoteName)
	fmt.Printf("  Confirm BOTH screens show code %s and words %s-%s\n", p.Code, p.WordA, p.WordB)
	fmt.Print("  Match? [y/N] ")
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(line)), "y")
}

func waitForSignal() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
	<-ch
	fmt.Println("\nshutting down")
}

func configDir() string {
	if runtime.GOOS == "windows" {
		if appData := os.Getenv("APPDATA"); appData != "" {
			return filepath.Join(appData, "Conduit")
		}
	}
	home, _ := os.UserHomeDir()
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "conduit")
	}
	return filepath.Join(home, ".config", "conduit")
}

func receiveDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Downloads", "Conduit")
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "Conduit Daemon"
	}
	return h
}

func fatal(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}
