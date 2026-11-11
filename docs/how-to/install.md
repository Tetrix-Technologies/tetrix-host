# How to install Tetrix Host

The host is one command, `tetrix-host`. Homebrew and the install script both put it on your `PATH`, so you can run it from any directory.

No release is published yet. Until the first release, [install from a checkout](#install-from-a-checkout).

## Install with Homebrew

On a Mac, or on Linux with Homebrew, run one command.

```sh
brew install tetrix-technologies/tap/tetrix-host
```

Homebrew downloads the build for your machine. It compiles nothing and needs no Go.

## Install with the script

On macOS or Linux without Homebrew, run the install script.

```sh
curl -fsSL https://github.com/Tetrix-Technologies/tetrix-host/releases/latest/download/install.sh | sh
```

The script downloads the build for your machine and checks it against the release's `checksums.txt`. It then puts `tetrix-host` in `/usr/local/bin`. If that directory needs administrator rights, `sudo` asks for your password.

To install without administrator rights, name a directory of your own.

```sh
curl -fsSL https://github.com/Tetrix-Technologies/tetrix-host/releases/latest/download/install.sh | TETRIX_HOST_BIN_DIR="$HOME/.local/bin" sh
```

If the directory is not on your `PATH`, the script prints the line that adds it.

To install one version, set `TETRIX_HOST_VERSION`, for example `TETRIX_HOST_VERSION=0.1.0`.

To read the script before you run it, open [`install.sh`](https://github.com/Tetrix-Technologies/tetrix-host/blob/main/install.sh). The script changes one file, the command itself.

## Install on Windows

1. Open the [releases page](https://github.com/Tetrix-Technologies/tetrix-host/releases).
2. Download `tetrix-host_windows_amd64.zip`. On a PC with an ARM processor, download `tetrix-host_windows_arm64.zip`.
3. Unpack the zip file, and move `tetrix-host.exe` to a directory on your `PATH`.

## Install from a checkout

You need [Go](https://go.dev/dl/) 1.26 or later.

```sh
git clone https://github.com/Tetrix-Technologies/tetrix-host.git
cd tetrix-host
make install
```

`make install` builds the command and installs it the way the script does. Set `TETRIX_HOST_BIN_DIR` to choose the directory.

## Check the install

```sh
tetrix-host version
```

The command prints its name and version. Next, [run your first host](../tutorial/run-your-first-host.md), or [run the host in the background](run-in-the-background.md).

## Upgrade

| Installed with | Run |
|----------------|-----|
| Homebrew | `brew upgrade tetrix-host` |
| The script | The script again |
| A checkout | `git pull`, then `make install` |

A host that runs in the background stays on the old version until it restarts. To restart it, install the service again.

```sh
tetrix-host service install
```

## Uninstall

1. If the host runs in the background, remove the service.

	```sh
	tetrix-host service uninstall
	```

2. Remove the command. With Homebrew, run `brew uninstall tetrix-host`. Otherwise, delete the file that `command -v tetrix-host` prints.
3. To remove the host's identity, pairings, and settings too, delete the [data directory](../reference/files.md#data-directory). Paired apps can no longer reach this host after that.
