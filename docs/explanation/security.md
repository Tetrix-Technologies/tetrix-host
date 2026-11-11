# Security model

Tetrix Host exists so that a person's prompts and answers stay on hardware they own. This page says what that promise covers, how the design keeps it, and where it stops. It is written so that you can check each claim against the code.

## Who is trusted with what

Four parties take part in a request.

| Party | Run by | Trusted to |
|-------|--------|------------|
| The app on a paired device | The person | See its own prompts and answers |
| The host | The person | See every prompt and answer, and run the models |
| The engine, such as Ollama | The person | The same as the host. It runs on the same machine |
| The relay | Tetrix, or the person | Deliver messages. Nothing else |

The relay is the only part that sits outside the person's own hardware, so the design treats it as hostile. A relay that is curious, broken into, or served with a legal order must learn as little as possible and must not be able to act as anyone.

## What the relay cannot do

**It cannot read a request or an answer.** The app and the host run a Noise handshake through the relay and derive keys the relay never sees. Everything after the handshake is sealed with ChaCha20-Poly1305 under those keys. This covers the prompt, the answer, the model's name, the tool calls, and the names of the app and the device.

**It cannot pretend to be the host.** When an app pairs, it learns the host's static public key and keeps it. Every later session uses the Noise IK pattern, in which the app seals its first message to that key. A relay that answers in the host's place cannot open the message or finish the handshake, and the app reports that the host could not prove its identity.

**It cannot pretend to be a device.** The host accepts a session only from a static key that belongs to a paired device. The key is proved inside the handshake, not sent as a token the relay could copy.

**It cannot pair a device.** Pairing needs the code the host shows on its own screen. The code holds a 128-bit random secret, and the pairing handshake, Noise XXpsk0, mixes that secret into the keys from the first message. The relay passes the handshake but never sees the code, so it cannot complete one. A person who reads the code off the screen or scans it carries the secret from the host to the app without the relay in between.

**It cannot change or replay a message.** Each sealed message is authenticated, and its nonce is a counter. A changed, repeated, dropped, or reordered message fails to open, and the connection ends.

These five properties are tested. `internal/session/session_test.go` and `internal/secure/vectors_test.go` check from the host's side that a wrong code, a wrong host key, an unknown device key, and a tampered message are refused. `Tests/TetrixHostKitTests` checks the same from the app's side.

## What the relay can see

A sealed tunnel still has an outside. The relay, and anyone who watches the network next to it, can see:

- The host ID a client asks for, and the network addresses of the client and the host.
- When a host is online, and when each client connects and disconnects.
- When messages pass, how many, and roughly how large they are.
- The 4-byte hint that names a pairing code, and the category of a refusal, such as "unknown device".

So the relay knows that some device used some host at 9:14 and received an answer of about four hundred tokens. It does not know what was asked.

### Sizes and timing

A model streams its answer one token at a time. If each token travelled in a message of its own exact size, the sizes alone would give away the length of every token, and published attacks rebuild much of an answer from that. Tetrix Host pads every frame to a multiple of 512 bytes before it seals it. A message that carries a token is the same size whatever the token is.

Padding does not hide timing or count. The number of messages still follows the number of tokens, and a pause still shows. Closing that gap would mean sending at a constant rate whether or not there is anything to say, and the cost in speed and battery is not worth it for this product. If your threat is an observer who must not learn even how long an answer was, run the host and its relay on a network you control.

## What happens when a key is stolen

| If someone steals | They can | They cannot |
|-------------------|----------|-------------|
| A device's pairing, from its Keychain | Use the host as that device until the owner unpairs it | Read that device's past sessions. Use another device's pairing |
| The host's `identity.json` | Impersonate the host to its paired devices. Take over its place on the relay | Read past sessions, which used keys that no longer exist |
| A pairing code, while it is open | Pair one device. The owner sees it appear in the device list | Use it twice, or after 10 minutes |
| The admin token | Do anything the owner can do through the local API | Reach the host from another machine. The API listens on loopback only |

