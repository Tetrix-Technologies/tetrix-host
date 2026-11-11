# How to run the host in the background

`tetrix-host serve` runs until you close the terminal. To keep a host up, install it as a background service of your user account. No administrator rights are needed.

## Install the service

Put the `tetrix-host` binary where it will stay, for example `/usr/local/bin`. The service runs the binary from the path it had when you installed the service.

```sh
tetrix-host service install
```

The command starts the host and prints its address. The host now starts each time you log in, and restarts if it stops.

| Platform | Service | Log |
|----------|---------|-----|
| macOS | The LaunchAgent `tech.tetrix.host` | `~/Library/Application Support/Tetrix Host/host.log` |
| Linux | The systemd user unit `tetrix-host.service` | `journalctl --user -u tetrix-host` |

On Linux, a user service stops when you log out. To keep the host up on a server, turn on lingering for your account.

```sh
loginctl enable-linger
```

## Check the service

```sh
tetrix-host service status
tetrix-host status
```

## Remove the service

```sh
tetrix-host service uninstall
```

The host stops. Paired devices, models, and settings are kept.

## Keep a Mac awake

A Mac that sleeps cannot answer. In System Settings, open **Energy** and turn on **Prevent automatic sleeping when the display is off**. On a laptop, the host answers only while the lid is open or the laptop is plugged in and connected to a display.
