#!/bin/sh
# Tests install.sh, and the Homebrew formula, against a release built here.
#
#   scripts/test-install.sh           Test install.sh
#   scripts/test-install.sh --brew    Also install the formula with Homebrew
#
# The release is served from a temporary directory with file:// addresses,
# so nothing is downloaded and nothing is published. install.sh runs with an
# empty environment and a PATH that holds only the tools it is allowed to
# need, so a new dependency fails here first.
#
# The install.sh tests change nothing outside the temporary directory. The
# --brew test adds a tap named tetrix-host-test/local to this machine's
# Homebrew, installs tetrix-host from it, and removes both again.

set -eu

brew_too=no
[ "${1:-}" = --brew ] && brew_too=yes

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
tap=tetrix-host-test/local
tapped=no

cleanup() {
	status=$?
	if [ "$tapped" = yes ]; then
		brew uninstall --force tetrix-host >/dev/null 2>&1 || true
		brew untap "$tap" >/dev/null 2>&1 || true
	fi
	chmod -R u+w "$tmp" 2>/dev/null || true
	rm -rf "$tmp"
	exit "$status"
}
trap cleanup EXIT

version=0.0.0-test
site=$tmp/site
echo "Building the test release."
scripts/dist.sh "$version" "$site/download/v$version" >/dev/null
mkdir -p "$site/latest"
cp -R "$site/download/v$version" "$site/latest/download"

case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; *) arch=arm64 ;; esac
if [ "$os" = darwin ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then arch=arm64; fi

# Everything install.sh may run, and nothing else.
tools=$tmp/tools
mkdir -p "$tools"
for tool in uname sysctl curl tar gzip awk cut mktemp dirname basename mkdir cp chmod mv rm cat readlink shasum sha256sum; do
	found=$(command -v "$tool" 2>/dev/null || true)
	[ -n "$found" ] && ln -s "$found" "$tools/$tool"
done

count=0
out=$tmp/out
shell=/bin/sh

ok() {
	count=$((count + 1))
	echo "ok    $1"
}

die() {
	echo "FAIL  $1" >&2
	[ -f "$out" ] && sed 's/^/      /' "$out" >&2
	exit 1
}

# install [NAME=value ...] runs install.sh in an empty environment. The
# output goes to $out. A later NAME=value replaces an earlier one.
install() {
	# shellcheck disable=SC2086
	env -i HOME="$tmp/home" SHELL=/bin/zsh PATH="$tools" \
		TETRIX_HOST_RELEASES="file://$site" SCRIPT=install.sh "$@" \
		$shell -c 'exec "$0" "$SCRIPT"' $shell >"$out" 2>&1
}

says() { grep -q -- "$1" "$out"; }

# The command file inside one of the built archives, to compare against.
built() {
	mkdir -p "$tmp/built/$1"
	tar -xzf "$site/download/v$version/tetrix-host_$1.tar.gz" -C "$tmp/built/$1"
	echo "$tmp/built/$1/tetrix-host"
}

# --- Each shell a system may have as sh ---------------------------------------

n=0
for candidate in /bin/sh /bin/dash /bin/ksh "/bin/bash --posix" "/bin/zsh --emulate sh"; do
	[ -x "${candidate%% *}" ] || continue
	n=$((n + 1))
	shell=$candidate
	install TETRIX_HOST_BIN_DIR="$tmp/shell$n" || die "install under $candidate"
	[ "$("$tmp/shell$n/tetrix-host" version)" = "tetrix-host $version" ] || die "version under $candidate"
	says "tetrix-host $version is installed at $tmp/shell$n/tetrix-host" || die "report under $candidate"
	says "service install" || die "next steps under $candidate"
	ok "installs the latest release under $candidate"
done
shell=/bin/sh

# --- Versions -----------------------------------------------------------------

install TETRIX_HOST_BIN_DIR="$tmp/pin" TETRIX_HOST_VERSION="$version" || die "pinned version"
[ "$("$tmp/pin/tetrix-host" version)" = "tetrix-host $version" ] || die "pinned version runs"
install TETRIX_HOST_BIN_DIR="$tmp/pinv" TETRIX_HOST_VERSION="v$version" || die "pinned version with v"
[ -x "$tmp/pinv/tetrix-host" ] || die "pinned version with v installs"
ok "installs a named version, with or without the v"

if install TETRIX_HOST_BIN_DIR="$tmp/missing" TETRIX_HOST_VERSION=9.9.9; then die "a missing version passed"; fi
says "could not download" || die "missing version message"
[ ! -e "$tmp/missing/tetrix-host" ] || die "a missing version installed something"
ok "fails on a version that does not exist"

# --- A bad download -----------------------------------------------------------

bad=$tmp/bad
cp -R "$site" "$bad"
printf x >>"$bad/latest/download/tetrix-host_${os}_$arch.tar.gz"
if install TETRIX_HOST_BIN_DIR="$tmp/corrupt" TETRIX_HOST_RELEASES="file://$bad"; then die "a changed archive passed"; fi
says "does not match its checksum" || die "checksum message"
[ ! -e "$tmp/corrupt/tetrix-host" ] || die "a changed archive installed something"
ok "refuses an archive that does not match its checksum"

grep -v "tetrix-host_${os}_$arch.tar.gz" "$site/latest/download/checksums.txt" >"$bad/latest/download/checksums.txt"
if install TETRIX_HOST_BIN_DIR="$tmp/unlisted" TETRIX_HOST_RELEASES="file://$bad"; then die "an unlisted archive passed"; fi
says "does not list" || die "unlisted message"
ok "refuses an archive that checksums.txt does not list"

# --- An upgrade ---------------------------------------------------------------

install TETRIX_HOST_BIN_DIR="$tmp/pin" || die "upgrade"
says "restart it on this version" || die "upgrade message"
ok "replaces an installed copy and says how to restart the host"

# --- Other machines -----------------------------------------------------------

# A uname that reports what the test asks for.
fake=$tmp/fake
mkdir -p "$fake"
cat >"$fake/uname" <<'EOF'
#!/bin/sh
case "$1" in
	-s) echo "$FAKE_OS" ;;
	-m) echo "$FAKE_MACHINE" ;;