Session keys come from one-time keys that both sides discard, so a stolen long-term key does not open a recorded session. One exception is small and deliberate: the first message of a session carries the app's name and version sealed to the host's static key only, so a thief with that key could read those two fields from a recording.

Unpairing takes effect at once. The host deletes the device's key and closes every session the device has open.

## The local API

The host serves an HTTP API on `127.0.0.1` for the Mac app, the CLI, and local programs. Every route except a health check needs a bearer token.

A web page in a browser on the same machine can send requests to a loopback port. It cannot read the token files, so its requests get `401`. This is why the model routes need a key even on loopback, unlike some local model servers.

The CLI and the Mac app find the host through `daemon.json`, which names a port. If the host died without removing that file, some other program could take the port and wait to be handed the admin token. So a client first sends a random challenge to the health check and expects an HMAC of it under the token. Only a listener that already holds the token can answer, and only then does the client send it.

Two tokens exist so that a local program does not hold more power than it needs. The API key opens the model routes. Only the admin token can pair a device, change a model, or read the device list.

A paired device cannot reach the admin routes at all. The tunnel is mounted on a separate handler that has only the model routes.

## What the host records

The host counts requests and tokens per device and keeps the last 40 request records in memory. A record holds the time, the device, the role, the model, the status, the duration, and the token counts. The host does not write prompts or answers to its log, its statistics, or disk. The counts reset when the host restarts.

The engine is a separate program with its own behavior. Check what your engine logs.

## What this design does not protect against

- **A compromised host machine.** The host sees everything in the clear. Disk encryption and a locked screen matter more than anything on this page.
- **A compromised app.** An app that is paired can use the host. Pair only apps you trust, and unpair devices you no longer use.
- **A relay that refuses service.** The relay can drop a connection or go offline. It can also void an open pairing code by sending five bad attempts against a hint it has seen. Neither exposes data. Both stop work until you make a new code or point the host at another relay.
- **A relay that lies about why it closed a connection.** A close code is not sealed. The client package therefore never reports a device as unpaired because of a code. It reports that only when the host says so inside the sealed handshake, so a relay cannot talk an app into dropping its pairing.
- **A flood from someone who knows a host ID.** A host ID is not a secret, and anyone who has one can open connections to that host through the relay. The relay limits what one network address can take of a host's budget, the host drops a connection that does not complete a handshake within 15 seconds, and the host caps its own sessions. A flood from many addresses can still crowd a host's devices out for as long as it lasts. It cannot read or change anything.
- **Traffic analysis**, as described above.
- **Quantum computers.** The handshakes use X25519. A recording made today could be opened by a large quantum computer in the future. Noise has hybrid variants, and a later version of the protocol can adopt one.

## How to check these claims

The protocol is specified in [Wire protocol](../reference/protocol.md). The code that implements it is short:

| Part | Go | Swift |
|------|----|-------|
| Handshakes and sealed channel | `internal/secure/secure.go`, on top of `github.com/flynn/noise` | `Sources/TetrixHostKit/Noise.swift`, on top of CryptoKit |
| Pairing codes | `internal/pairing/pairing.go` | `Sources/TetrixHostKit/PairingOffer.swift` |
| Relay | `internal/relay/relay.go` | |
| Host session | `internal/session/session.go` | `Sources/TetrixHostKit/HostConnection.swift` |

The two Noise implementations are checked against each other. `go test ./internal/secure` writes a set of handshakes with fixed keys to `Tests/TetrixHostKitTests/Fixtures/noise-vectors.json`, and `swift test` reproduces every byte. `scripts/interop.sh` then runs the Swift client against the Go host through a real relay.

You do not have to trust Tetrix's relay. [Run your own](../how-to/run-your-own-relay.md) and point your host at it.
