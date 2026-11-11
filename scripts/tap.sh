#!/bin/sh
# Puts the formula for one release in the Homebrew tap.
#
#   scripts/tap.sh <version> <checksums.txt>
#
# TAP_REMOTE is the git address of the tap. It defaults to the tap on GitHub.

set -eu

usage="usage: scripts/tap.sh <version> <checksums.txt>"
version=${1:?$usage}
version=${version#v}
sums=${2:?$usage}
remote=${TAP_REMOTE:-https://github.com/Tetrix-Technologies/homebrew-tap.git}

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

scripts/formula.sh "$version" "$sums" >"$work/tetrix-host.rb"
git clone --quiet --depth 1 "$remote" "$work/tap" 2>/dev/null ||
	{ echo "tap: could not clone $remote" >&2; exit 1; }
mkdir -p "$work/tap/Formula"
cp "$work/tetrix-host.rb" "$work/tap/Formula/tetrix-host.rb"

cd "$work/tap"
git add Formula/tetrix-host.rb
if git diff --cached --quiet; then
	echo "The tap already has the formula for tetrix-host $version."
	exit 0
fi
git commit --quiet -m "tetrix-host $version"
git push --quiet origin "HEAD:$(git symbolic-ref --short HEAD)"
echo "The tap has the formula for tetrix-host $version."
