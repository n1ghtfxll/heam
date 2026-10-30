#!/bin/sh
# Publishes a release that installed copies of heam pick up through Sparkle.
#
# Usage: scripts/release.sh notes.md
#   notes.md  release notes in Markdown; shown on GitHub and, as HTML, in the update window.
#
# Needs: gh (signed in), dmgbuild (see build.sh), and the Sparkle signing key in the login
# Keychain under the account "is.bored.heam" (created once with Sparkle's generate_keys).
# Lose that key and existing installs can never accept another update, so back it up:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account is.bored.heam -x heam-sparkle-key.txt
set -e
cd "$(dirname "$0")/.."

NOTES="$1"
[ -f "$NOTES" ] || { echo "usage: scripts/release.sh notes.md" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
REPO="n1ghtfxll/heam"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
DIST=build/dist

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists; bump CFBundleShortVersionString and CFBundleVersion first." >&2
  exit 1
fi

./build.sh --dmg
rm -rf "$DIST"
mkdir -p "$DIST"
cp "build/heam-$VERSION.dmg" "$DIST/"

# Start from the published feed so earlier versions keep their entries.
gh release download --repo "$REPO" --pattern appcast.xml --dir "$DIST" 2>/dev/null || true

# Notes next to the archive, same base name, are embedded in the feed for the update window.
{
  echo "<!doctype html><meta charset=\"utf-8\"><body style=\"font: 13px -apple-system, sans-serif\">"
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
      -e 's/\*\*\([^*]*\)\*\*/<b>\1<\/b>/g' \
      -e 's/^## \(.*\)/<h3>\1<\/h3>/' \
      -e 's/^- \(.*\)/<li>\1<\/li>/' \
      -e 's/^$/<br>/' "$NOTES"
  echo "</body>"
} > "$DIST/heam-$VERSION.html"

"$SPARKLE_BIN/generate_appcast" \
  --account is.bored.heam \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes \
  --maximum-deltas 0 \
  "$DIST"

gh release create "$TAG" --repo "$REPO" --title "heam $VERSION" --notes-file "$NOTES" \
  "$DIST/heam-$VERSION.dmg" "$DIST/appcast.xml"
echo "Released $TAG"
