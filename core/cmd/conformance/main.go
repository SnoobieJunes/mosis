// Command conformance runs the Go implementation against the shared golden
// vectors in proto/vectors and reports pass/fail. A release requires this AND
// the Swift conformance suite green (spec §9 Phase 4 step 2 invariant).
//
// Usage: conformance <path-to-proto/vectors>
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/auston/conduit-core/identity"
	"github.com/auston/conduit-core/wire"
)

type result struct {
	name string
	ok   bool
	msg  string
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: conformance <proto/vectors dir>")
		os.Exit(2)
	}
	dir := os.Args[1]
	var results []result
	results = append(results, checkMessages(filepath.Join(dir, "messages.json"))...)
	results = append(results, checkChunkFrames(filepath.Join(dir, "chunk_frames.json"))...)
	results = append(results, checkScreenFrames(filepath.Join(dir, "screen_frames.json"))...)
	results = append(results, checkPairing(filepath.Join(dir, "pairing.json"))...)

	failed := 0
	for _, r := range results {
		if r.ok {
			fmt.Printf("  ok   %s\n", r.name)
		} else {
			failed++
			fmt.Printf("  FAIL %s: %s\n", r.name, r.msg)
		}
	}
	fmt.Printf("\n%d vectors, %d failed\n", len(results), failed)
	if failed > 0 {
		os.Exit(1)
	}
	fmt.Println("Go conformance: PASS")
}

func loadJSON(path string) (map[string]interface{}, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m map[string]interface{}
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return m, nil
}

// checkMessages: decode each frame_hex → typed message → re-encode canonically
// → must equal canonical_json AND re-frame to the same bytes.
func checkMessages(path string) []result {
	file, err := loadJSON(path)
	if err != nil {
		return []result{{name: "messages.json", msg: err.Error()}}
	}
	vectors, _ := file["vectors"].([]interface{})
	var out []result
	for _, v := range vectors {
		vec := v.(map[string]interface{})
		name := "message:" + vec["name"].(string)
		frameHex := vec["frame_hex"].(string)
		wantCanonical := vec["canonical_json"].(string)

		frameBytes, err := hex.DecodeString(frameHex)
		if err != nil {
			out = append(out, result{name: name, msg: "bad hex"})
			continue
		}
		var reader wire.FrameReader
		frames, err := reader.Append(frameBytes)
		if err != nil || len(frames) != 1 || frames[0].Kind != wire.KindControl {
			out = append(out, result{name: name, msg: "did not parse to one control frame"})
			continue
		}
		payload := frames[0].Control

		// Typed round-trip: decode → re-encode via the typed codec.
		env, msg, err := wire.DecodeMessage(payload)
		if err != nil {
			out = append(out, result{name: name, msg: "decode: " + err.Error()})
			continue
		}
		if msg.Body == nil {
			out = append(out, result{name: name, msg: "unknown type " + env.Type})
			continue
		}
		reencoded, err := wire.EncodeMessage(env.SessionID, env.Seq, msg)
		if err != nil {
			out = append(out, result{name: name, msg: "encode: " + err.Error()})
			continue
		}
		if string(reencoded) != wantCanonical {
			out = append(out, result{name: name, msg: fmt.Sprintf(
				"canonical mismatch\n   want: %s\n   got:  %s", wantCanonical, string(reencoded))})
			continue
		}
		// Reframing the canonical bytes must reproduce the golden frame.
		if hex.EncodeToString(wire.EncodeControl(reencoded)) != frameHex {
			out = append(out, result{name: name, msg: "reframed bytes differ"})
			continue
		}
		out = append(out, result{name: name, ok: true})
	}
	return out
}

func checkChunkFrames(path string) []result {
	file, err := loadJSON(path)
	if err != nil {
		return []result{{name: "chunk_frames.json", msg: err.Error()}}
	}
	vectors, _ := file["vectors"].([]interface{})
	var out []result
	for _, v := range vectors {
		vec := v.(map[string]interface{})
		name := "chunk:" + vec["name"].(string)
		frameBytes, _ := hex.DecodeString(vec["frame_hex"].(string))
		var reader wire.FrameReader
		frames, err := reader.Append(frameBytes)
		if err != nil || len(frames) != 1 || frames[0].Chunk == nil {
			out = append(out, result{name: name, msg: "did not parse to one chunk frame"})
			continue
		}
		c := frames[0].Chunk
		if hex.EncodeToString(wire.EncodeChunk(*c)) != vec["frame_hex"].(string) {
			out = append(out, result{name: name, msg: "re-encode differs"})
			continue
		}
		out = append(out, result{name: name, ok: true})
	}
	return out
}

