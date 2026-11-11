# Command line

`tetrix-host` runs a host and manages it. Every command except `serve`, `relay serve`, `service`, `version`, and `help` talks to a running host and fails with a clear message if none is running.

## Environment

| Variable | Effect |
|----------|--------|
| `TETRIX_HOST_HOME` | The [data directory](files.md). Set it to run a second host on one machine |

## Run

| Command | Does |
|---------|------|
| `tetrix-host serve` | Runs the host in the terminal until Ctrl-C |
| `tetrix-host serve --listen <address>` | Uses this loopback address for this run. The default is `127.0.0.1:4784` |
| `tetrix-host serve --quiet` | Logs warnings and errors only |
| `tetrix-host service install` | Installs and starts the host as a background service of this user |
| `tetrix-host service uninstall` | Stops and removes the service. Keeps all data |
| `tetrix-host service status` | Says whether the service is installed and running |

## Inspect

| Command | Does |
|---------|------|
| `tetrix-host status` | Prints the host, machine, tunnel, roles, devices, and totals |
| `tetrix-host status --json` | Prints the [status document](admin-api.md#status-document) |
| `tetrix-host doctor` | Checks the host, each engine, each role, a test request, the tunnel, and a round trip through the relay. Exits with status 1 if a check fails |
| `tetrix-host key` | Prints the base URL and API key for programs on this machine |
| `tetrix-host version` | Prints the version |

`doctor` pairs and unpairs a throwaway device to test the tunnel. It skips that check while a pairing code is open, because the check would cancel the code.

## Devices

| Command | Does |
|---------|------|
| `tetrix-host pair` | Prints a pairing QR code and link, then waits until a device pairs, the code expires, or Ctrl-C |
| `tetrix-host pair --no-wait` | Prints the code and exits. The code stays open |
| `tetrix-host pair --json` | Prints the [pairing offer](admin-api.md#pairing-offer) as JSON and exits |
| `tetrix-host devices` | Lists paired devices |
| `tetrix-host devices rm <device>` | Unpairs a device, by name or ID |
| `tetrix-host devices rename <device> <name>` | Renames a device |

Making a code cancels the code that was open. `pair` cancels its code when it exits without a pairing.

## Models

| Command | Does |
|---------|------|
| `tetrix-host models` | Lists installed models, their roles, what they can do, and the context window each runs with |
| `tetrix-host models pull <name>` | Downloads a model with the first Ollama engine. Ctrl-C cancels |
| `tetrix-host models rm <model>` | Deletes a model |
| `tetrix-host use <model>` | Uses one model for everything |
| `tetrix-host use deep <model>` | Sets the model for deep work |
| `tetrix-host use quick <model>` | Sets the model for quick work |
| `tetrix-host window` | Prints the context window the host gives the model for each kind of work |
| `tetrix-host window deep <tokens>` | Sets the window for deep work. The default is 32,768 |
| `tetrix-host window quick <tokens>` | Sets the window for quick work. The default is 8,192 |
| `tetrix-host chat [text]` | Sends text to the deep model and prints the answer. With no text, starts a conversation |
| `tetrix-host chat --quick [text]` | Uses the quick model |
| `tetrix-host chat --model <model> [text]` | Uses a named model |

`<model>` is a model ID such as `ollama/qwen3:8b`, or the engine's own name, `qwen3:8b`, when only one engine has a model of that name.

In place of a number, `window` takes `default`, which restores the default, or `engine`, which leaves the window to the model server. The smallest window is 1,024 tokens. The host sets the window on an Ollama engine only.

`chat` reads a prompt from standard input when input is piped.

## Engines

| Command | Does |
|---------|------|
| `tetrix-host engines` | Lists engines, their state, and how many models each has |
| `tetrix-host engines add <id> <address>` | Adds a server that speaks the OpenAI API |
| `tetrix-host engines add --kind ollama <id> <address>` | Adds an Ollama server |
| `tetrix-host engines add --key <key> <id> <address>` | Adds a server that needs a key |
| `tetrix-host engines rm <id>` | Removes an engine |

## Tunnel

| Command | Does |
|---------|------|
| `tetrix-host tunnel` | Prints the tunnel's state, the relay, and the host ID |
| `tetrix-host tunnel on` | Connects to the relay |
| `tetrix-host tunnel off` | Disconnects. Paired devices cannot reach the host |
| `tetrix-host tunnel relay <address>` | Uses another relay. The address starts with `wss://` or `ws://` |
| `tetrix-host tunnel relay default` | Uses the default relay, `wss://relay.tetrix.tech` |
| `tetrix-host name <name>` | Sets the name paired devices see |

A change to the tunnel cancels the open pairing code.

## Relay

| Command | Does |
|---------|------|
| `tetrix-host relay serve` | Runs a relay on port 8787 |
| `tetrix-host relay serve --listen <address>` | Listens on this address |
| `tetrix-host relay serve --max-hosts <n>` | Serves at most `n` hosts at once |
| `tetrix-host relay serve --behind-proxy` | Reads each client's address from `X-Forwarded-For`. For a relay behind your own reverse proxy |

## Exit status

A command exits with status 0 on success and 1 on failure. A failure prints one line to standard error that starts with `tetrix-host:`.
