#!/bin/sh
# Builds the release archives and checksums.txt.
#
#   scripts/dist.sh <version> [directory]
#
# The directory defaults to dist/release. Each archive holds one file, the
# tetrix-host command, and LICENSE once the repository has one. Archive names
# carry no version, so that the address
# .../releases/latest/download/<archive> always names the newest build.

set -eu

version=${1:?usage: scripts/dist.sh <version> [directory]}
version=${version#v}
case "$version" in
	[0-9]*.[0-9]*.[0-9]*) ;;
	*) echo "dist: \"$version\" is not a version such as 0.1.0" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."
out=${2:-dist/release}
mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -f "$out"/tetrix-host_* "$out/checksums.txt"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# macOS tar stores extended attributes as extra "._" files unless told not to.
export COPYFILE_DISABLE=1

for target in darwin/arm64 darwin/amd64 linux/arm64 linux/amd64 windows/arm64 windows/amd64; do
	os=${target%/*}
	arch=${target#*/}
	name=tetrix-host
	[ "$os" = windows ] && name=tetrix-host.exe
	dir=$stage/${os}_$arch
	mkdir -p "$dir"

	CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath \
		-ldflags "-s -w -X github.com/Tetrix-Technologies/tetrix-host/internal/brand.Version=$version" \
		-o "$dir/$name" ./cmd/tetrix-host
	[ -f LICENSE ] && cp LICENSE "$dir/"

	files=$(cd "$dir" && ls)
	if [ "$os" = windows ]; then
		(cd "$dir" && zip -q -X "$out/tetrix-host_${os}_$arch.zip" $files)
	else
		tar -C "$dir" -czf "$out/tetrix-host_${os}_$arch.tar.gz" $files
	fi
done

(cd "$out" && shasum -a 256 tetrix-host_* >checksums.txt)
echo "Built tetrix-host $version in $out:"
(cd "$out" && ls -1)
