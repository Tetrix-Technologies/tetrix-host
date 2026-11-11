// Package wire defines the bytes that cross the network. It has three parts:
// the relay frames between a host and a relay, the first byte of a client's
// opening message, and the tunnel frames that travel inside the sealed
// channel. docs/reference/protocol.md is the specification. This file is its
// Go form, and Sources/TetrixHostKit/Wire.swift is its Swift form.
package wire

import (
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"
)

// Subprotocol is the WebSocket subprotocol of both relay endpoints.
const Subprotocol = "tetrix-host.v1"

// MaxNoiseMessage is the largest message the Noise framework allows.
const MaxNoiseMessage = 65535

// TagSize is the size of the AEAD tag on every sealed message.
const TagSize = 16

// MaxFramePayload is the largest tunnel-frame payload that fits one sealed
// message: 65535 bytes, less the tag, less the 7-byte frame header.
const MaxFramePayload = MaxNoiseMessage - TagSize - TunnelHeaderSize

// PadBlock is the step a frame is padded to before it is sealed. A model
// streams its answer a token at a time, and without padding the size of
// each sealed message would give away the length of each token to anyone
// who watches the connection, the relay included. With it, every message
// that carries a token has the same size.
const PadBlock = 512

// BodyChunk is the size the host and the SDK cut a body into.
const BodyChunk = 32 * 1024

// MaxClientMessage bounds one message on a client's connection to a relay.
// A client sends bare Noise messages, so the bound is Noise's own.
const MaxClientMessage = MaxNoiseMessage

// MaxHostMessage bounds one message on a host's connection to a relay: one
// client message plus the relay header. The relay must never forward a
// message a host would refuse to read, or one client could cut a host off.
const MaxHostMessage = MaxClientMessage + RelayHeaderSize

// Domain-separation strings. Each one names a single use of a key or hash.
const (
	// RegisterContext prefixes the challenge a host signs for a relay.
	RegisterContext = "tetrix-host/relay-register/1\x00"
	// HostIDContext prefixes the signing key when the host ID is derived.
	HostIDContext = "tetrix-host/host-id/1\x00"
	// DeviceIDContext prefixes a device's static key when its ID is derived.
	DeviceIDContext = "tetrix-host/device-id/1\x00"
	// PairHintContext prefixes a pairing secret when its hint is derived.
	PairHintContext = "tetrix-host/pair-hint/1\x00"
	// PairPrologue and SessionPrologue start the two Noise prologues. The
	// host ID follows each.
	PairPrologue    = "tetrix-host/pair/1\x00"
	SessionPrologue = "tetrix-host/session/1\x00"
)

// Relay frames travel between a host and a relay. A client's leg carries
// bare payloads, so the relay adds and removes this header.
const (
	RelayOpen  byte = 0x01 // relay to host: a client connected
	RelayData  byte = 0x02 // either way: one client message
	RelayClose byte = 0x03 // either way: the client leg ended
)

// RelayHeaderSize is one type byte and an 8-byte session ID.
const RelayHeaderSize = 9

// AppendRelayFrame appends a relay frame to dst.
func AppendRelayFrame(dst []byte, kind byte, sid uint64, payload []byte) []byte {
	dst = append(dst, kind)
	dst = binary.BigEndian.AppendUint64(dst, sid)
	return append(dst, payload...)
}

// ParseRelayFrame splits a relay frame. The payload aliases b.
func ParseRelayFrame(b []byte) (kind byte, sid uint64, payload []byte, err error) {
	if len(b) < RelayHeaderSize {
		return 0, 0, nil, errors.New("wire: short relay frame")
	}
	return b[0], binary.BigEndian.Uint64(b[1:9]), b[9:], nil
}

// The first byte of a client's opening message says which handshake follows.
const (
	// HelloPair is followed by a 4-byte ticket hint and Noise message 1 of
	// Noise_XXpsk0_25519_ChaChaPoly_SHA256.
	HelloPair byte = 0x01
	// HelloSession is followed by Noise message 1 of
	// Noise_IK_25519_ChaChaPoly_SHA256.
	HelloSession byte = 0x02
)

// HintSize is the length of a ticket hint.
const HintSize = 4

// Tunnel frames travel inside the sealed channel, one frame per message.
const (
	FrameRequest  byte = 0x01 // client: JSON RequestHead, opens a stream
	FrameBody     byte = 0x02 // either: body bytes
	FrameEnd      byte = 0x03 // either: this side's body is complete
	FrameResponse byte = 0x04 // host: JSON ResponseHead
	FrameReset    byte = 0x05 // either: abandon the stream, optional JSON Reset
	FramePing     byte = 0x06 // either: payload is echoed in a pong
	FramePong     byte = 0x07
	FramePaired   byte = 0x10 // host: JSON PairResult, ends a pairing
)

// TunnelHeaderSize is one type byte, a 4-byte stream ID, and a 2-byte
// payload length.
const TunnelHeaderSize = 7

// AppendTunnelFrame appends a tunnel frame to dst: the header, the payload,
// and zero bytes up to the next multiple of PadBlock. The payload must not
// be longer than MaxFramePayload.
func AppendTunnelFrame(dst []byte, kind byte, stream uint32, payload []byte) []byte {
	start := len(dst)
	dst = append(dst, kind)
	dst = binary.BigEndian.AppendUint32(dst, stream)
	dst = binary.BigEndian.AppendUint16(dst, uint16(len(payload)))
	dst = append(dst, payload...)
	return append(dst, make([]byte, PaddedSize(len(dst)-start)-(len(dst)-start))...)
}

