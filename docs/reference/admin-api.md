# Admin API

A running host serves this API on loopback. The Mac app and the `tetrix-host` CLI are both clients of it. A paired device cannot reach it, because the tunnel mounts the [model routes](model-api.md) only.

## Find the host

A running host writes `daemon.json` in its [data directory](files.md).

```json
{
	"pid": 4242,
	"address": "127.0.0.1:4784",
	"version": "0.1.0",
	"startedAt": "2026-11-11T02:28:55Z"
}
```

`GET http://<address>/healthz` needs no token. It returns `{"ok": true, "product": "Tetrix Host", "version": "..."}`.

### Check the host before you send the token

`daemon.json` can outlive the host that wrote it. Another program could then be listening on the same port. A client must check that the listener holds the admin token before it sends the token.

1. Make a random nonce of 16 to 64 bytes.
2. Send `GET /healthz` with the header `X-Host-Challenge: <nonce in base64>`.
3. Read `proof` from the answer.
4. Compute HMAC-SHA256 with the admin token's text as the key, over `"tetrix-host/local-proof/1" ‖ 0x00 ‖ nonce`. Encode the result in base64.
5. Compare the two in constant time. If they differ, or `proof` is absent, do not send the token. Treat the host as not running.

`internal/host/admin.go` has the host's side in `LocalProof`, and `cmd/tetrix-host/admin.go` has a client's side in `proves`.

## Authenticate

Send `Authorization: Bearer <token>` on every other request.

| Token | File | Opens |
|-------|------|-------|
| Admin token | `admin.token` | Every route |
| API key | `api.key` | The model routes under `/v1` only |

A request with no valid token gets `401`.

## Errors

A failed request returns a status of 400 or above and this body.

```json
{ "error": { "message": "No such device.", "type": "host_error", "code": "not_found" } }
```

`message` is written for a person and is safe to show.

## Routes

