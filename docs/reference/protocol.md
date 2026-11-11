# Wire protocol

This page specifies the bytes that a client, a relay, and a host exchange. It is version 1. Two implementations exist: Go in `internal/wire`, `internal/secure`, `internal/relay`, `internal/tunnel`, and `internal/session`, and Swift in `Sources/TetrixHostKit`.

For the reasons behind these choices, read [Security model](../explanation/security.md).

## Terms

| Term | Meaning |
|------|---------|
| Host | The program that serves models on a person's machine |
| Client | An app on a paired device |
| Relay | The server that passes messages between a client and a host |
| Message | One binary WebSocket message |
| Sealed message | A message encrypted with a Noise transport key |

All integers are big-endian unless a line says otherwise.

## Identifiers

A host has two long-term keys.

| Key | Type | Use |
|-----|------|-----|
| Signing key | Ed25519 | Proves the host ID to a relay |
| Static key | X25519 | The host's Noise static key |

A client has one long-term key per pairing: an X25519 static key.

| Identifier | Derivation |
|------------|------------|
| Host ID | The first 10 bytes of `SHA-256("tetrix-host/host-id/1" ‖ 0x00 ‖ signing public key)`, in lower-case base32 without padding. 16 characters |
| Device ID | `d_` followed by the first 8 bytes of `SHA-256("tetrix-host/device-id/1" ‖ 0x00 ‖ client static public key)`, in lower-case base32 without padding |

Base32 is the RFC 4648 alphabet, `A` to `Z` and `2` to `7`.

## Relay endpoints

Both WebSocket endpoints use the subprotocol `tetrix-host.v1`.

| Connection | Largest message |
|------------|-----------------|
| Client to relay | 65,535 bytes, the largest Noise message |
| Host to relay | 65,544 bytes, one client message and the 9-byte relay frame header |

The relay closes a client that sends a larger message. It never forwards a message that the host would refuse to read.

| Endpoint | Caller | Purpose |
|----------|--------|---------|
| `GET /v1/host?id={hostId}` | Host | Register and receive clients |
| `GET /v1/connect/{hostId}` | Client | Reach a registered host |
| `GET /healthz` | Anyone | Returns `{"ok": true, ...}` |

### Host registration

The host names its ID in the address, so that a relay can send the connection to the right place before anything is proved. The ID proves nothing by itself. The exchange below does.

The host and the relay exchange three JSON text messages before any binary message.

1. The relay sends `{"type": "challenge", "nonce": "<base64, 32 bytes>"}`.
2. The host sends `{"type": "register", "hostId": "...", "publicKey": "<base64 signing public key>", "signature": "<base64>"}`. The signature is Ed25519 over `"tetrix-host/relay-register/1" ‖ 0x00 ‖ nonce`.
3. The relay checks the signature, and checks that `hostId` is the host ID of `publicKey` and the ID in the address. It sends `{"type": "registered", "hostId": "..."}`. On failure it sends `{"type": "error", "code": "...", "message": "..."}` and closes with code 4401.

A host that registers an ID that is already registered replaces the earlier connection. The relay closes the earlier connection with code 4409 and closes that connection's clients with code 4404.

The relay sends a WebSocket ping every 25 seconds on every connection. A peer that does not answer within 10 seconds is disconnected.

### Relay frames

After registration, every message between the host and the relay is a relay frame.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | Type |
| 1 | 8 | Session ID |
| 9 | rest | Payload |

| Type | Value | Direction | Payload |
|------|-------|-----------|---------|
| `OPEN` | `0x01` | Relay to host | Empty. A client connected, and the relay gave it this session ID |
| `DATA` | `0x02` | Both | One message to or from that client, unchanged |
| `CLOSE` | `0x03` | Both | From the relay: empty. From the host: empty, or a 2-byte close code and a UTF-8 reason of at most 64 bytes |

A client's connection carries bare messages with no relay frame. The relay adds and removes the 9-byte header.