// PaddedSize is the size a frame of n bytes has after padding.
func PaddedSize(n int) int {
	padded := (n + PadBlock - 1) / PadBlock * PadBlock
	return min(padded, MaxNoiseMessage-TagSize)
}

// ParseTunnelFrame splits a tunnel frame and drops its padding. The payload
// aliases b.
func ParseTunnelFrame(b []byte) (kind byte, stream uint32, payload []byte, err error) {
	if len(b) < TunnelHeaderSize {
		return 0, 0, nil, errors.New("wire: short tunnel frame")
	}
	n := int(binary.BigEndian.Uint16(b[5:7]))
	if TunnelHeaderSize+n > len(b) {
		return 0, 0, nil, errors.New("wire: tunnel frame is shorter than its length field")
	}
	return b[0], binary.BigEndian.Uint32(b[1:5]), b[7 : 7+n], nil
}

// RequestHead opens a stream. Header names are lower case.
type RequestHead struct {
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Headers map[string]string `json:"headers,omitempty"`
}

// ResponseHead answers a RequestHead.
type ResponseHead struct {
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers,omitempty"`
}

// Reset says why a stream ended early.
type Reset struct {
	Code    string `json:"code"`
	Message string `json:"message,omitempty"`
}

// HostHello is the payload of the host's handshake message. A client reads
// it to learn what the host can do before it sends a request.
type HostHello struct {
	HostID  string `json:"hostId"`
	Name    string `json:"name"`
	Version string `json:"version"`
	// Refused is set when the host will not serve this client. It travels
	// inside the handshake, so the client knows the host itself said it. A
	// close code alone could come from the relay.
	Refused string `json:"refused,omitempty"`
}

// RefusedUnknownDevice is the Refused value for a key that belongs to no
// paired device.
const RefusedUnknownDevice = "unknown_device"

// ClientHello is the payload a client sends in its handshake.
type ClientHello struct {
	Name       string `json:"name,omitempty"`
	App        string `json:"app,omitempty"`
	AppVersion string `json:"appVersion,omitempty"`
	Platform   string `json:"platform,omitempty"`
	SDK        string `json:"sdk,omitempty"`
}

// PairResult ends a pairing. The client stores DeviceID and the host's
// static key, which it learned in the handshake.
type PairResult struct {
	OK       bool   `json:"ok"`
	DeviceID string `json:"deviceId,omitempty"`
	HostID   string `json:"hostId,omitempty"`
	HostName string `json:"hostName,omitempty"`
	Error    string `json:"error,omitempty"`
}

// WebSocket close codes in the application range. The relay sends them, and
// a host can ask the relay to send one to a client.
const (
	CloseBadRequest      = 4400
	CloseUnauthorized    = 4401
	CloseUnknownDevice   = 4403
	CloseHostOffline     = 4404
	CloseSlowConsumer    = 4408
	CloseReplaced        = 4409
	ClosePairingFailed   = 4410
	CloseTooManySessions = 4429
	CloseHostError       = 4500
)

// AppendClose builds the payload of a RelayClose frame from a host: a
// 2-byte close code and a short reason. The relay can read both, so a
// reason names a category and never carries detail.
func AppendClose(dst []byte, code int, reason string) []byte {
	dst = binary.BigEndian.AppendUint16(dst, uint16(code))
	return append(dst, reason...)
}

// ParseClose reads the payload AppendClose builds. An empty payload is a
// normal closure.
func ParseClose(b []byte) (code int, reason string) {
	if len(b) < 2 {
		return 1000, ""
	}
	code = int(binary.BigEndian.Uint16(b[:2]))
	if code < 4000 || code > 4999 {
		code = 1000
	}
	reason = string(b[2:])
	if len(reason) > 64 {
		reason = reason[:64]
	}
	return code, reason
}

// Control messages are JSON text frames a host and a relay exchange before
// the first binary frame.
type Control struct {
	Type      string `json:"type"` // challenge, register, registered, error
	Nonce     string `json:"nonce,omitempty"`
	HostID    string `json:"hostId,omitempty"`
	PublicKey string `json:"publicKey,omitempty"`
	Signature string `json:"signature,omitempty"`
	Code      string `json:"code,omitempty"`
	Message   string `json:"message,omitempty"`
}

// RegisterMessage is the byte string a host signs to claim its ID.
func RegisterMessage(nonce []byte) []byte {
	return append([]byte(RegisterContext), nonce...)
}

// CleanText makes text from another party safe to store, log, and print:
// it trims it, drops control characters, and cuts it to max bytes. A device
// name or a relay's error message cannot then corrupt a terminal or forge a
// log line.
func CleanText(s string, max int) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(s) {
		if r < 0x20 || r == 0x7f {
			continue
		}
		if b.Len()+utf8.RuneLen(r) > max {
			break
		}
		b.WriteRune(r)
	}
	return b.String()
}

// CloseError is the error a connection returns when the far side ended it
// with a code.
type CloseError struct {
	Code   int
	Reason string
}

func (e *CloseError) Error() string {
	if e.Reason == "" {
		return fmt.Sprintf("closed with code %d", e.Code)
	}
	return fmt.Sprintf("closed with code %d: %s", e.Code, e.Reason)
}
