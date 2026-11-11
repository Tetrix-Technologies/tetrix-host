# Model routes

These are the routes an app calls. A paired device reaches them through the tunnel. A program on the host's own machine reaches them over loopback with the API key.

The routes follow the OpenAI HTTP API, so an existing OpenAI client works against a host. The host changes two things in a request and passes the rest to the engine untouched.

## Reach the routes

| From | Address | Authentication |
|------|---------|----------------|
| A paired device | The tunnel. See [Use a host from Swift](../how-to/use-a-host-from-swift.md) | The device's key, checked in the handshake |
| The host's machine | `http://127.0.0.1:4784/v1`, or the address `tetrix-host key` prints | `Authorization: Bearer <API key>` |

## Routes

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/chat/completions` | Chat, with or without streaming, tools, and structured output |
| `POST` | `/v1/completions` | Plain completion |
| `POST` | `/v1/embeddings` | Embeddings |
| `GET` | `/v1/models` | The roles and the installed models |
| `GET` | `/v1/host` | What the host can do |
| `DELETE` | `/v1/device` | Ends the calling device's own pairing. Returns `204`, then the host closes the device's sessions. A local program gets `400` |

A request body is at most 32 MB.

## The `model` field

| Value | The host uses |
|-------|---------------|
| `deep` | The model assigned to deep work |
| `quick` | The model assigned to quick work. If none is assigned, the deep model |
| Absent or empty | The deep model |
| `tetrix/deep`, `tetrix/quick` | The same as `deep` and `quick` |
| A model ID such as `ollama/qwen3:8b` | That model |

An app names a role, not a model. The host's owner decides which model serves each role.

## What the host changes

- The host replaces `model` with the engine's own name for the chosen model.
- If `stream` is `true` and the request has no `stream_options`, the host adds `{"include_usage": true}`. The engine then ends the stream with a chunk that holds token counts, and the host reads them for its statistics.

Every other field reaches the engine as the app sent it. Whether `tools`, `response_format`, or image input work depends on the engine and the model. `GET /v1/host` reports what each role's model can do.

## Responses

The host passes the engine's status and body through. A streamed answer is a `text/event-stream` body of `data:` lines that ends with `data: [DONE]`.

The header `x-host-model` holds the model ID that served the request.

## `GET /v1/models`

```json
{
	"object": "list",
	"data": [
		{ "id": "deep", "object": "model", "owned_by": "role", "resolves_to": "ollama/qwen3:8b" },
		{ "id": "quick", "object": "model", "owned_by": "role", "resolves_to": "ollama/gemma3:4b" },
		{ "id": "ollama/qwen3:8b", "object": "model", "owned_by": "ollama" },
		{ "id": "ollama/gemma3:4b", "object": "model", "owned_by": "ollama" }
	]
}
```

A role appears only when a model is assigned to it.

## `GET /v1/host`

```json
{
	"id": "aoccscb7qz37b47z",
	"name": "Studio",
	"product": "Tetrix Host",
	"version": "0.1.0",
	"single": false,
	"roles": {
		"deep": { "model": "ollama/qwen3:8b", "available": true, "contextLength": 40960, "contextInUse": 4096, "capabilities": ["tools", "thinking"] },
		"quick": { "model": "ollama/gemma3:4b", "available": true, "contextLength": 32768, "capabilities": [] }
	}
}
```

| Field | Meaning |
|-------|---------|
| `single` | True when one model serves both roles |
| `roles.<role>.model` | The assigned model ID. Empty when none is assigned |
| `roles.<role>.available` | Whether the model is installed and its engine answers |
| `roles.<role>.contextLength` | The largest context window the model supports, in tokens. Absent when the engine does not report it |
| `roles.<role>.contextInUse` | The window a request gets. On an Ollama engine the host sets it, so it is known before the model loads. On another engine it is what the engine reports for a loaded model, and absent otherwise |
| `roles.<role>.capabilities` | What the model can do beyond chat: `tools`, `vision`, `thinking`, `embedding`. `null` when the engine does not say. An empty list when the engine says the model has none |

A request that does not fit the window is cut to fit, with no error. An app must keep each request within `contextInUse` when that field is present.

## Errors

An error from the host has this body. An error from the engine passes through in the engine's own shape.

```json
{ "error": { "message": "This host has no model assigned yet. Its owner can assign one in Tetrix Host.", "type": "host_error", "code": "no_model_assigned" } }
```

| Status | Code | Cause |
|--------|------|-------|
| 400 | `bad_request` | The body is not a JSON object |
| 400 | `tools_unsupported` | The request has `tools`, and the engine reports that the chosen model cannot use them |
| 401 | `unauthorized` | A loopback request has no valid key |
| 404 | `model_not_found` | The request named a model ID that is not installed |
| 413 | `too_large` | The body is larger than 32 MB |
| 502 | `engine_unreachable` | The engine did not answer |
| 503 | `no_model_assigned` | No model is assigned to the role |
| 503 | `model_unavailable` | The role's model is not installed, or its engine is down |
