# Files

A host keeps its files in one data directory.

## Data directory

| Platform | Path |
|----------|------|
| macOS | `~/Library/Application Support/Tetrix Host` |
| Linux | `~/.config/tetrix-host`, or `$XDG_CONFIG_HOME/tetrix-host` |
| Windows | `%AppData%\Tetrix Host` |

The environment variable `TETRIX_HOST_HOME` replaces the path. The CLI, the host, and the Mac app all read it.

The host creates the directory with mode `0700`.

## Contents

| File | Mode | Holds | Written |
|------|------|-------|---------|
| `config.json` | `0600` | The host's name, listen address, tunnel setting, engines, and roles | On first start and on each change |
| `identity.json` | `0600` | The signing key and the static key | On first start |
| `devices.json` | `0600` | Paired devices: ID, name, app, public key, times | On each pairing, rename, removal, and connection |
| `admin.token` | `0600` | The admin token | On first start |
| `api.key` | `0600` | The API key for local programs | On first start |
| `daemon.json` | `0600` | The running host's process ID and address | On start. Removed on a clean stop |
| `host.log` | | The host's log, when the macOS background service runs it | By the service |

Models are not in this directory. Each engine stores its own.

## `config.json`

```json
{
	"name": "Studio",
	"listen": "127.0.0.1:4784",
	"tunnel": { "enabled": true, "relay": "wss://relay.tetrix.tech" },
	"engines": [
		{ "id": "ollama", "kind": "ollama", "baseURL": "http://127.0.0.1:11434" }
	],
	"roles": { "deep": "ollama/qwen3:8b", "quick": "ollama/gemma3:4b" },
	"window": { "deep": 32768, "quick": 8192 }
}
```

| Field | Meaning | Default |
|-------|---------|---------|
| `name` | The name paired devices see | The machine's host name |
| `listen` | The loopback address of the local API | `127.0.0.1:4784` |
| `tunnel.enabled` | Whether the host connects to a relay | `true` |
| `tunnel.relay` | The relay's address | `wss://relay.tetrix.tech` |
| `engines[].id` | A short name, with no slash | |
| `engines[].kind` | `ollama` or `openai` | |
| `engines[].baseURL` | Where the engine listens | |
| `engines[].apiKey` | A key the engine requires. Optional | |
| `roles.deep` | The model ID for deep work | Empty until a model is installed |
| `roles.quick` | The model ID for quick work. Empty means the deep model | Empty |
| `window.deep` | The context window for deep work, in tokens. A negative number leaves it to the engine | 32,768 |
| `window.quick` | The context window for quick work | 8,192 |

The host reads `config.json` when it starts. Stop the host before you edit the file by hand.

## What each file means for recovery

| If you lose | Then |
|-------------|------|
| `identity.json` | The host makes a new identity and a new host ID. Every device must pair again |
| `devices.json` | Every device must pair again |
| `admin.token` or `api.key` | The host makes a new one on its next start. Local programs need the new API key |
| `config.json` | The host starts with defaults. Assign the roles again |

To move a host to another machine, copy `identity.json`, `devices.json`, and `config.json`. Paired devices keep working, because the host ID and keys are the same.

Anyone who can read `identity.json` can impersonate the host to its paired devices. Keep it out of shared backups.
