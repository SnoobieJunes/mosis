package session

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/auston/conduit-core/transport"
	"github.com/auston/conduit-core/wire"
)

// ---- Receiver ----

type incomingTransfer struct {
	offer     wire.FileOfferBody
	file      *os.File
	hasher    interface{ Write([]byte) (int, error) }
	received  uint64
	bulkToken string
	uuid      [16]byte
}

type fileReceiver struct {
	node       *Node
	link       *Link
	mu         sync.Mutex
	transfers  map[string]*incomingTransfer
	byUUID     map[[16]byte]string
	autoAccept bool
}

func newFileReceiver(n *Node, l *Link) *fileReceiver {
	return &fileReceiver{
		node: n, link: l,
		transfers:  map[string]*incomingTransfer{},
		byUUID:     map[[16]byte]string{},
		autoAccept: true, // daemon auto-accepts from paired peers
	}
}

func (r *fileReceiver) handleOffer(offer wire.FileOfferBody) {
	uuid, err := parseUUID(offer.FileID)
	if err != nil {
		_ = r.link.framed.Send(wire.Message{Type: wire.TypeFileReject, Body: wire.FileRejectBody{
			FileID: offer.FileID, Reason: "bad file id"}})
		return
	}
	if !r.autoAccept {
		_ = r.link.framed.Send(wire.Message{Type: wire.TypeFileReject, Body: wire.FileRejectBody{
			FileID: offer.FileID, Reason: "declined"}})
		return
	}
	if err := os.MkdirAll(r.node.ReceiveDir, 0o755); err != nil {
		return
	}
	partial := filepath.Join(r.node.ReceiveDir, offer.SHA256+".part")
	f, err := os.Create(partial)
	if err != nil {
		return
	}
	token := randToken()
	t := &incomingTransfer{offer: offer, file: f, hasher: sha256.New(), bulkToken: token, uuid: uuid}
	r.mu.Lock()
	r.transfers[offer.FileID] = t
	r.byUUID[uuid] = offer.FileID
	r.mu.Unlock()
	r.node.registerBulkToken(token, r) // so an inbound bulk lane finds us
	_ = r.link.framed.Send(wire.Message{Type: wire.TypeFileAccept, Body: wire.FileAcceptBody{
		FileID: offer.FileID, ResumeFromChunk: 0, BulkToken: token}})
}

// attachFileBulk binds an inbound bulk connection to an accepted transfer and
// drains its chunk frames.
func (n *Node) attachFileBulk(framed *FramedConn, attach wire.BulkAttachBody) {
	// Find the transfer across all active links via a global registry.
	n.bulkMu.Lock()
	rcv := n.pendingBulk[attach.BulkToken]
	n.bulkMu.Unlock()
	if rcv == nil {
		framed.Close()
		return
	}
	rcv.drainBulk(framed, attach.FileID)
}

func (r *fileReceiver) registerBulk() {}

func (r *fileReceiver) drainBulk(framed *FramedConn, fileID string) {
	defer framed.Close()
	for {
		frame, ok, err := framed.NextFrame()
		if err != nil || !ok {
			return
		}
		if frame.Kind == wire.KindFileChunk {
			if done := r.handleChunk(*frame.Chunk); done {
				return
			}
		}
	}
}

// handleChunk writes one chunk; returns true when the transfer finished.
func (r *fileReceiver) handleChunk(chunk wire.ChunkFrame) bool {
	r.mu.Lock()
	fileID, ok := r.byUUID[chunk.FileID]
	if !ok {
		r.mu.Unlock()
		return false
	}
	t := r.transfers[fileID]
	r.mu.Unlock()
	if t == nil {
		return false
	}
	if chunk.Seq != t.received {
		r.fail(fileID, "out-of-order chunk")
		return true
	}
	if _, err := t.file.Write(chunk.Data); err != nil {
		r.fail(fileID, "write failed")
		return true
	}
	t.hasher.Write(chunk.Data)
	t.received++

	isFinal := chunk.IsLast || t.received == t.offer.ChunkCount
	if t.received%16 == 0 && !isFinal {
		_ = r.link.framed.Send(wire.Message{Type: wire.TypeFileAck, Body: wire.FileAckBody{
			FileID: fileID, Status: "progress", AckedThrough: t.received}})
	}
	if isFinal {
		r.finalize(fileID)
		return true
	}
	return false
}

