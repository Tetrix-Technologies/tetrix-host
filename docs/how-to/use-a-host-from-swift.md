# How to use a host from a Swift app

Add `TetrixHostKit` to an app to pair with a host and send model requests to it. The package needs iOS 17, macOS 14, or visionOS 1, and depends on Foundation and CryptoKit only.

## Add the package

In `Package.swift`:

```swift
dependencies: [
	.package(url: "https://github.com/Tetrix-Technologies/tetrix-host", from: "0.1.0"),
],
targets: [
	.target(name: "MyApp", dependencies: [
		.product(name: "TetrixHostKit", package: "tetrix-host"),
	]),
]
```

Until the repository is published, add it by path: `.package(path: "../tetrix-host")`.

## Pair

Take the code or link from the person, as text from a paste or a QR scan. Describe the device the way its owner should see it in the host's device list.

```swift
import TetrixHostKit

let device = DeviceInfo(name: "Noah's MacBook Pro", app: "Cue", appVersion: "1.2.0")
let paired = try await HostPairing.pair(code: pastedText, device: device)
try PairedHostStore().save(paired)
```

`PairingOffer.isValid(_:)` tells you whether a string is a pairing code, for example before you offer to pair with what is on the pasteboard.

To handle a `tetrix-host://pair/` link that the person opens, register the `tetrix-host` URL scheme and pass the URL's string to `HostPairing.pair`.

## Keep the pairing in the Keychain

A `PairedHost` holds the device's private key. `PairedHostStore` keeps it in the Keychain, for this device only. It uses the data protection keychain, which needs a signed app. A command-line tool or a unit test passes `dataProtection: false`.

```swift
let store = PairedHostStore()
let hosts = try store.all()
try store.remove(hostID: paired.hostID)
```

Do not put a `PairedHost` in `UserDefaults`, a file, or iCloud. A pairing belongs to one device.

## Send a request

Make one `HostClient` for each paired host and keep it. The client opens a connection on the first request and opens a new one if the old one drops.

For a plain conversation, use `chat`.

```swift
let client = HostClient(host: paired, device: device)

for try await delta in client.chat([.user("Summarise this in one line: ...")], role: .quick) {
	print(delta.content ?? "", terminator: "")
}
```

`role` is `.deep` for work that needs thought and `.quick` for short work. The host's owner decides which model serves each.

## Send tools, images, or your own request shape

The host's chat route takes the full OpenAI chat-completions body. Build the body yourself, set `"model"` to `"deep"` or `"quick"`, and read the event stream line by line.

```swift
let body = try JSONSerialization.data(withJSONObject: [
	"model": "deep",
	"stream": true,
	"messages": messages,
	"tools": tools,
])
for try await line in client.lines(for: .json("/v1/chat/completions", body: body)) {
	// Each line is one line of a text/event-stream body.
}
```

For an answer that is not streamed, use `data(for:)`, which returns the whole body.

## Check what the host can do

Ask before you depend on a capability.

```swift
let info = try await client.info()
let deep = info[.deep]

if deep?.can("tools") == false {
	// The host says the deep model cannot call tools.
}
if let window = deep?.usableContext {
	// Keep each request within this many tokens.
}
```

`can` returns `nil` when the host's engine does not say what a model can do. That is not a no. Send the request, and handle the error `tools_unsupported` or the engine's own.

`usableContext` is the window the model is running with when the host knows it, and the model's own limit otherwise. An engine cuts a longer request to fit and reports no error, so compare the prompt token count in the answer's usage with what you expected to send.

## Cancel a request, or set a deadline

Stop iterating the stream, or cancel the task that reads it. The client tells the host, and the model stops.

`data(for:timeout:)` limits the whole call. `lines(for:timeout:)` limits the wait for the answer to start, and a model can take a while to load, so allow for that. Both throw `HostError.timedOut`.

## Unpair

To end a pairing from the app, tell the host, then forget the pairing.

```swift
try? await client.unpair()
try PairedHostStore().remove(hostID: paired.hostID)
```

Remove the pairing even if `unpair` fails. If the host is offline, its owner can unpair the device there.

## Handle errors

Every call throws `HostError`. Each case has a `localizedDescription` that is safe to show.

| Error | Meaning | Do this |
|-------|---------|---------|
| `hostOffline` | The host is stopped, or its tunnel is down | Fall back, or tell the person |
| `deviceNotPaired` | The owner unpaired this device. The host says so inside the sealed handshake, so a relay cannot fake it | Remove the pairing and offer to pair again |
| `hostNotVerified` | The far side did not prove that it holds the host's key. Nothing was sent to it | Keep the pairing. A relay or a network fault can cause this. If it persists, offer to pair again |
| `relayUnreachable` | No network, or the relay is down | Retry later |
| `connectionLost` | The connection dropped, or the relay closed it | Retry the request |
| `requestRejected` | The host answered with an error status | Read `code`. `no_model_assigned` means the owner has not chosen a model |
| `pairingRefused` | The code is wrong, used, or expired | Ask for a new code |

## Test without a host

`HostClient`, `HostConnection`, and `HostPairing` take a `HostSocketOpener`. Pass your own to run the client against an in-memory host in tests. `Tests/TetrixHostKitTests/TestHost.swift` in this repository is a working example.
