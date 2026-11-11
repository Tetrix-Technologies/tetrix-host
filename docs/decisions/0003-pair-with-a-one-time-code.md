# 3. Pair with a one-time code shown by the host

Status: accepted, 2026-11-11

## Context

An app and a host must learn each other's public keys the first time they meet. Their only network path runs through the relay, which must not be able to insert itself.

## Decision

The host shows a pairing code as a QR image and as a link. The code holds the host ID and a 128-bit random secret. The person carries it to the app by scanning or pasting.

Both sides run Noise XXpsk0 with a key derived from the secret. The handshake completes only between two parties that hold the code, and each learns the other's static key from it. The host then lists the app's key as a paired device.

A code works once, expires after 10 minutes, and is voided after 5 failed attempts. A host has one open code at a time.

## Alternatives

A short code that the person types, six or eight digits, is friendlier. A short code cannot be used directly as a Noise pre-shared key, because anyone who records the handshake could try every code offline. It needs a password-authenticated key exchange such as SPAKE2 or CPace. CryptoKit has no such primitive, and writing one by hand in two languages is how protocols get broken.

Comparing a short number on both screens after an unauthenticated handshake is sound when people compare. People often do not.

An account, where the host and the app both sign in to Tetrix, would make pairing automatic. It would also make Tetrix the party that decides which keys to trust, which gives Tetrix the power to add a device.

## Consequences

- The relay and Tetrix cannot pair a device with a host.
- The code is 44 characters, too long to type. Pairing is by scan or paste. A short typed code can be added later as a second method if a vetted PAKE becomes available on both sides.
- Anyone who obtains an open code can pair one device. The host shows each new device, and its owner can unpair it at once.
- A pairing is per device and per app. It does not move with an iCloud account, by design.