func (r *fileReceiver) finalize(fileID string) {
	r.mu.Lock()
	t := r.transfers[fileID]
	delete(r.transfers, fileID)
	delete(r.byUUID, t.uuid)
	r.mu.Unlock()
	t.file.Close()

	digest := hex.EncodeToString(t.hasher.(interface{ Sum([]byte) []byte }).Sum(nil))
	partial := filepath.Join(r.node.ReceiveDir, t.offer.SHA256+".part")
	if digest != t.offer.SHA256 {
		os.Remove(partial)
		_ = r.link.framed.Send(wire.Message{Type: wire.TypeFileAck, Body: wire.FileAckBody{
			FileID: fileID, Status: "hash_mismatch", AckedThrough: t.received, Message: "sha256 mismatch"}})
		return
	}
	dest := uniqueDest(r.node.ReceiveDir, t.offer.Name)
	os.Rename(partial, dest)
	_ = r.link.framed.Send(wire.Message{Type: wire.TypeFileAck, Body: wire.FileAckBody{
		FileID: fileID, Status: "complete", AckedThrough: t.received}})
	if r.node.handlers.OnFileReceived != nil {
		r.node.handlers.OnFileReceived(dest, t.offer)
	}
}

func (r *fileReceiver) fail(fileID, reason string) {
	r.mu.Lock()
	t := r.transfers[fileID]
	delete(r.transfers, fileID)
	if t != nil {
		delete(r.byUUID, t.uuid)
		t.file.Close()
	}
	r.mu.Unlock()
	_ = r.link.framed.Send(wire.Message{Type: wire.TypeFileAck, Body: wire.FileAckBody{
		FileID: fileID, Status: "error", AckedThrough: 0, Message: reason}})
}

// ---- Sender ----

type outgoingTransfer struct {
	offer wire.FileOfferBody
	path  string
	uuid  [16]byte
	done  chan error
}

type fileSender struct {
	node      *Node
	link      *Link
	mu        sync.Mutex
	transfers map[string]*outgoingTransfer
}

func newFileSender(n *Node, l *Link) *fileSender {
	return &fileSender{node: n, link: l, transfers: map[string]*outgoingTransfer{}}
}

// SendFile offers a file and blocks until the transfer completes or fails.
func (l *Link) SendFile(path string) error {
	return l.sender.send(path)
}

func (s *fileSender) send(path string) error {
	sum, size, err := sha256File(path)
	if err != nil {
		return err
	}
	chunkSize := wire.DefaultChunkSize
	chunkCount := (size + uint64(chunkSize) - 1) / uint64(chunkSize)
	if size == 0 {
		chunkCount = 1
	}
	fileID := newSessionID()
	uuid, _ := parseUUID(fileID)
	offer := wire.FileOfferBody{
		FileID: fileID, Name: filepath.Base(path), Size: size,
		Mime: "application/octet-stream", SHA256: sum,
		ChunkSize: chunkSize, ChunkCount: chunkCount,
	}
	t := &outgoingTransfer{offer: offer, path: path, uuid: uuid, done: make(chan error, 1)}
	s.mu.Lock()
	s.transfers[fileID] = t
	s.mu.Unlock()
	if err := s.link.framed.Send(wire.Message{Type: wire.TypeFileOffer, Body: offer}); err != nil {
		return err
	}
	return <-t.done
}