esac
EOF
chmod +x "$fake/uname"

for pair in "aarch64 arm64" "x86_64 amd64"; do
	machine=${pair% *}
	want=${pair#* }
	install PATH="$fake:$tools" FAKE_OS=Linux FAKE_MACHINE="$machine" TETRIX_HOST_BIN_DIR="$tmp/linux-$want" || die "Linux on $machine"
	cmp -s "$tmp/linux-$want/tetrix-host" "$(built "linux_$want")" || die "Linux on $machine got another build"
done
ok "picks the Linux builds for aarch64 and x86_64"

if [ "$os" = darwin ] && [ "$arch" = arm64 ]; then
	install PATH="$fake:$tools" FAKE_OS=Darwin FAKE_MACHINE=x86_64 TETRIX_HOST_BIN_DIR="$tmp/rosetta" || die "Rosetta"
	cmp -s "$tmp/rosetta/tetrix-host" "$(built darwin_arm64)" || die "a Rosetta shell got the Intel build"
	ok "picks the Apple silicon build from a shell under Rosetta"
fi

if install PATH="$fake:$tools" FAKE_OS=FreeBSD FAKE_MACHINE=amd64 TETRIX_HOST_BIN_DIR="$tmp/bsd"; then die "FreeBSD passed"; fi
says "no build for FreeBSD" || die "unknown system message"
if install PATH="$fake:$tools" FAKE_OS=Linux FAKE_MACHINE=armv7l TETRIX_HOST_BIN_DIR="$tmp/arm32"; then die "armv7l passed"; fi
says "no build for the armv7l processor" || die "unknown processor message"
ok "fails with a reason on a system or processor that has no build"

# --- Where the command goes ---------------------------------------------------

# A copy of the script whose system directory is inside the temporary one.
system=$tmp/system
sed "s|^SYSTEM_DIR=.*|SYSTEM_DIR=$system|" install.sh >"$tmp/install-test.sh"
grep -q "^SYSTEM_DIR=$system\$" "$tmp/install-test.sh" || die "could not point the script at a test directory"

mkdir -p "$system"
install SCRIPT="$tmp/install-test.sh" PATH="$tools:$system" || die "default directory"
[ -x "$system/tetrix-host" ] || die "default directory is empty"
if says "not on your PATH" || says "Another copy"; then die "a clean install warned about the PATH"; fi
ok "installs to the system directory when it is writable"

rm -f "$system/tetrix-host"
chmod 555 "$system"
cat >"$fake/sudo" <<EOF
#!/bin/sh
# Stands in for sudo: notes the call, then runs it with the rights it needs.
echo "\$*" >>"$tmp/sudo.log"
[ "\$1" = -n ] && exit 0
chmod 755 "$system"
"\$@"
status=\$?
chmod 555 "$system"
exit \$status
EOF
chmod +x "$fake/sudo"
install SCRIPT="$tmp/install-test.sh" PATH="$fake:$tools:$system" FAKE_OS="$(uname -s)" FAKE_MACHINE="$(uname -m)" || die "sudo"
[ -x "$system/tetrix-host" ] || die "sudo did not install"
grep -q "mv -f" "$tmp/sudo.log" || die "sudo was not used"
says "administrator rights" || die "sudo notice"
ok "uses sudo when the system directory needs it"

chmod 755 "$system"
rm -f "$system/tetrix-host"
chmod 555 "$system"
install SCRIPT="$tmp/install-test.sh" || die "home directory"
[ -x "$tmp/home/.local/bin/tetrix-host" ] || die "home directory is empty"
says "$tmp/home/.local/bin is not on your PATH" || die "PATH notice"
says "zshrc" || die "PATH line for zsh"
ok "falls back to ~/.local/bin without sudo, and says how to add it to the PATH"

mkdir -p "$tmp/locked"
chmod 555 "$tmp/locked"
if install TETRIX_HOST_BIN_DIR="$tmp/locked"; then die "a locked directory passed"; fi
says "cannot write to $tmp/locked" || die "locked directory message"
ok "fails when the named directory cannot be written and there is no sudo"

# --- Other copies -------------------------------------------------------------

brewed=$tmp/brew
mkdir -p "$brewed/Cellar/tetrix-host/1/bin" "$brewed/bin"
cp "$tmp/pin/tetrix-host" "$brewed/Cellar/tetrix-host/1/bin/tetrix-host"
ln -s ../Cellar/tetrix-host/1/bin/tetrix-host "$brewed/bin/tetrix-host"
if install PATH="$tools:$brewed/bin"; then die "a Homebrew copy was replaced"; fi
says "brew upgrade tetrix-host" || die "Homebrew message"
ok "leaves a copy that Homebrew manages alone"

mkdir -p "$tmp/first"
cp "$tmp/pin/tetrix-host" "$tmp/first/tetrix-host"
install PATH="$tools:$tmp/first:$tmp/second" TETRIX_HOST_BIN_DIR="$tmp/second" || die "second copy"
says "Another copy at $tmp/first/tetrix-host comes first" || die "second copy message"
ok "warns when another copy comes first on the PATH"

# --- A build that is already here ---------------------------------------------

env -i HOME="$tmp/home" PATH="$tools" TETRIX_HOST_BIN_DIR="$tmp/local" \
	/bin/sh install.sh --binary "$(built "${os}_$arch")" >"$out" 2>&1 || die "--binary"
[ "$("$tmp/local/tetrix-host" version)" = "tetrix-host $version" ] || die "--binary runs"
ok "installs a build passed with --binary"

# --- The tap ------------------------------------------------------------------

sums=$site/download/v$version/checksums.txt
git init --quiet --bare "$tmp/tap.git"
TAP_REMOTE="$tmp/tap.git" scripts/tap.sh "$version" "$sums" >"$out" 2>&1 || die "tap.sh on an empty tap"
TAP_REMOTE="$tmp/tap.git" scripts/tap.sh "$version" "$sums" >"$out" 2>&1 || die "tap.sh a second time"
says "already has the formula" || die "tap.sh made a second commit for the same formula"
git clone --quiet "$tmp/tap.git" "$tmp/tap"
[ "$(git -C "$tmp/tap" rev-list --count HEAD)" = 1 ] || die "the tap does not have one commit"
scripts/formula.sh "$version" "$sums" | cmp -s - "$tmp/tap/Formula/tetrix-host.rb" || die "the tap's formula differs"
for build in darwin_arm64 darwin_amd64 linux_arm64 linux_amd64; do
	sum=$(awk -v file="tetrix-host_$build.tar.gz" '$2 == file { print $1 }' "$sums")
	grep -q "sha256 \"$sum\"" "$tmp/tap/Formula/tetrix-host.rb" || die "the formula lacks the checksum for $build"
done
ok "puts the formula in a tap, once, with the checksum of each build"

# --- Homebrew -----------------------------------------------------------------

if [ "$brew_too" = yes ]; then
	command -v brew >/dev/null || die "Homebrew is not installed"
	if brew list --formula tetrix-host >/dev/null 2>&1; then
		die "Homebrew already has tetrix-host installed, and this test would remove it"
	fi
	export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1
	rm -f "$out"
	tapped=yes
	brew tap-new --no-git "$tap" >"$out" 2>&1 || die "brew tap-new"
	formula=$(brew --repository "$tap")/Formula/tetrix-host.rb
	scripts/formula.sh "$version" "$site/download/v$version/checksums.txt" "file://$site/download/v$version" >"$formula"
	brew install "$tap/tetrix-host" >"$out" 2>&1 || die "brew install"
	[ "$("$(brew --prefix)/bin/tetrix-host" version)" = "tetrix-host $version" ] || die "the command Homebrew installed"
	says "tetrix-host service install" || die "the formula's caveats"
	ok "installs with Homebrew from the formula"
	brew test "$tap/tetrix-host" >"$out" 2>&1 || die "brew test"
	ok "passes the formula's own test"
	brew style "$tap/tetrix-host" >"$out" 2>&1 || die "brew style"
	ok "passes brew style"
	brew uninstall tetrix-host >"$out" 2>&1 || die "brew uninstall"
	[ ! -e "$(brew --prefix)/bin/tetrix-host" ] || die "brew uninstall left the command"
	brew untap "$tap" >"$out" 2>&1 || die "brew untap"
	tapped=no
	ok "uninstalls cleanly"
fi

echo "All $count checks passed."
