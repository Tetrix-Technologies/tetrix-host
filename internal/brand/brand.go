// Package brand holds every user-visible name in one place. Protocol
// identifiers are separate constants in package wire, so a change here
// never changes the wire format.
package brand

const (
	// Name is the product's name as people read it.
	Name = "Tetrix Host"
	// CLI is the command people type.
	CLI = "tetrix-host"
	// Scheme is the URL scheme of a pairing link.
	Scheme = "tetrix-host"
	// EnvHome names the environment variable that moves the data directory.
	EnvHome = "TETRIX_HOST_HOME"
	// ServiceLabel names the background service.
	ServiceLabel = "tech.tetrix.host"
	// DefaultRelay is the relay a host uses when none is configured.
	DefaultRelay = "wss://relay.tetrix.tech"
	// DefaultListen is the loopback address of the local API.
	DefaultListen = "127.0.0.1:4784"
	// Source is where the code lives.
	Source = "https://github.com/Tetrix-Technologies/tetrix-host"
)

// Version is set at build time with -ldflags "-X .../brand.Version=1.2.3".
var Version = "0.1.0-dev"
