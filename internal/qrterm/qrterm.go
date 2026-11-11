// Package qrterm draws a QR code in a terminal.
package qrterm

import (
	"io"
	"strings"

	"rsc.io/qr"
)

// Write draws text as a QR code. It sets its own colors, black on white, so
// the code scans on a dark or a light terminal. Each line of text holds two
// rows of the code.
func Write(w io.Writer, text string) error {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return err
	}
	const quiet = 2
	size := code.Size + 2*quiet
	dark := func(x, y int) bool {
		x, y = x-quiet, y-quiet
		return x >= 0 && y >= 0 && x < code.Size && y < code.Size && code.Black(x, y)
	}
	var b strings.Builder
	for y := 0; y < size; y += 2 {
		b.WriteString("  \x1b[30;47m")
		for x := 0; x < size; x++ {
			top, bottom := dark(x, y), dark(x, y+1)
			switch {
			case top && bottom:
				b.WriteString("█")
			case top:
				b.WriteString("▀")
			case bottom:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		b.WriteString("\x1b[0m\n")
	}
	_, err = io.WriteString(w, b.String())
	return err
}