| Method | Path | Body | Success |
|--------|------|------|---------|
| `GET` | `/admin/v1/status` | | `200` and a [status document](#status-document) |
| `GET` | `/admin/v1/events` | | `200` and an [event stream](#event-stream) |
| `POST` | `/admin/v1/pairing` | | `200` and a [pairing offer](#pairing-offer) |
| `DELETE` | `/admin/v1/pairing` | | `204` |
| `PATCH` | `/admin/v1/devices/{id}` | `{"name": "..."}` | `204` |
| `DELETE` | `/admin/v1/devices/{id}` | | `204` |
| `PUT` | `/admin/v1/roles` | `{"deep": "<model id>", "quick": "<model id>"}` | `204` |
| `PUT` | `/admin/v1/settings` | `{"name": "...", "tunnel": {"enabled": true, "relay": "wss://..."}, "window": {"deep": 32768, "quick": 8192}}` | `204` |
| `POST` | `/admin/v1/models/pull` | `{"name": "qwen3:8b", "engine": "ollama"}` | `202` |
| `DELETE` | `/admin/v1/models/pull?engine=<id>&name=<name>` | | `204` |
| `DELETE` | `/admin/v1/models?id=<model id>` | | `204` |
| `POST` | `/admin/v1/engines` | `{"id": "...", "kind": "ollama", "baseURL": "http://...", "apiKey": "..."}` | `204` |
| `DELETE` | `/admin/v1/engines/{id}` | | `204` |

### Pairing

`POST /admin/v1/pairing` makes a new code and cancels the code that was open. `DELETE` cancels the open code. A code works once and expires after 10 minutes.

### Devices

`PATCH /admin/v1/devices/{id}` renames a device. An empty name returns `400`. An unknown ID returns `404`.

`DELETE /admin/v1/devices/{id}` unpairs a device. The host removes the device's key and closes every session the device has open. If the host cannot save the change to disk, it still unpairs the device for this run and returns `500` with a message that says so.

### Roles

Every field of the `PUT /admin/v1/roles` body is optional. A field that is absent keeps its value. Set `quick` to `""`, or to the same model as `deep`, to use one model for everything. A model ID that is not installed returns `404`.

### Settings

Every field of the `PUT /admin/v1/settings` body is optional. A change to the tunnel restarts the tunnel and cancels the open pairing code.

`window` sets the context window, in tokens, that the host gives the model for each kind of work. A positive number is at least 1,024. Zero restores the default. A negative number leaves the window to the engine.

### Models

`POST /admin/v1/models/pull` starts a download and returns at once. `engine` is optional and defaults to the first Ollama engine. Progress arrives as `pull` events. The status document lists downloads in progress under `pulls`.

`DELETE /admin/v1/models` deletes a model from its engine. If a role used the model, the host clears that role.

An engine of kind `openai` manages its own models. A pull or a delete on such an engine fails with `unsupported`.

## Status document

`GET /admin/v1/status` returns the whole state of the host.

| Field | Type | Meaning |
|-------|------|---------|
| `product` | string | The product name |
| `version` | string | The host's version |
| `host.id` | string | The host ID, 16 characters |
| `host.name` | string | The name a person gave the host |
| `host.startedAt` | time | When this run started |
| `host.address` | string | The loopback address of this API |
| `host.endpoint` | string | The base URL for an OpenAI client on this machine |
| `hardware.model` | string | The machine's name, such as `Mac mini` |
| `hardware.kind` | string | `laptop`, `desktop`, or `server` |
| `hardware.chip` | string | The processor |
| `hardware.cores` | number | Logical processor cores |
| `hardware.memoryBytes` | number | Installed memory |
| `hardware.diskBytes` | number | Size of the data volume |
| `hardware.diskFreeBytes` | number | Free space on the data volume |
| `hardware.os` | string | The operating system and its version |
| `hardware.arch` | string | The processor architecture |
| `hardware.gpus` | array | Graphics cards with their own memory: `name`, `memoryBytes`. Absent on a Mac |
| `load.memoryUsedBytes` | number | Memory in use |
| `load.cpuPercent` | number | Processor use, 0 to 100 |
| `load.at` | time | When the sample was taken |
| `tunnel.enabled` | boolean | Whether the host connects to a relay |
| `tunnel.state` | string | `connected`, `connecting`, `offline`, or `disabled` |
| `tunnel.relay` | string | The relay's address |
| `tunnel.since` | time | When the tunnel entered this state. Absent when disabled |
| `tunnel.lastError` | string | Why the tunnel is offline. Absent when connected |
| `engines` | array | [Engines](#engine) |
| `roles.deep` | string | Model ID for work that needs thought. Empty when none is assigned |
| `roles.quick` | string | Model ID for short work. Empty when `deep` serves both |
| `roles.single` | boolean | True when one model serves both |
| `roles.window.deep` | number | The context window the host asks for on deep work, in tokens. 0 when left to the engine |
| `roles.window.quick` | number | The same for quick work |
| `devices` | array | [Devices](#device) |
| `stats.requests` | number | Requests served since the host started |
| `stats.tokensIn` | number | Prompt tokens since the host started |
| `stats.tokensOut` | number | Generated tokens since the host started |
| `stats.active` | number | Requests in progress |
| `stats.running` | array | The requests in progress, oldest first: `id`, `at`, `deviceId`, `source`, `role`, `model`. `deviceId` is absent for a local request, and `role` is absent when the app named a model |
| `stats.tokensPerSecond` | number | Generation speed of the last request that produced more than one token over at least 50 milliseconds. A shorter answer leaves the earlier value in place |
| `stats.recent` | array | The last 40 [requests](#request-record), newest first |
| `pairing` | object or null | The open [pairing offer](#pairing-offer) |
| `pulls` | array | Downloads in progress, as [pull progress](#pull-progress) |

Times are RFC 3339 strings in UTC.

### Engine

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | The engine's ID |
| `kind` | string | `ollama` or `openai` |
| `baseURL` | string | Where the engine listens |
| `state` | string | `ready` or `unreachable` |
| `version` | string | The engine's version, if it reports one |
| `error` | string | Why the engine is unreachable |
| `models` | array | [Models](#model). Empty when unreachable |

### Model

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | The engine ID, a slash, and the engine's name for the model |
| `engine` | string | The engine ID |
| `name` | string | The engine's name for the model |
| `sizeBytes` | number | Size on disk. Absent if the engine does not report it |
| `family` | string | The model family |
| `parameters` | string | Parameter count, such as `8.2B` |
| `quantization` | string | Quantization level, such as `Q4_K_M` |
| `contextLength` | number | The largest context window the model supports, in tokens |
| `contextInUse` | number | The window the engine runs the model with now. Absent when the model is not loaded. A request longer than this is cut short |
| `capabilities` | array | What the model can do beyond chat: `tools`, `vision`, `thinking`, `embedding`. Absent when empty |
| `loaded` | boolean | Whether the model is in memory now |

### Device

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | The device ID, which starts with `d_` |
| `name` | string | The device's name |
| `app` | string | The app that paired, such as `Cue` |
| `appVersion` | string | The app's version |
| `platform` | string | The app's platform, such as `macOS` |
| `publicKey` | string | The device's static public key, base64 |
| `pairedAt` | time | When the device paired |
| `lastSeenAt` | time | When the device last opened a session |
| `online` | boolean | Whether the device has a session open now |
| `requests` | number | Requests from this device since the host started |
| `tokensIn` | number | Prompt tokens from this device |
| `tokensOut` | number | Tokens generated for this device |

### Request record

A record holds sizes and times. It never holds a prompt or an answer.

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | Unique within this run |
| `at` | time | When the request started |
| `deviceId` | string | The device that sent it. Absent for a local request |
| `source` | string | `tunnel` or `local` |
| `role` | string | `deep` or `quick`. Absent when the app named a model |
| `model` | string | The model ID that served it |
| `status` | number | The HTTP status. `499` means the app cancelled |
| `durationMs` | number | Time from request to last byte |
| `tokensIn` | number | Prompt tokens |
| `tokensOut` | number | Generated tokens |
| `stream` | boolean | Whether the answer was streamed |

### Pairing offer

| Field | Type | Meaning |
|-------|------|---------|
| `code` | string | The code, in groups of four characters |
| `link` | string | The code as a `tetrix-host://pair/` link. Draw this as the QR image |
| `expiresAt` | time | When the code stops working |

### Pull progress

| Field | Type | Meaning |
|-------|------|---------|
| `engine` | string | The engine ID |
| `name` | string | The engine's name for the model |
| `status` | string | `Starting`, `Downloading`, `Verifying`, `Finishing`, `Done`, `Cancelled`, or `Failed` |
| `completed` | number | Bytes downloaded |
| `total` | number | Bytes to download. 0 until the engine knows |
| `done` | boolean | True on the last event of a download |
| `error` | string | Why the download failed. `cancelled` after a cancel |

## Event stream

`GET /admin/v1/events` holds the connection open and sends server-sent events. A comment line arrives every 15 seconds to keep the connection alive.

```
event: changed
data: {"type":"changed","at":"2026-11-11T02:31:07Z"}

event: load
data: {"type":"load","at":"2026-11-11T02:31:10Z","data":{"memoryUsedBytes":13059981312,"cpuPercent":27.4,"at":"2026-11-11T02:31:10Z"}}
```

| Event | `data` | Sent when |
|-------|--------|-----------|
| `changed` | none | The status document is out of date. Fetch it again |
| `load` | A `load` object | Every 3 seconds while a client is connected |
| `pull` | [Pull progress](#pull-progress) | A download advances, at most 4 times a second |
| `request` | A [request record](#request-record) | A request finishes |
| `paired` | A [device](#device) without the activity fields | A device pairs |

A client that falls 64 events behind loses events. After a reconnect, fetch the status document.
