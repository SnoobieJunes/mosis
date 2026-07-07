package wire

import (
	"encoding/json"
	"fmt"
)

// Protocol constants shared with the Swift implementation (docs/protocol.md).
const (
	Version     = "0.2"
	ServiceType = "_cndt-app._tcp"

	// Capability identifiers (feature-flag strings; peers use the intersection).
	CapFile         = "file"
	CapClipboard    = "clipboard"
	CapInputInject  = "input-inject"
	CapMediaTarget  = "media-target"
	CapScreenSource = "screen-source"
	CapScreenView   = "screen-view"
	CapNotifySource = "notify-source"
	CapNotifyShow   = "notify-show"

	DefaultChunkSize uint32 = 512 * 1024
)

// MessageType is the envelope `type` discriminator.
type MessageType string

const (
	TypeHello         MessageType = "HELLO"
	TypeHelloAck      MessageType = "HELLO_ACK"
	TypePing          MessageType = "PING"
	TypePong          MessageType = "PONG"
	TypeClipboardPush MessageType = "CLIPBOARD_PUSH"
	TypeFileOffer     MessageType = "FILE_OFFER"
	TypeFileAccept    MessageType = "FILE_ACCEPT"
	TypeFileReject    MessageType = "FILE_REJECT"
	TypeFileAck       MessageType = "FILE_ACK"
	TypePairRequest   MessageType = "PAIR_REQUEST"
	TypePairResponse  MessageType = "PAIR_RESPONSE"
	TypePairConfirm   MessageType = "PAIR_CONFIRM"
	TypePairReject    MessageType = "PAIR_REJECT"
	TypeBulkAttach    MessageType = "BULK_ATTACH"
	TypeInputRequest  MessageType = "INPUT_REQUEST"
	TypeInputStatus   MessageType = "INPUT_STATUS"
	TypeInputEvent    MessageType = "INPUT_EVENT"
	TypeInputAttach   MessageType = "INPUT_ATTACH"
	TypeMediaControl  MessageType = "MEDIA_CONTROL"
	TypeScreenRequest MessageType = "SCREEN_REQUEST"
	TypeScreenOffer   MessageType = "SCREEN_OFFER"
	TypeScreenReject  MessageType = "SCREEN_REJECT"
	TypeScreenAttach  MessageType = "SCREEN_ATTACH"
	TypeScreenAck     MessageType = "SCREEN_ACK"
	TypeScreenEnd     MessageType = "SCREEN_END"
	// Phase 4-5: notifications.
	TypeNotification MessageType = "NOTIFICATION"
)

// Envelope carries every control message. Frozen shape (spec §6):
// version, type, session_id, seq, payload.
type Envelope struct {
	Payload   json.RawMessage `json:"payload"`
	Seq       uint64          `json:"seq"`
	SessionID string          `json:"session_id"`
	Type      string          `json:"type"`
	Version   string          `json:"version"`
}

// --- Message bodies. Fields are declared in the order that keeps hand-written
// struct marshaling readable; Canonical() re-sorts keys, so declaration order
// does not affect the wire bytes. ---

type DeviceClass string

type HelloBody struct {
	Identity      string   `json:"identity"`
	Name          string   `json:"name"`
	DeviceClass   string   `json:"device_class"`
	AppVersion    string   `json:"app_version"`
	Pubkey        []byte   `json:"pubkey"`
	Capabilities  []string `json:"capabilities"`
	PlatformWalls []string `json:"platform_walls"`
	ListenPort    *uint16  `json:"listen_port,omitempty"`
}

type PingBody struct {
	Nonce string `json:"nonce"`
	T     uint64 `json:"t"`
}

type ClipboardPushBody struct {
	Mime string `json:"mime"`
	Data []byte `json:"data"`
}

type FileOfferBody struct {
	FileID     string `json:"file_id"`
	Name       string `json:"name"`
	Size       uint64 `json:"size"`
	Mime       string `json:"mime"`
	SHA256     string `json:"sha256"`
	ChunkSize  uint32 `json:"chunk_size"`
	ChunkCount uint64 `json:"chunk_count"`
}