When the host sends `CLOSE` with a code from 4000 to 4999, the relay closes the client's WebSocket with that code and reason. The relay can read the reason, so a reason names a category and carries no detail.

### Close codes

| Code | Meaning | Sent by |
|------|---------|---------|
| 4400 | Malformed opening message, frame, or host ID | Relay, host |
| 4401 | The handshake failed, or a host's registration failed | Relay, host |
| 4403 | The client's key belongs to no paired device | Host |
| 4404 | The host is not registered, or it disconnected | Relay |
| 4408 | The receiver read too slowly | Relay, host |
| 4409 | Another connection registered this host ID | Relay |
| 4410 | The pairing failed: no open code, or the wrong code | Host |
| 4429 | Too many sessions or too many new connections | Relay |
| 4500 | The host failed internally | Host |

### Relay limits

| Limit | Default |
|-------|---------|
| Clients connected to one host | 64 |
| New client connections to one host | 240 a minute |
| Clients connected to one host from one address | 16 |
| New client connections to one host from one address | 60 a minute |
| Bytes queued for one slow client | 8 MiB |
| Bytes queued for one slow host | 32 MiB |

A connection that exceeds a queue limit is closed with code 4408. A connection that exceeds a count is closed with code 4429.

An address is an IPv4 address or an IPv6 /64. The relay reads it from the connection. With `--behind-proxy`, the relay reads it from the last entry of `X-Forwarded-For`.

A host also limits itself to 128 clients at once, and closes a further client with code 4429.

### Close codes are hints

A close code is not sealed, so a relay can send any code. A client must not treat a code as a statement from the host. In particular, a client must not discard a pairing because of a code. The host's own refusal of an unpaired device travels inside the session handshake.

## Opening message

The first message a client sends says which handshake follows.

