// Command conduitview is the Conduit screen viewer + remote controller for
// Linux: it renders a paired peer's screen in an X11 window and forwards
// pointer/keyboard input back over the wire (spec §9 Phase 3 viewer + Phase 2
// controller, ADR 0015 absolute pointing). The daemon half lives in conduitd;
// this is the interactive half, split out because a viewer has a window and a
// daemon must not.
//
//	conduitview probe                        report what can run here, honestly
//	conduitview pair --host H --port P       pair with a peer (confirm the code)
//	conduitview view --host H --port P [--peer PREFIX] [--view-only]
//
// Config lives under ~/.config/conduit-view — deliberately NOT conduitd's
// directory: a device identity belongs to one node, and sharing it between
// two running processes would present one identity from two listeners.
//
// There is no discovery in the Go core yet (no mDNS), so view/pair take the
// peer's host and listener port explicitly; conduitd prints both at startup.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/auston/conduit-core/screencast"
	"github.com/auston/conduit-core/session"
	"github.com/auston/conduit-core/wire"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: conduitview <probe|pair|view> [flags]")
		os.Exit(2)
	}
	mode := os.Args[1]
	fs := flag.NewFlagSet(mode, flag.ExitOnError)
	host := fs.String("host", "", "peer host")
	port := fs.Int("port", 0, "peer listener port (conduitd prints it at startup)")
	peerSel := fs.String("peer", "", "paired peer to view: device-id prefix or name (default: the only paired peer)")
	maxWidth := fs.Int("max-width", 1920, "request the stream fit this width")
	maxHeight := fs.Int("max-height", 1080, "request the stream fit this height")
	fps := fs.Int("fps", 30, "request at most this frame rate")
	viewOnly := fs.Bool("view-only", false, "do not request input control")
	_ = fs.Parse(os.Args[2:])

	switch mode {
	case "probe":
		probe()
	case "pair":
		if *host == "" || *port == 0 {
			fatal("pair needs --host and --port")
		}
		node := buildNode()
		node.Confirm = confirmInteractively
		if err := node.Start(); err != nil {
			fatal("start: %v", err)
		}
		peer, err := node.Pair(*host, uint16(*port))
		if err != nil {
			fatal("pair: %v", err)
		}
		fmt.Printf("Paired with %s (%s)\n", peer.Name, peer.DeviceID[:16])
	case "view":
		if *host == "" || *port == 0 {
			fatal("view needs --host and --port (conduitd prints its listen port)")
		}
		view(*host, uint16(*port), *peerSel, *maxWidth, *maxHeight, *fps, !*viewOnly)
	default:
		fatal("unknown mode %q", mode)
	}
}

// probe prints what this machine can actually do, with reasons — the same
// honesty rule the daemon's capability advertisement follows.
func probe() {
	ffmpeg, reason := screencast.FindFFmpeg()
	if ffmpeg != "" {
		fmt.Printf("ffmpeg        : %s (decoders: %s)\n", ffmpeg,
			strings.Join(screencast.DecoderCodecs(ffmpeg), ", "))
	} else {
		fmt.Printf("ffmpeg        : MISSING — %s\n", reason)
	}
	if runtime.GOOS == "linux" {
		if os.Getenv("DISPLAY") != "" {
			fmt.Printf("X11 (DISPLAY) : %s\n", os.Getenv("DISPLAY"))
		} else {
			fmt.Println("X11 (DISPLAY) : not set — no window can open (Wayland-native is not implemented; XWayland sets DISPLAY)")
		}
	} else {
		fmt.Printf("window        : unavailable — the viewer window is Linux/X11 only (this is %s)\n", runtime.GOOS)
	}
}