type FileAcceptBody struct {
	FileID          string `json:"file_id"`
	ResumeFromChunk uint64 `json:"resume_from_chunk"`
	BulkToken       string `json:"bulk_token"`
}

type FileRejectBody struct {
	FileID string `json:"file_id"`
	Reason string `json:"reason"`
}

type FileAckBody struct {
	FileID       string `json:"file_id"`
	Status       string `json:"status"`
	AckedThrough uint64 `json:"acked_through"`
	Message      string `json:"message,omitempty"`
}

type PairBody struct {
	Identity        string `json:"identity"`
	Name            string `json:"name"`
	DeviceClass     string `json:"device_class"`
	Pubkey          []byte `json:"pubkey"`
	TLSPubkeySHA256 string `json:"tls_pubkey_sha256"`
	BindingSig      []byte `json:"binding_sig"`
}

type PairRejectBody struct {
	Reason string `json:"reason"`
}

type BulkAttachBody struct {
	FileID    string `json:"file_id"`
	BulkToken string `json:"bulk_token"`
}

type NotificationBody struct {
	AppName string   `json:"app_name"`
	Title   string   `json:"title"`
	Body    string   `json:"body"`
	ID      string   `json:"id"`
	Actions []string `json:"actions,omitempty"`
}

// --- Phase 2: remote input + media. Optional fields are pointers so a nil
// (absent) is distinct from a present zero, matching Swift's Optional encoding. ---

type InputEventBody struct {
	Kind       string   `json:"kind"`
	Dx         *float64 `json:"dx,omitempty"`
	Dy         *float64 `json:"dy,omitempty"`
	Button     *string  `json:"button,omitempty"`
	Action     *string  `json:"action,omitempty"`
	ClickCount *int     `json:"click_count,omitempty"`
	Key        *string  `json:"key,omitempty"`
	Text       *string  `json:"text,omitempty"`
	Modifiers  []string `json:"modifiers,omitempty"`
}

type InputStatusBody struct {
	Active        bool    `json:"active"`
	Reason        *string `json:"reason,omitempty"`
	UDPPort       *uint16 `json:"udp_port,omitempty"`
	DatagramToken *string `json:"datagram_token,omitempty"`
	SecureInput   *bool   `json:"secure_input,omitempty"`
}

type InputAttachBody struct {
	Token string `json:"token"`
}

type MediaControlBody struct {
	Action string   `json:"action"`
	Value  *float64 `json:"value,omitempty"`
}

// --- Phase 3: screen sharing. ---

type ScreenRequestBody struct {
	MaxWidth  *int     `json:"max_width,omitempty"`
	MaxHeight *int     `json:"max_height,omitempty"`
	MaxFps    *int     `json:"max_fps,omitempty"`
	Codecs    []string `json:"codecs"`
}

type ScreenOfferBody struct {
	ScreenSessionID string `json:"screen_session_id"`
	WireSessionID   uint16 `json:"wire_session_id"`
	Codec           string `json:"codec"`
	Width           int    `json:"width"`
	Height          int    `json:"height"`
	Fps             int    `json:"fps"`
	CaptureKind     string `json:"capture_kind"`
	SourceName      string `json:"source_name"`
	BulkToken       string `json:"bulk_token"`
}

type ScreenRejectBody struct {
	Reason string `json:"reason"`
}

type ScreenAttachBody struct {
	ScreenSessionID string `json:"screen_session_id"`
	BulkToken       string `json:"bulk_token"`
}

type ScreenAckBody struct {
	ScreenSessionID string `json:"screen_session_id"`
	AckedSeq        uint32 `json:"acked_seq"`
	RequestKeyframe bool   `json:"request_keyframe"`
}

type ScreenEndBody struct {
	ScreenSessionID string  `json:"screen_session_id"`
	Reason          *string `json:"reason,omitempty"`
}

