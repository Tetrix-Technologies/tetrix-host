# 1. Go for the host and relay, Swift for the client and app

Status: accepted, 2026-11-11

## Context

Tetrix Host has four pieces of code: the host that runs on a person's machine, the relay, the package apps use to reach a host, and a Mac app. Tetrix writes its apps in Swift.

The host must run wherever a person has hardware worth using. That includes Macs, Linux servers with graphics cards, and Windows PCs. It is a long-running network program: an HTTP server, an outbound WebSocket, a reverse proxy for streamed responses.

The client package ships inside Cue and other apps on macOS and iOS, where every dependency adds build time and review surface.

## Decision

The host, the CLI, and the relay are one Go module that builds one binary, `tetrix-host`. The client package, `TetrixHostKit`, and the Mac app are Swift. `TetrixHostKit` depends on Foundation and CryptoKit only.

## Alternatives

Swift everywhere would share one implementation of the protocol. It runs on Linux through SwiftNIO and swift-crypto, but not usefully on Windows, and it would pull a server framework into a repo whose client package must stay dependency-free.

Rust with generated Swift bindings would share one implementation on every platform. It would add a second toolchain to every app build and an XCFramework to maintain, for a team that writes no Rust.

## Consequences

- One `go build` produces a static binary for each platform. The repository cross-compiles for Linux and Windows today.
- The protocol is implemented twice. The repository treats this as a check: Go writes handshake vectors that the Swift tests must reproduce byte for byte, and `scripts/interop.sh` runs the Swift client against the Go host.
- A protocol change touches `internal/wire`, `Sources/TetrixHostKit/Wire.swift`, and `docs/reference/protocol.md` together.
- The Mac app does not link the host. It starts the `tetrix-host` binary and talks to it over loopback, the same way the CLI does.
