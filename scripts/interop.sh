#!/bin/sh
# Runs the Swift client against a real host through a real relay.
#
# The script builds the host, starts a fake engine, a relay, and a host in a
# temporary directory, makes a pairing link, and runs the Swift suite
# LiveHostTests with it. Nothing touches your own host's files, and no model
# is needed.
#
# Usage: scripts/interop.sh
# Set PORT_BASE to move the three loopback ports (default 18940).
# Set RELAY_URL to test through a relay that already runs, in place of the
# Go relay this script starts. For example, the Cloudflare Worker under
# "wrangler dev" at ws://127.0.0.1:18950, or the deployed one.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
base=${PORT_BASE:-18940}
engine=127.0.0.1:$((base + 1))
relay=127.0.0.1:$((base + 2))
host=127.0.0.1:$((base + 3))

work=$(mktemp -d)
pids=""
cleanup() {
	for pid in $pids; do kill "$pid" 2>/dev/null || true; done
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

cd "$root"
go build -o "$work/tetrix-host" ./cmd/tetrix-host

"$work/tetrix-host" dev fake-engine --listen "$engine" >"$work/engine.log" 2>&1 &
pids="$pids $!"
relay_url=${RELAY_URL:-}
if [ -z "$relay_url" ]; then
	"$work/tetrix-host" relay serve --listen "$relay" >"$work/relay.log" 2>&1 &
	pids="$pids $!"
	relay_url="ws://$relay"
fi

export TETRIX_HOST_HOME="$work/home"
mkdir -p "$TETRIX_HOST_HOME"
cat >"$TETRIX_HOST_HOME/config.json" <<JSON
{
	"name": "Interop host",
	"listen": "$host",
	"tunnel": { "enabled": true, "relay": "$relay_url" },
	"engines": [{ "id": "fake", "kind": "openai", "baseURL": "http://$engine" }],
	"roles": { "deep": "fake/big", "quick": "fake/small" }
}
JSON
"$work/tetrix-host" serve --quiet >"$work/host.log" 2>&1 &
pids="$pids $!"

tries=0
until "$work/tetrix-host" status --json 2>/dev/null | grep -q '"state": "connected"'; do
	tries=$((tries + 1))
	if [ "$tries" -gt 50 ]; then
		echo "The host did not connect to the relay. Its log:" >&2
		cat "$work/host.log" >&2
		exit 1
	fi
	sleep 0.2
done

link=$("$work/tetrix-host" pair --json | sed -n 's/.*"link":"\([^"]*\)".*/\1/p')
if [ -z "$link" ]; then
	echo "The host did not return a pairing link." >&2
	exit 1
fi

# A host has one open code at a time, so the second link is made only once
# the first is spent. The test asks for it through this helper.
export TETRIX_HOST_PAIR_LINK="$link"
export TETRIX_HOST_INTEROP_BINARY="$work/tetrix-host"
swift test --filter LiveHostTests
