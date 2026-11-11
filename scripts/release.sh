#!/bin/sh
# Publishes a release of the tetrix-host command.
#
#   scripts/release.sh <version>             Publish
#   scripts/release.sh <version> --dry-run   Stop before anything is published
#
# The script checks that main is clean and pushed, runs the tests, builds the
# archives, tags the commit, makes the GitHub release, and puts the formula in
# the Homebrew tap. A dry run does the local steps and prints the rest. It
# also turns a failed repository check into a warning, so that you can
# rehearse on a branch.
#
# TAP_REMOTE is the git address of the Homebrew tap. See scripts/tap.sh.

set -eu

usage="usage: scripts/release.sh <version> [--dry-run]"
version=${1:?$usage}
version=${version#v}
dry=no
case "${2:-}" in
	--dry-run) dry=yes ;;
	"") ;;
	*) echo "$usage" >&2; exit 1 ;;
esac
repo=Tetrix-Technologies/tetrix-host
tag=v$version

cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$*"; }

# A reason not to release. A dry run notes it and goes on.
stop() {
	if [ "$dry" = yes ]; then
		echo "warning: $*. A real release stops here."
	else
		echo "release: $*" >&2
		exit 1
	fi
}

step "Check the repository"
[ "$(git branch --show-current)" = main ] || stop "this is not the main branch"
[ -z "$(git status --porcelain)" ] || stop "there are changes that are not committed"
git fetch --quiet --tags origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || stop "this commit is not the tip of origin/main"
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then stop "the tag $tag exists already"; fi

step "Run the tests"
make test
scripts/test-install.sh

step "Build the archives"
scripts/dist.sh "$version"
scripts/formula.sh "$version" dist/release/checksums.txt >dist/tetrix-host.rb

if [ "$dry" = yes ]; then
	step "Dry run"
	cat <<EOF
Nothing was tagged or published. The archives are in dist/release and the
formula is in dist/tetrix-host.rb. A real release would now run:

  git tag -a $tag -m "Tetrix Host $version"
  git push origin $tag
  gh release create $tag --repo $repo --verify-tag --title "Tetrix Host $version" --generate-notes dist/release/* install.sh
  scripts/tap.sh $version dist/release/checksums.txt
EOF
	exit 0
fi

step "Tag and publish"
git tag -a "$tag" -m "Tetrix Host $version"
git push origin "$tag"
gh release create "$tag" --repo "$repo" --verify-tag --title "Tetrix Host $version" --generate-notes dist/release/* install.sh

step "Update the Homebrew tap"
scripts/tap.sh "$version" dist/release/checksums.txt

step "Check the downloads"
if curl --fail --silent --location --output /dev/null "https://github.com/$repo/releases/download/$tag/checksums.txt"; then
	echo "Anyone can download tetrix-host $version."
else
	echo "warning: the release exists, but a download without a login fails."
	echo "Homebrew and install.sh cannot install it until $repo is public."
fi
