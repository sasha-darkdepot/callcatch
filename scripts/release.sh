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
#   4. roll CHANGELOG  [Unreleased] + changelog.d/*.md -> [X.Y.Z] — <today>
#      (+ fresh empty [Unreleased]; the folded fragments are deleted)
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
# --porcelain с untracked: неотслеженный Swift-файл собрался бы в бинарь,
# но не попал бы в тег — релиз лгал бы о своём содержимом (ревью-финдинг).
[ -z "$(git status --porcelain --untracked-files=all)" ] \
    || { echo "error: working tree is dirty or has untracked files — commit or stash first"; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 \
    && { echo "error: tag $TAG already exists"; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || { echo "error: local main is not in sync with origin/main"; exit 1; }
grep -q '^## \[Unreleased\]' CHANGELOG.md \
    || { echo "error: no '## [Unreleased]' section in CHANGELOG.md"; exit 1; }
# Пер-задачные заметки: параллельные ветки пишут changelog.d/<ISSUE-KEY>.md
# вместо общего CHANGELOG.md (mono landing.serialPaths), релиз их сворачивает.
for f in changelog.d/*.md; do
    [ -e "$f" ] || continue
    basename "$f" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+\.md$' \
        || { echo "error: changelog fragment $f is not named <ISSUE-KEY>.md"; exit 1; }
    grep -q '[^[:space:]]' "$f" \
        || { echo "error: changelog fragment $f is empty"; exit 1; }
done

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

# Сборочный гейт ДО тега и пуша: упавшая сборка/подпись не должна оставлять
# опубликованный тег без установленного релиза (ревью-финдинг, два ревьюера).
echo "==> build gate (pre-tag)"
MARKETING_VERSION="$VERSION" bash scripts/build-app.sh >/dev/null

# --- roll the changelog ---------------------------------------------------
DATE="$(date +%Y-%m-%d)"
# Ключ по возрастанию номера (CALL-9 раньше CALL-10); имена проверены выше.
FRAGMENTS="$(find changelog.d -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort -t- -k1,1 -k2,2n || true)"
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
for f in $FRAGMENTS; do
    cat "$f" >> "$NOTES"
    [ -z "$(tail -c1 "$f")" ] || echo >> "$NOTES"
done
echo "==> rolling CHANGELOG: [Unreleased] + $(echo "$FRAGMENTS" | grep -c . || true) fragment(s) -> [$VERSION]"
# Фрагменты встают первыми в секцию версии, за ними — то, что было записано
# прямо под [Unreleased]; legacy-заглушка «_Nothing yet._» выбрасывается,
# подряд идущие пустые строки внутри секции схлопываются.
awk -v ver="$VERSION" -v date="$DATE" -v notes="$NOTES" '
    function out(s) { if (s == "" && last == "") return; print s; last = s }
    /^## \[Unreleased\]/ && !done {
        out("## [Unreleased]"); out("")
        out("## [" ver "] — " date); out("")
        while ((getline line < notes) > 0) out(line)
        out("")
        inside = 1; done = 1; next
    }
    inside && /^## \[/ { inside = 0 }
    inside && /^_Nothing yet\._$/ { next }
    inside { out($0); next }
    { print; last = $0 }
' CHANGELOG.md > CHANGELOG.tmp && mv CHANGELOG.tmp CHANGELOG.md

# --- commit, tag, push ----------------------------------------------------
echo "==> commit + tag $TAG"
git add CHANGELOG.md
# shellcheck disable=SC2086 — имена фрагментов без пробелов (проверены выше)
[ -z "$FRAGMENTS" ] || git rm -q $FRAGMENTS
git commit -q -m "release: $VERSION"
git tag -a "$TAG" -m "$VERSION"
git push -q origin main
git push -q origin "$TAG"

# --- build the stamped version --------------------------------------------
echo "==> building & installing $VERSION"
INSTALL=1 bash scripts/build-app.sh

echo "==> released $TAG"
