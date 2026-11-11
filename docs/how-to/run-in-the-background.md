# How to run the host in the background

`tetrix-host serve` runs until you close the terminal. To keep a host up, install it as a background service of your user account. No administrator rights are needed.

## Install the service

[Install the command](install.md) first. The service runs the command from the place it is installed, so a copy in a build directory stops when you delete the directory.

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

## Restart the host after an upgrade

An upgrade replaces the command, but the running host stays on the old version. To restart it on the new version, install the service again.

```sh
tetrix-host service install
```

## Remove the service

```sh
tetrix-host service uninstall
```

The host stops. Paired devices, models, and settings are kept.

## Keep a Mac awake

A Mac that sleeps cannot answer. In System Settings, open **Energy** and turn on **Prevent automatic sleeping when the display is off**. On a laptop, the host answers only while the lid is open or the laptop is plugged in and connected to a display.
