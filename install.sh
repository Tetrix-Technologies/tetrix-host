#!/bin/sh
# Installs the tetrix-host command on macOS or Linux.
#
#   curl -fsSL https://github.com/Tetrix-Technologies/tetrix-host/releases/latest/download/install.sh | sh
#
# The script downloads the build for this machine from the project's
# releases, checks the download against the release's checksums.txt, and puts
# one file, tetrix-host, in a directory on your PATH. It changes nothing else.
#
# Variables:
#   TETRIX_HOST_VERSION    The version to install, such as 0.1.0.
#                          Default: the latest release.
#   TETRIX_HOST_BIN_DIR    The directory for the command.
#                          Default: /usr/local/bin. If that needs administrator
#                          rights and there is no way to ask for them,
#                          ~/.local/bin.
#   TETRIX_HOST_RELEASES   Where the releases are, for a mirror.
#                          Default: the project's releases on GitHub.
#
# To install a build you already have, pass it: sh install.sh --binary <file>

set -eu

SYSTEM_DIR=/usr/local/bin
RELEASES_DEFAULT=https://github.com/Tetrix-Technologies/tetrix-host/releases
NAME=tetrix-host

say() { printf '%s\n' "$*"; }
fail() { printf 'install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<EOF
Installs the $NAME command on macOS or Linux.

  sh install.sh                    Install the latest release
  sh install.sh --binary <file>    Install a build you already have

Variables:
  TETRIX_HOST_VERSION    The version to install, such as 0.1.0
  TETRIX_HOST_BIN_DIR    The directory for the command. Default: $SYSTEM_DIR
  TETRIX_HOST_RELEASES   Where the releases are. Default: $RELEASES_DEFAULT
EOF
}

# The directory with every link in its path followed, to compare two paths.
real_dir() {
	(cd "$1" 2>/dev/null && pwd -P)
}

detect_os() {
	case "$(uname -s)" in
		Darwin) echo darwin ;;
		Linux) echo linux ;;
		*) fail "there is no build for $(uname -s). Builds exist for macOS, Linux, and Windows. On Windows, download the zip file from $RELEASES_DEFAULT" ;;
	esac
}

detect_arch() {
	machine=$(uname -m)
	# A shell that runs under Rosetta reports x86_64 on Apple silicon.
	if [ "$1" = darwin ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
		machine=arm64
	fi
	case "$machine" in
		x86_64 | amd64) echo amd64 ;;
		arm64 | aarch64) echo arm64 ;;
		*) fail "there is no build for the $machine processor. Builds exist for 64-bit Intel, AMD, and ARM" ;;
	esac
}

fetch() {
	if have curl; then
		curl --fail --silent --show-error --location --retry 2 --output "$2" "$1"
	elif have wget; then
		wget --quiet --output-document "$2" "$1"
	else
		fail "this script needs curl or wget"
	fi
}

sha256() {
	if have sha256sum; then
		sha256sum "$1" | cut -d ' ' -f 1
	elif have shasum; then
		shasum -a 256 "$1" | cut -d ' ' -f 1
	elif have openssl; then
		openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1
	else
		fail "this script needs sha256sum, shasum, or openssl to check the download"
	fi
}

# True if a file can be made in the directory without more rights. The
# directory may not exist yet, so the test is on its nearest parent that does.
writable() {
	# sh has no local variables, so this name must differ from the caller's.
	probe=$1
	while [ ! -e "$probe" ]; do
		probe=$(dirname "$probe")
	done
	[ -d "$probe" ] && [ -w "$probe" ]
}

# True if sudo can run now: either it needs no password, or there is a
# terminal for it to ask on. Under "curl | sh" the terminal is not stdin.
can_sudo() {
	have sudo || return 1
	sudo -n true 2>/dev/null && return 0
	(: </dev/tty) 2>/dev/null
}