func view(host string, port uint16, peerSel string, maxW, maxH, fps int, wantInput bool) {
	ffmpeg, reason := screencast.FindFFmpeg()
	if ffmpeg == "" {
		fatal("cannot view without ffmpeg: %s", reason)
	}
	node := buildNode()
	peer, err := resolvePeer(node, peerSel)
	if err != nil {
		fatal("%v", err)
	}
	if err := node.Start(); err != nil {
		fatal("start: %v", err)
	}
	defer node.Close()

	viewer := screencast.NewViewer(node, screencast.ViewerConfig{
		FFmpegPath:  ffmpeg,
		Window:      screencast.NewWindow(),
		MaxWidth:    maxW,
		MaxHeight:   maxH,
		MaxFPS:      fps,
		EnableInput: wantInput,
		Log:         func(s string) { fmt.Println("  " + s) },
	})
	node.SetHandlers(session.Handlers{
		OnScreenOffer:   viewer.HandleOffer,
		OnScreenReject:  viewer.HandleReject,
		OnScreenEnd:     viewer.HandleEnd,
		OnScreenFrame:   viewer.HandleControlFrame,
		OnInputStatus:   viewer.HandleInputStatus,
		OnSessionClosed: viewer.HandleSessionClosed,
		Log:             func(s string) { fmt.Fprintf(os.Stderr, "[log] %s\n", s) },
	})

	link, err := node.Connect(peer, host, port)
	if err != nil {
		fatal("connect to %s at %s:%d: %v", peer.Name, host, port, err)
	}
	fmt.Printf("Connected to %s; requesting its screen…\n", peer.Name)
	if err := viewer.Start(link); err != nil {
		fatal("%v", err)
	}
	if err := viewer.Wait(); err != nil {
		fatal("viewing ended: %v", err)
	}
	fmt.Printf("Viewing ended (%d frames drawn).\n", viewer.BlitCount())
}

func resolvePeer(node *session.Node, sel string) (session.PinnedPeer, error) {
	peers := node.Peers.All()
	if len(peers) == 0 {
		return session.PinnedPeer{}, fmt.Errorf("no paired peers — run `conduitview pair --host H --port P` first")
	}
	if sel == "" {
		if len(peers) == 1 {
			return peers[0], nil
		}
		var names []string
		for _, p := range peers {
			names = append(names, fmt.Sprintf("%s (%s)", p.Name, p.DeviceID[:8]))
		}
		return session.PinnedPeer{}, fmt.Errorf("multiple paired peers — pick one with --peer: %s", strings.Join(names, ", "))
	}
	for _, p := range peers {
		if strings.HasPrefix(p.DeviceID, sel) || strings.EqualFold(p.Name, sel) {
			return p, nil
		}
	}
	return session.PinnedPeer{}, fmt.Errorf("no paired peer matches %q", sel)
}

func buildNode() *session.Node {
	cfgDir := configDir()
	os.MkdirAll(cfgDir, 0o700)
	id, tls, err := session.LoadIdentity(filepath.Join(cfgDir, "identity.json"))
	if err != nil {
		id, tls, err = session.CreateIdentity(filepath.Join(cfgDir, "identity.json"), hostname()+" viewer")
		if err != nil {
			fatal("identity: %v", err)
		}
	}
	return &session.Node{
		Name:        hostname() + " viewer",
		DeviceClass: "desktop",
		AppVersion:  "conduitview-0.1",
		ID:          id,
		TLS:         tls,
		Peers:       session.LoadPeerStore(filepath.Join(cfgDir, "peers.json")),
		ReceiveDir:  filepath.Join(cfgDir, "received"),
		// The viewer end of the direction-specific pair (spec §4); it never
		// sources a screen and never injects input.
		Capabilities: []string{wire.CapScreenView},
	}
}

func confirmInteractively(p session.PairPrompt) bool {
	fmt.Printf("\nPairing with %s\n", p.RemoteName)
	fmt.Printf("  Confirm BOTH screens show code %s and words %s-%s\n", p.Code, p.WordA, p.WordB)
	fmt.Print("  Match? [y/N] ")
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(line)), "y")
}

func configDir() string {
	home, _ := os.UserHomeDir()
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "conduit-view")
	}
	return filepath.Join(home, ".config", "conduit-view")
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "Conduit Viewer"
	}
	return h
}

func fatal(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}
