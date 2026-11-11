# How to publish a release

A release has three parts: a tag, a GitHub release that holds the builds, and a formula in the Homebrew tap. `scripts/release.sh` makes all three.

## Before you start

You need:

- Push access to `Tetrix-Technologies/tetrix-host` and to the tap, `Tetrix-Technologies/homebrew-tap`.
- The `gh` command, signed in.
- Go 1.26 or later, and Xcode for the Swift tests.
- The `main` branch checked out, with nothing uncommitted and nothing unpushed.

## Rehearse

Run the release as a dry run first.

```sh
make release VERSION=0.1.0 DRY_RUN=1
```

A dry run runs the tests and builds the archives in `dist/release`. It writes the formula to `dist/tetrix-host.rb` and prints the commands that a real release would run. It tags nothing and publishes nothing. A dry run works on a branch, and warns about each check that would stop a real release.

To install the formula with Homebrew on your own machine, run the installer tests with `BREW=1`.

```sh
make install-test BREW=1
```

The test adds a tap named `tetrix-host-test/local`, installs from it, and removes both again. It stops if Homebrew already has `tetrix-host` installed.

## Publish

```sh
make release VERSION=0.1.0
```

The script does these steps in order and stops at the first one that fails.

1. It checks that `main` is clean, that it matches `origin/main`, and that the tag `v0.1.0` does not exist.
2. It runs `make test` and `scripts/test-install.sh`.
3. It builds the archives and `checksums.txt` with `scripts/dist.sh`.
4. It makes the tag `v0.1.0` and pushes it.
5. It makes the GitHub release, and uploads the archives, `checksums.txt`, and `install.sh`.
6. It writes `Formula/tetrix-host.rb` in the tap with `scripts/tap.sh`, and pushes the commit.
7. It downloads `checksums.txt` without a login, to check that the release is public.

## Recover from a failed step

If the script stops after it pushed the tag, do not run it again, because the tag now exists. Run the remaining commands by hand. A dry run prints them.

To write the formula again from the archives in `dist/release`, run the tap step on its own.

```sh
scripts/tap.sh 0.1.0 dist/release/checksums.txt
```

The step changes nothing if the tap already has that formula.

## What a release holds

| File | For |
|------|-----|
| `tetrix-host_darwin_arm64.tar.gz` | A Mac with Apple silicon |
| `tetrix-host_darwin_amd64.tar.gz` | A Mac with an Intel processor |
| `tetrix-host_linux_arm64.tar.gz` | Linux on 64-bit ARM |
| `tetrix-host_linux_amd64.tar.gz` | Linux on 64-bit Intel or AMD |
| `tetrix-host_windows_arm64.zip` | Windows on ARM |
| `tetrix-host_windows_amd64.zip` | Windows on 64-bit Intel or AMD |
| `checksums.txt` | The SHA-256 of each archive |
| `install.sh` | The install script |

An archive name carries no version. The address `releases/latest/download/<file>` then always names the newest build, which is how `install.sh` finds it.

The Mac builds are not signed with a Developer ID and not notarized. Homebrew and `install.sh` install them without a warning, because neither marks a download as quarantined. macOS blocks a build that someone downloaded in a browser, until they allow it in System Settings.
