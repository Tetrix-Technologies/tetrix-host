package wire

import (
	"bytes"
	"testing"
)

func TestTunnelFramePadsToBlocks(t *testing.T) {
	for _, tc := range []struct{ payload, want int }{
		{0, 512}, {3, 512}, {505, 512}, {506, 1024}, {BodyChunk, 33280}, {MaxFramePayload, MaxNoiseMessage - TagSize},
	} {
		payload := bytes.Repeat([]byte{0xAB}, tc.payload)
		frame := AppendTunnelFrame(nil, FrameBody, 7, payload)
		if len(frame) != tc.want {
			t.Errorf("a payload of %d bytes made a frame of %d, want %d", tc.payload, len(frame), tc.want)
		}
		kind, stream, got, err := ParseTunnelFrame(frame)
		if err != nil || kind != FrameBody || stream != 7 || !bytes.Equal(got, payload) {
			t.Errorf("a payload of %d bytes did not round trip: %v", tc.payload, err)
		}
	}
}

func TestTunnelFrameMatchesSwift(t *testing.T) {
	// The Swift tests assert the same bytes for the same frame.
	frame := AppendTunnelFrame(nil, FrameBody, 0x01020304, []byte("abc"))
	if want := []byte{0x02, 1, 2, 3, 4, 0, 3, 'a', 'b', 'c'}; !bytes.Equal(frame[:10], want) {
		t.Fatalf("frame starts % x, want % x", frame[:10], want)
	}
}

func TestParseRefusesBadLengths(t *testing.T) {
	if _, _, _, err := ParseTunnelFrame([]byte{1, 2}); err == nil {
		t.Error("a short frame parsed")
	}
	if _, _, _, err := ParseTunnelFrame([]byte{2, 0, 0, 0, 1, 0, 9, 1, 2}); err == nil {
		t.Error("a frame whose length points past its end parsed")
	}
}

func TestCloseRoundTrip(t *testing.T) {
	code, reason := ParseClose(AppendClose(nil, CloseUnknownDevice, "unknown device"))
	if code != CloseUnknownDevice || reason != "unknown device" {
		t.Fatalf("got %d %q", code, reason)
	}
	if code, _ := ParseClose(nil); code != 1000 {
		t.Fatalf("an empty payload gave %d, want 1000", code)
	}
	// A host cannot make the relay send a code outside the application range.
	if code, _ := ParseClose(AppendClose(nil, 1001, "")); code != 1000 {
		t.Fatalf("a reserved code passed through as %d", code)
	}
}