func checkScreenFrames(path string) []result {
	file, err := loadJSON(path)
	if err != nil {
		return []result{{name: "screen_frames.json", msg: err.Error()}}
	}
	vectors, _ := file["vectors"].([]interface{})
	var out []result
	for _, v := range vectors {
		vec := v.(map[string]interface{})
		name := "screen:" + vec["name"].(string)
		frameBytes, _ := hex.DecodeString(vec["frame_hex"].(string))
		var reader wire.FrameReader
		frames, err := reader.Append(frameBytes)
		if err != nil || len(frames) != 1 || frames[0].Screen == nil {
			out = append(out, result{name: name, msg: "did not parse to one screen frame"})
			continue
		}
		s := frames[0].Screen
		if hex.EncodeToString(wire.EncodeScreen(*s)) != vec["frame_hex"].(string) {
			out = append(out, result{name: name, msg: "re-encode differs"})
			continue
		}
		// Inner packing must round-trip to the vector's parameter sets.
		frame, err := wire.UnpackScreenFrame(s.Data, s.IsKeyframe)
		if err != nil {
			out = append(out, result{name: name, msg: "unpack: " + err.Error()})
			continue
		}
		wantSets, _ := vec["parameter_sets_hex"].([]interface{})
		if len(frame.ParameterSets) != len(wantSets) {
			out = append(out, result{name: name, msg: "parameter set count mismatch"})
			continue
		}
		mismatch := false
		for i, ws := range wantSets {
			if hex.EncodeToString(frame.ParameterSets[i]) != ws.(string) {
				mismatch = true
			}
		}
		if mismatch {
			out = append(out, result{name: name, msg: "parameter set bytes differ"})
			continue
		}
		out = append(out, result{name: name, ok: true})
	}
	return out
}

func checkPairing(path string) []result {
	file, err := loadJSON(path)
	if err != nil {
		return []result{{name: "pairing.json", msg: err.Error()}}
	}
	var out []result

	// Wordlist must be frozen: its SHA-256 matches the pinned value.
	wantHash, _ := file["wordlist_sha256"].(string)
	joined := strings.Join(identity.Wordlist, "\n")
	sum := sha256.Sum256([]byte(joined))
	if hex.EncodeToString(sum[:]) == wantHash {
		out = append(out, result{name: "pairing:wordlist_frozen", ok: true})
	} else {
		out = append(out, result{name: "pairing:wordlist_frozen", msg: "wordlist hash drift"})
	}

	vectors, _ := file["vectors"].([]interface{})
	for _, v := range vectors {
		vec := v.(map[string]interface{})
		name := "pairing:" + vec["name"].(string)
		switch vec["name"] {
		case "pairing_basic":
			pubA, _ := hex.DecodeString(vec["pub_a_hex"].(string))
			pubB, _ := hex.DecodeString(vec["pub_b_hex"].(string))
			code := identity.VerificationCode(pubA, pubB)
			wA, wB := identity.VerificationWords(pubA, pubB)
			if code == vec["code"].(string) && wA == vec["word_a"].(string) && wB == vec["word_b"].(string) {
				out = append(out, result{name: name, ok: true})
			} else {
				out = append(out, result{name: name, msg: fmt.Sprintf("code/words mismatch (got %s %s/%s)", code, wA, wB)})
			}
		case "identity_derivation":
			pub, _ := hex.DecodeString(vec["ed25519_pub_hex"].(string))
			if identity.DeviceID(pub) == vec["device_id"].(string) {
				out = append(out, result{name: name, ok: true})
			} else {
				out = append(out, result{name: name, msg: "device id mismatch"})
			}
		case "tls_binding":
			pub, _ := hex.DecodeString(vec["ed25519_pub_hex"].(string))
			hash, _ := hex.DecodeString(vec["tls_key_hash_hex"].(string))
			sig, _ := hex.DecodeString(vec["signature_hex"].(string))
			if identity.VerifyTLSBinding(sig, hash, pub) {
				out = append(out, result{name: name, ok: true})
			} else {
				out = append(out, result{name: name, msg: "binding signature failed to verify"})
			}
		}
	}
	return out
}
