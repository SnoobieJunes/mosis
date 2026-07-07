// Package wire is the Go implementation of the Conduit wire protocol
// (docs/protocol.md). It exists to prove the protocol is implementable outside
// Swift and to interoperate with the Apple apps byte-for-byte; the golden
// vectors in proto/vectors are the shared conformance suite.
package wire

import (
	"bytes"
	"encoding/json"
)

// Canonical encodes v as Conduit's canonical JSON: sorted keys at every level,
// no inserted whitespace, forward slashes and non-ASCII left unescaped,
// integers left as integers, []byte as base64. This must match Swift's
// JSONEncoder([.sortedKeys, .withoutEscapingSlashes]) byte-for-byte.
//
// Method: marshal normally, then round-trip through a generic value so the
// standard encoder sorts every map's keys, with HTML escaping disabled and the
// trailing newline trimmed. json.Number preserves integer formatting.
func Canonical(v interface{}) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return canonicalizeBytes(raw)
}

func canonicalizeBytes(raw []byte) ([]byte, error) {
	var generic interface{}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&generic); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(generic); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}