// Message pairs a decoded body with its type.
type Message struct {
	Type MessageType
	Body interface{}
}

// EncodeMessage produces the canonical JSON of a full envelope for the message.
func EncodeMessage(sessionID string, seq uint64, m Message) ([]byte, error) {
	payload, err := Canonical(m.Body)
	if err != nil {
		return nil, err
	}
	env := Envelope{
		Payload:   json.RawMessage(payload),
		Seq:       seq,
		SessionID: sessionID,
		Type:      string(m.Type),
		Version:   Version,
	}
	return Canonical(env)
}

// DecodeEnvelope splits the header from the payload without interpreting the body.
func DecodeEnvelope(data []byte) (Envelope, error) {
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		return Envelope{}, fmt.Errorf("not JSON: %w", err)
	}
	return env, nil
}

// DecodeMessage decodes into a typed body. Unknown types return a Message with
// a nil Body and the raw type, mirroring the Swift .unknown case (never fatal).
func DecodeMessage(data []byte) (Envelope, Message, error) {
	env, err := DecodeEnvelope(data)
	if err != nil {
		return Envelope{}, Message{}, err
	}
	body, err := decodeBody(MessageType(env.Type), env.Payload)
	if err != nil {
		return env, Message{}, err
	}
	return env, Message{Type: MessageType(env.Type), Body: body}, nil
}

func decodeBody(t MessageType, payload []byte) (interface{}, error) {
	switch t {
	case TypeHello, TypeHelloAck:
		var b HelloBody
		return unmarshalBody(payload, &b)
	case TypePing, TypePong:
		var b PingBody
		return unmarshalBody(payload, &b)
	case TypeClipboardPush:
		var b ClipboardPushBody
		return unmarshalBody(payload, &b)
	case TypeFileOffer:
		var b FileOfferBody
		return unmarshalBody(payload, &b)
	case TypeFileAccept:
		var b FileAcceptBody
		return unmarshalBody(payload, &b)
	case TypeFileReject:
		var b FileRejectBody
		return unmarshalBody(payload, &b)
	case TypeFileAck:
		var b FileAckBody
		return unmarshalBody(payload, &b)
	case TypePairRequest, TypePairResponse:
		var b PairBody
		return unmarshalBody(payload, &b)
	case TypePairConfirm:
		return struct{}{}, nil
	case TypePairReject:
		var b PairRejectBody
		return unmarshalBody(payload, &b)
	case TypeBulkAttach:
		var b BulkAttachBody
		return unmarshalBody(payload, &b)
	case TypeInputRequest:
		return struct{}{}, nil
	case TypeInputStatus:
		var b InputStatusBody
		return unmarshalBody(payload, &b)
	case TypeInputEvent:
		var b InputEventBody
		return unmarshalBody(payload, &b)
	case TypeInputAttach:
		var b InputAttachBody
		return unmarshalBody(payload, &b)
	case TypeMediaControl:
		var b MediaControlBody
		return unmarshalBody(payload, &b)
	case TypeScreenRequest:
		var b ScreenRequestBody
		return unmarshalBody(payload, &b)
	case TypeScreenOffer:
		var b ScreenOfferBody
		return unmarshalBody(payload, &b)
	case TypeScreenReject:
		var b ScreenRejectBody
		return unmarshalBody(payload, &b)
	case TypeScreenAttach:
		var b ScreenAttachBody
		return unmarshalBody(payload, &b)
	case TypeScreenAck:
		var b ScreenAckBody
		return unmarshalBody(payload, &b)
	case TypeScreenEnd:
		var b ScreenEndBody
		return unmarshalBody(payload, &b)
	case TypeNotification:
		var b NotificationBody
		return unmarshalBody(payload, &b)
	default:
		// Unknown type: inert, not an error (spec §6 invariant).
		return nil, nil
	}
}

func unmarshalBody[T any](payload []byte, b *T) (interface{}, error) {
	if err := json.Unmarshal(payload, b); err != nil {
		return nil, err
	}
	return *b, nil
}
