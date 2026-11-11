# How to pair an app

Pair an app once on each device. After that the app reaches the host on its own, from any network.

The host must be running with its tunnel connected. Check with `tetrix-host status`.

## Pair from the terminal

1. On the host's machine, run:

	```sh
	tetrix-host pair
	```

	The command prints a QR code and a link that starts with `tetrix-host://pair/`.

2. In the app, open its host settings and choose to pair. Scan the QR code with a phone, or paste the link on a Mac.

3. Wait for the terminal to print `Paired.` with the app's name and the device's name.

The code works once and expires after 10 minutes. If it expires, run `tetrix-host pair` again.

## Pair from the Mac app

1. In Tetrix Host, click **Pair a device** in the toolbar.
2. Scan the code with the app, or click **Copy** and paste the link into the app.
3. Wait for the sheet to say that the device is paired.

If you close the sheet before a device pairs, the code stops working.

## Send the link to another person

To pair a device you cannot reach, send its owner the link. Anyone who has the link can pair one device while the code is open, so send it over a channel you trust, and check the device list afterward.

```sh
tetrix-host devices
```

## Unpair a device

To unpair from the terminal, name the device.

```sh
tetrix-host devices rm "Noah's MacBook Pro"
```

In the Mac app, select the device's card and click **Unpair**.

The device loses access at once, even if it has a request in progress. To use the host again, the device must pair again.

## If pairing fails

| The app says | Cause | Do this |
|--------------|-------|---------|
| The host did not accept that code | The code was used, expired, or cancelled | Make a new code |
| The host is offline | The host is stopped, or its tunnel is not connected | Run `tetrix-host status` on the host's machine |
| The relay is not answering | The device has no network, or the relay is down | Check the device's connection. Run `tetrix-host doctor` on the host |
