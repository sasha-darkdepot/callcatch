#!/bin/bash
#
# Cut a release, the one and only way.
#
#   scripts/release.sh 0.3.0
#
# The principle: the git tag vX.Y.Z is the single source of truth for the
# version. This script is the only sanctioned path from "changes on main" to
# "a tagged, installed release" — so the version story can never drift.
#
# What it does (and refuses to do if any check fails):
#   1. validate the version is SemVer X.Y.Z and greater than the latest tag
#   2. require a clean `main` in sync with origin, tag not already used
#   3. run the full test suite
#   4. roll CHANGELOG  [Unreleased] -> [X.Y.Z] — <today>  (+ fresh [Unreleased])
#   5. commit, tag vX.Y.Z, push branch + tag
#   6. build & install the stamped version into /Applications
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh X.Y.Z"; exit 1; }
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || { echo "error: version must be SemVer X.Y.Z (got '$VERSION')"; exit 1; }
TAG="v$VERSION"

# --- guards ---------------------------------------------------------------
[ "$(git branch --show-current)" = "main" ] \
    || { echo "error: releases are cut from 'main'"; exit 1; }
git diff --quiet && git diff --cached --quiet \
    || { echo "error: working tree is dirty — commit or stash first"; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 \
    && { echo "error: tag $TAG already exists"; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || { echo "error: local main is not in sync with origin/main"; exit 1; }
grep -q '^## \[Unreleased\]' CHANGELOG.md \
    || { echo "error: no '## [Unreleased]' section in CHANGELOG.md"; exit 1; }

# new version must be strictly greater than the latest tag (sort -V)
LATEST="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if [ -n "$LATEST" ]; then
    GREATEST="$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -V | tail -1)"
    { [ "$VERSION" != "$LATEST" ] && [ "$GREATEST" = "$VERSION" ]; } \
        || { echo "error: $VERSION is not greater than latest tag v$LATEST"; exit 1; }
fi

# --- verify ---------------------------------------------------------------
echo "==> running tests"
swift test >/dev/null

# --- roll the changelog ---------------------------------------------------
echo "==> rolling CHANGELOG: [Unreleased] -> [$VERSION]"
DATE="$(date +%Y-%m-%d)"
awk -v ver="$VERSION" -v date="$DATE" '
    /^## \[Unreleased\]/ && !done {
        print "## [Unreleased]"; print ""; print "_Nothing yet._"; print "";
        print "## [" ver "] — " date;
        done = 1; next
    }
    { print }
' CHANGELOG.md > CHANGELOG.tmp && mv CHANGELOG.tmp CHANGELOG.md

# --- commit, tag, push ----------------------------------------------------
echo "==> commit + tag $TAG"
git add CHANGELOG.md
git commit -q -m "release: $VERSION"
git tag -a "$TAG" -m "$VERSION"
git push -q origin main
git push -q origin "$TAG"

# --- build the stamped version --------------------------------------------
echo "==> building & installing $VERSION"
INSTALL=1 bash scripts/build-app.sh

echo "==> released $TAG"