func (s *fileSender) handle(msg wire.Message) {
	switch msg.Type {
	case wire.TypeFileAccept:
		body := msg.Body.(wire.FileAcceptBody)
		go s.pump(body.FileID, body.ResumeFromChunk, body.BulkToken)
	case wire.TypeFileReject:
		body := msg.Body.(wire.FileRejectBody)
		s.finish(body.FileID, errors.New("rejected: "+body.Reason))
	case wire.TypeFileAck:
		body := msg.Body.(wire.FileAckBody)
		switch body.Status {
		case "complete":
			s.finish(body.FileID, nil)
		case "hash_mismatch", "error":
			s.finish(body.FileID, errors.New("transfer failed: "+body.Status))
		}
	}
}

// pump streams chunks. For the daemon we send over the control connection
// (a dedicated bulk lane is an optimization; the Swift side opens one for its
// sends, and accepts chunks on either lane).
func (s *fileSender) pump(fileID string, resumeFrom uint64, bulkToken string) {
	s.mu.Lock()
	t := s.transfers[fileID]
	s.mu.Unlock()
	if t == nil {
		return
	}
	// Open a dedicated bulk connection to the peer for parity with Swift.
	host := s.link.framed.RemoteHost()
	var bulk *FramedConn
	if host != "" && s.link.remote.ListenPort != nil {
		if conn, err := s.node.Backend.Dial(host, *s.link.remote.ListenPort, transport.PinPolicy{
			Pinned: map[string]bool{hex.EncodeToString(s.link.peer.TLSPubkeySHA256): true},
		}); err == nil {
			bulk = NewFramedConn(conn)
			bulk.SetSessionID(newSessionID())
			if bulk.Send(wire.Message{Type: wire.TypeBulkAttach, Body: wire.BulkAttachBody{
				FileID: fileID, BulkToken: bulkToken}}) != nil {
				bulk.Close()
				bulk = nil
			}
		}
	}
	sendChunk := s.link.framed.SendChunk
	if bulk != nil {
		defer bulk.Close()
		sendChunk = bulk.SendChunk
	}

	f, err := os.Open(t.path)
	if err != nil {
		s.finish(fileID, err)
		return
	}
	defer f.Close()
	f.Seek(int64(resumeFrom)*int64(t.offer.ChunkSize), io.SeekStart)

	buf := make([]byte, t.offer.ChunkSize)
	seq := resumeFrom
	for seq < t.offer.ChunkCount {
		n, rerr := io.ReadFull(f, buf)
		if rerr == io.ErrUnexpectedEOF || rerr == io.EOF {
			rerr = nil
		}
		isLast := seq == t.offer.ChunkCount-1
		if err := sendChunk(wire.ChunkFrame{FileID: t.uuid, Seq: seq, IsLast: isLast, Data: buf[:n]}); err != nil {
			s.finish(fileID, err)
			return
		}
		seq++
	}
	// Completion is signaled by the receiver's FILE_ACK complete.
}

func (s *fileSender) finish(fileID string, err error) {
	s.mu.Lock()
	t := s.transfers[fileID]
	delete(s.transfers, fileID)
	s.mu.Unlock()
	if t != nil {
		select {
		case t.done <- err:
		default:
		}
	}
}

// ---- helpers ----

func sha256File(path string) (string, uint64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	size, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), uint64(size), nil
}

func parseUUID(s string) ([16]byte, error) {
	var out [16]byte
	clean := ""
	for _, c := range s {
		if c != '-' {
			clean += string(c)
		}
	}
	b, err := hex.DecodeString(clean)
	if err != nil || len(b) != 16 {
		return out, errors.New("bad uuid")
	}
	copy(out[:], b)
	return out, nil
}

func uniqueDest(dir, name string) string {
	base := filepath.Join(dir, name)
	if _, err := os.Stat(base); os.IsNotExist(err) {
		return base
	}
	ext := filepath.Ext(name)
	stem := name[:len(name)-len(ext)]
	for i := 2; i < 9999; i++ {
		cand := filepath.Join(dir, stem+" ("+itoa(i)+")"+ext)
		if _, err := os.Stat(cand); os.IsNotExist(err) {
			return cand
		}
	}
	return base
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}
