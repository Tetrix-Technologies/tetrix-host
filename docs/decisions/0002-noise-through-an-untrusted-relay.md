# 2. Seal traffic with Noise and treat the relay as untrusted

Status: accepted, 2026-11-11

## Context

A host sits behind a home or office router. The product must work without a static address, a forwarded port, or a VPN. The person's prompts and answers must not be readable by Tetrix.

## Decision

A host dials out to a relay and keeps a WebSocket open. An app dials the same relay and names the host. The relay copies messages between them.

The app and the host seal everything with the Noise Protocol Framework, using X25519, ChaCha20-Poly1305, and SHA-256. A session uses the IK pattern, with the host's static key pinned by the app at pairing. The relay is given no key and no role in the handshake.

The host proves its ID to the relay by signing a challenge with a separate Ed25519 key, so that no one else can take its place on the relay.

Every frame is padded to a multiple of 512 bytes before it is sealed, so that the size of a message does not give away the length of a streamed token.

## Alternatives

TLS from the app to the relay and from the relay to the host is what most tunnels do. The relay then sees everything, which is the one thing this product must not allow.

A mesh VPN such as WireGuard or Tailscale gives a direct, sealed path. It needs a network extension on iOS and a second account for the person, and one app cannot bring up a tunnel for another.

WebRTC data channels give a direct path with sealed transport. They need STUN and TURN servers, which is a relay again with more moving parts.

A custom handshake was never an option. Noise is specified, analysed, and has test vectors, and both languages have what it needs.

## Consequences

- No account, no port forwarding, and no VPN. A host works from behind any router that allows outbound HTTPS.
- All traffic passes through the relay, which costs a round trip and bandwidth. A direct path on a shared network can be added later without a change to the sealed channel.
- The relay sees who talks to whom, when, and roughly how much. [Security model](../explanation/security.md) states this in full.
- The relay is small and stateless, and anyone can run one.
