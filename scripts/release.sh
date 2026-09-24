#!/bin/bash
# release.sh : cut a release of PowerEmu and let the running copies find it.
#
#   scripts/release.sh 0.2 2 "What changed, in plain words."
#
# Builds at that version, packs the app, attaches it to a GitHub release,
# and updates appcast.json -- which is what PowerEmu reads to know a newer
# build exists.  Nothing is pushed until the build and the packing have
# worked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${POWEREMU_REPO:-Spartan0285/PowerEmu}"

VERSION="${1:-}"
BUILD="${2:-}"
NOTES="${3:-}"
if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
    echo "usage: $0 VERSION BUILD [NOTES]      e.g. $0 0.2 2 \"Coherence mode\"" >&2
    exit 2
fi
case "$BUILD" in ''|*[!0-9]*) echo "BUILD must be a whole number" >&2; exit 2;; esac

command -v gh >/dev/null || { echo "needs the gh command line tool" >&2; exit 1; }

# The build number is what the updater compares, so it must be going up.
CURRENT=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/appcast.json" 2>/dev/null \
          | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("build",0))' 2>/dev/null || echo 0)
if [ "$BUILD" -le "$CURRENT" ]; then
    echo "build $BUILD is not newer than the published $CURRENT" >&2
    exit 1
fi

echo "== building $VERSION ($BUILD)"
POWEREMU_VERSION="$VERSION" POWEREMU_BUILD="$BUILD" sh "$ROOT/scripts/build-app.sh"

ZIP="$ROOT/build/PowerEmu-$VERSION.zip"
rm -f "$ZIP"
# ditto, not zip: a bundle's symlinks have to survive or its signature does not.
echo "== packing"
(cd "$ROOT/build" && ditto -c -k --keepParent PowerEmu.app "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

# Prove the thing being published is the thing that will be accepted: the
# updater refuses anything not signed by the same developer as the copy in
# use, so a release that fails this check would be rejected by every reader.
echo "== checking the signature survived packing"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
codesign --verify --deep --strict "$TMP/PowerEmu.app"
echo "   ok: $(codesign -dv "$TMP/PowerEmu.app" 2>&1 | sed -n 's/^TeamIdentifier=/team /p')"

URL="https://github.com/$REPO/releases/download/v$VERSION/PowerEmu-$VERSION.zip"
# The feed carries the release before it as well, so What's New has a
# changelog to show without a second file to keep up to date.
/usr/bin/python3 - "$ROOT/appcast.json" "$VERSION" "$BUILD" "$SHA" "$URL" "$NOTES" <<'PY'
import json, os, sys, datetime
path, version, build, sha, url, notes = sys.argv[1:7]
now = (datetime.datetime.now(datetime.timezone.utc)
       .replace(microsecond=0).isoformat().replace("+00:00", "Z"))

old = {}
if os.path.exists(path):
    try:
        old = json.load(open(path))
    except ValueError:
        old = {}

history = old.get("history", [])
if old.get("version"):
    history.insert(0, {"version": old["version"], "build": old.get("build", 0),
                       "published": old.get("published", ""),
                       "notes": old.get("notes", "")})
# Keep the last twenty: enough to read back through, small enough to fetch.
seen, trimmed = set(), []
for h in history:
    if h.get("build") in seen:
        continue
    seen.add(h.get("build"))
    trimmed.append(h)
history = trimmed[:20]

json.dump({
    "version": version,
    "build": int(build),
    "published": now,
    "minimumSystem": "14.0",
    "notes": notes,
    "url": url,
    "sha256": sha,
    "history": history,
}, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY

echo "== publishing"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" \
   --title "PowerEmu $VERSION" --notes "${NOTES:-PowerEmu $VERSION}"

git -C "$ROOT" add appcast.json
git -C "$ROOT" commit -m "PowerEmu $VERSION ($BUILD)"
git -C "$ROOT" push

echo
echo "Published $VERSION ($BUILD)."
echo "Copies already out there will offer it within a day; Check for Updates finds it now."