download() {
	os=$(detect_os)
	arch=$(detect_arch "$os")
	asset=${NAME}_${os}_${arch}.tar.gz
	releases=${TETRIX_HOST_RELEASES:-$RELEASES_DEFAULT}
	releases=${releases%/}
	version=${TETRIX_HOST_VERSION:-latest}
	if [ "$version" = latest ]; then
		from=$releases/latest/download
	else
		from=$releases/download/v${version#v}
	fi

	have tar || fail "this script needs tar"
	say "Downloading $NAME for $os on $arch."
	fetch "$from/$asset" "$work/$asset" ||
		fail "could not download $from/$asset. Check the connection and that the version exists"
	fetch "$from/checksums.txt" "$work/checksums.txt" ||
		fail "could not download $from/checksums.txt"

	want=$(awk -v file="$asset" '$2 == file || $2 == "*" file { print $1 }' "$work/checksums.txt")
	[ -n "$want" ] || fail "checksums.txt does not list $asset"
	got=$(sha256 "$work/$asset")
	[ "$got" = "$want" ] ||
		fail "the download does not match its checksum, so nothing was installed. Expected $want and got $got"

	tar -xzf "$work/$asset" -C "$work" "$NAME" || fail "could not unpack $asset"
	binary=$work/$NAME
}

main() {
	binary=
	while [ $# -gt 0 ]; do
		case "$1" in
			--binary)
				[ $# -ge 2 ] || fail "--binary needs a file"
				binary=$2
				shift 2
				;;
			-h | --help)
				usage
				exit 0
				;;
			*) fail "unknown option $1" ;;
		esac
	done

	# Homebrew keeps its own copy up to date. A second copy would hide it or
	# be hidden by it, depending on the PATH.
	existing=$(command -v "$NAME" 2>/dev/null || true)
	if [ -z "${TETRIX_HOST_BIN_DIR:-}" ] && [ -n "$existing" ]; then
		case "$(readlink "$existing" 2>/dev/null || true)" in
			*/Cellar/*) fail "Homebrew manages the copy at $existing. Run \"brew upgrade $NAME\" instead" ;;
		esac
	fi

	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	if [ -n "$binary" ]; then
		[ -f "$binary" ] || fail "there is no file at $binary"
	else
		download
	fi

	dir=${TETRIX_HOST_BIN_DIR:-$SYSTEM_DIR}
	[ "$dir" = / ] || dir=${dir%/}
	as=
	if ! writable "$dir"; then
		if can_sudo; then
			as=sudo
			say "$dir needs administrator rights, so sudo may ask for your password."
			say "To install without them, press Ctrl-C and set TETRIX_HOST_BIN_DIR to a directory of your own."
		elif [ -z "${TETRIX_HOST_BIN_DIR:-}" ]; then
			dir=$HOME/.local/bin
		else
			fail "cannot write to $dir"
		fi
	fi

	target=$dir/$NAME
	upgrade=no
	[ -e "$target" ] && upgrade=yes

	# Copy next to the target and rename, so that a running host keeps the
	# file it started from and nothing ever sees half a file.
	$as mkdir -p "$dir" || fail "could not make $dir"
	$as cp "$binary" "$dir/.$NAME.new" || fail "could not write to $dir"
	$as chmod 755 "$dir/.$NAME.new"
	$as mv -f "$dir/.$NAME.new" "$target"

	installed=$("$target" version 2>/dev/null) || installed=$NAME
	say ""
	say "$installed is installed at $target."

	found=$(command -v "$NAME" 2>/dev/null || true)
	if [ -z "$found" ]; then
		say ""
		say "$dir is not on your PATH. Add it, then open a new terminal:"
		case "$(basename "${SHELL:-sh}")" in
			zsh) say "  echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zshrc" ;;
			bash) say "  echo 'export PATH=\"$dir:\$PATH\"' >> ~/.bashrc" ;;
			fish) say "  fish_add_path $dir" ;;
			*) say "  export PATH=\"$dir:\$PATH\"" ;;
		esac
	elif [ "$(real_dir "$(dirname "$found")")" != "$(real_dir "$dir")" ]; then
		say ""
		say "Another copy at $found comes first on your PATH. Remove it, or it runs in place of this one."
	fi

	say ""
	if [ "$upgrade" = yes ]; then
		say "If the host runs in the background, restart it on this version:"
		say "  $NAME service install"
	else
		say "Next:"
		say "  $NAME service install    Run the host in the background, from login"
		say "  $NAME doctor             Check every part and say what is wrong"
	fi
}

# The call is on the last line so that a download cut short runs nothing.
main "$@"
