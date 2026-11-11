#!/bin/sh
# Prints the Homebrew formula for one release.
#
#   scripts/formula.sh <version> <checksums.txt> [download address]
#
# The download address is the directory that holds the archives. It defaults
# to the release's directory on GitHub.
#
# The formula installs the archive's prebuilt command. It does not build from
# source, so "brew install" needs no Go and takes a few seconds.

set -eu

version=${1:?usage: scripts/formula.sh <version> <checksums.txt> [download address]}
version=${version#v}
sums=${2:?usage: scripts/formula.sh <version> <checksums.txt> [download address]}
base=${3:-https://github.com/Tetrix-Technologies/tetrix-host/releases/download/v$version}
base=${base%/}

sum() {
	found=$(awk -v file="tetrix-host_$1.tar.gz" '$2 == file { print $1 }' "$sums")
	[ -n "$found" ] || { echo "formula: $sums does not list tetrix-host_$1.tar.gz" >&2; exit 1; }
	echo "$found"
}

darwin_arm64=$(sum darwin_arm64)
darwin_amd64=$(sum darwin_amd64)
linux_arm64=$(sum linux_arm64)
linux_amd64=$(sum linux_amd64)

cat <<EOF
# Written by scripts/formula.sh in the tetrix-host repository. Do not edit.
class TetrixHost < Formula
  desc "Run the models behind your Tetrix apps on a machine you own"
  homepage "https://github.com/Tetrix-Technologies/tetrix-host"
  version "$version"

  on_macos do
    on_arm do
      url "$base/tetrix-host_darwin_arm64.tar.gz"
      sha256 "$darwin_arm64"
    end
    on_intel do
      url "$base/tetrix-host_darwin_amd64.tar.gz"
      sha256 "$darwin_amd64"
    end
  end

  on_linux do
    on_arm do
      url "$base/tetrix-host_linux_arm64.tar.gz"
      sha256 "$linux_arm64"
    end
    on_intel do
      url "$base/tetrix-host_linux_amd64.tar.gz"
      sha256 "$linux_amd64"
    end
  end

  def install
    bin.install "tetrix-host"
  end

  def caveats
    <<~EOS
      To run the host in the background, from login:
        tetrix-host service install

      After an upgrade, run that command again to restart the host on the
      new version.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/tetrix-host version")
  end
end
EOF
