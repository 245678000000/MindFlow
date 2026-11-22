#!/bin/zsh
# Usage: scripts/release.sh 1.1.0 "更新说明（Markdown）"
set -e
cd "$(dirname "$0")/.."
VERSION=${1:?version required}
NOTES=${2:-""}
echo "$VERSION" > VERSION
./build.sh universal
ZIP="build/MindFlow-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/MindFlow.app "$ZIP"
git add VERSION && git commit -m "Release $VERSION" >/dev/null 2>&1 || true
git tag -f "v$VERSION" && git push origin HEAD --tags -f
gh release create "v$VERSION" "$ZIP" --title "MindFlow $VERSION" --notes "$NOTES"