| First byte | Then | Handshake |
|------------|------|-----------|
| `0x01` | A 4-byte hint, then Noise message 1 | [Pairing](#pairing-handshake) |
| `0x02` | Noise message 1 | [Session](#session-handshake) |

The host closes a connection that sends nothing for 15 seconds.

## Noise

Both handshakes follow the Noise Protocol Framework, revision 34, with these functions.

| Function | Choice |
|----------|--------|
| DH | 25519 |
| Cipher | ChaChaPoly |
| Hash | SHA256 |

Each handshake payload is a JSON object.

| Object | Fields |
|--------|--------|
| Host hello | `hostId`, `name`, `version`, and `refused` when the host will not serve the client |
| Client hello | `name`, `app`, `appVersion`, `platform`, `sdk`. All optional |

### Pairing code

A pairing code is 27 bytes in base32 without padding, written in groups of four characters with hyphens.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | Version, `0x01` |
| 1 | 10 | Host ID, before encoding |
| 11 | 16 | Secret, random |

A pairing link is `tetrix-host://pair/<code>`. If the host's relay is not the default relay, the link ends with `?relay=<percent-encoded relay address>`. A bare code means the default relay, `wss://relay.tetrix.tech`.

| Value | Derivation |
|-------|------------|
| Hint | The first 4 bytes of `SHA-256("tetrix-host/pair-hint/1" ‖ 0x00 ‖ secret)` |
| Pre-shared key | `SHA-256("tetrix-host/pair-psk/1" ‖ 0x00 ‖ secret)` |

A host holds at most one open code. A code expires 10 minutes after the host makes it. A code works once. After 5 failed attempts the host voids the code.

### Pairing handshake

The protocol name is `Noise_XXpsk0_25519_ChaChaPoly_SHA256`. The prologue is `"tetrix-host/pair/1" ‖ 0x00 ‖ host ID`, with the host ID in its 16-character form. The client is the initiator.

| Message | Direction | Pattern | Payload |
|---------|-----------|---------|---------|
| 1 | Client to host | `psk, e` | Empty |
| 2 | Host to client | `e, ee, s, es` | Host hello |
| 3 | Client to host | `s, se` | Client hello |

The host finds the code by the hint. If message 1 does not open under that code's pre-shared key, the host counts a failed attempt and closes with code 4410.

After message 3 the host stores the client's static key as a new device, or updates the device that already has that key. The host then sends one sealed message that holds a `PAIRED` frame. The frame's payload is `{"ok": true, "deviceId": "...", "hostId": "...", "hostName": "..."}`, or `{"ok": false, "error": "..."}`.

The client stores the host ID, the relay address, the host's static public key from message 2, its own static private key, and the device ID. The connection then closes.

### Session handshake

The protocol name is `Noise_IK_25519_ChaChaPoly_SHA256`. The prologue is `"tetrix-host/session/1" ‖ 0x00 ‖ host ID`. The client is the initiator and supplies the host's static public key from its pairing.

| Message | Direction | Pattern | Payload |
|---------|-----------|---------|---------|
| 1 | Client to host | `e, es, s, ss` | Client hello |
| 2 | Host to client | `e, ee, se` | Host hello |

If message 1 does not open, the host closes with code 4401.

If the client's static key belongs to no paired device, the host sends message 2 with a host hello of `{"hostId": "...", "name": "", "version": "", "refused": "unknown_device"}`, then closes with code 4403. Message 2 opens only under keys that the real host can derive, so the client knows that the host itself refused it. A client that reads `refused` ends the handshake and sends nothing more.

The client sends a `PING` frame as its first sealed message and waits for the `PONG`. The host closes a session with code 4400 if no sealed message arrives within 15 seconds of message 2. The host marks a device as connected only after it opens a sealed message from that device. A replay of message 1 alone therefore gets an answer that the replayer cannot read, holds a session for 15 seconds, and has no other effect.

## Sealed channel

After a handshake, each message is one Noise transport message with empty associated data. The initiator's first cipher state seals what the client sends. Nonces count up from zero in each direction, so messages must arrive in the order they were sealed. This version does not rekey.

The plaintext of each sealed message is one tunnel frame.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | Type |
| 1 | 4 | Stream ID |
| 5 | 2 | Payload length, `n` |
| 7 | `n` | Payload |
| 7 + `n` | rest | Padding |

A sender pads each frame with zero bytes to the next multiple of 512 bytes, up to the largest plaintext, 65,519 bytes. A receiver reads `n` bytes of payload and ignores the rest. The largest payload is 65,512 bytes.

| Type | Value | Direction | Payload |
|------|-------|-----------|---------|
| `REQUEST` | `0x01` | Client to host | JSON `{"method": "...", "path": "...", "headers": {...}}`. Opens a stream |
| `BODY` | `0x02` | Both | Body bytes |
| `END` | `0x03` | Both | Empty. The sender's body is complete |
| `RESPONSE` | `0x04` | Host to client | JSON `{"status": 200, "headers": {...}}` |
| `RESET` | `0x05` | Both | Empty, or JSON `{"code": "...", "message": "..."}`. The stream is abandoned |
| `PING` | `0x06` | Both | Any bytes. The receiver answers with `PONG` and the same payload |
| `PONG` | `0x07` | Both | The payload of the `PING` |
| `PAIRED` | `0x10` | Host to client | The result of a pairing |

A receiver ignores a frame type it does not know.

### Streams

A stream carries one HTTP-style request and its response. The client picks the stream ID. A stream ID is not zero and is not reused on a connection. Stream ID zero is for `PING` and `PONG`.

1. The client sends `REQUEST`, then zero or more `BODY` frames, then `END`.
2. The host sends `RESPONSE`, then zero or more `BODY` frames, then `END`.

The host can send `RESPONSE` before it receives the client's `END`. Header names are lower case. The host drops the request headers `authorization`, `host`, and `connection`, because the handshake has already identified the device.

Either side can send `RESET` to abandon a stream. When the host receives `RESET`, it cancels the request, which stops the model. When a connection closes, every stream on it is abandoned.

A sender cuts a body into `BODY` frames of at most 32,768 bytes. A host accepts at most 16 open streams on one connection and answers a further `REQUEST` with `RESET` and the code `too_many_streams`.

The paths a client can request are the [model routes](model-api.md).
