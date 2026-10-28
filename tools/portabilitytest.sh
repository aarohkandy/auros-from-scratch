#!/bin/sh
# portabilitytest -- does any file outside docs/ still name the repository
# the project used to live in?
#
# The project moves between GitHub repositories (docs/MOVING.md). Outside
# docs/ nothing may hard-code where it lives: workflows use
# ${{ github.repository }}, scripts ask tools/repo.sh, the website is
# stamped at deploy (tools/site/stamp.sh). This fails on any mention of
# the old owner's name, in any case, in any text file of the tree.
#
#   sh tools/portabilitytest.sh [TREE]      TREE defaults to this checkout
#
# The only allowed exceptions are the two lines that pin a published
# release which exists nowhere else (EXCEPTIONS below). Each is matched
# by file AND by the release tag on the same line, so a second mention in
# either file is still a failure.
#
# It proves itself first: in a scratch copy of the tree it plants the
# name where a real slip would put it (a page, a script, a workflow, the
# other line of a pinned file) and requires the scan to go red each time.
set -u
cd "$(dirname "$0")/.."

# Split so that this file does not contain what it hunts for.
OLD="ComputerDude""771"
TAG="releases/download/v0.1.0-dd39389/"
# file<TAB>reason. The tag above must be on the same line.
EXCEPTIONS=".github/workflows/e2e.yml
.github/workflows/windows.yml"
# Why: e2e.yml and windows.yml test the installer that the original
# repository published as v0.1.0-dd39389. This repository has no release
# yet, so they stay pinned to that one on purpose. Delete the pin (and
# the exception) when this repository publishes its own release.

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '    ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '    FAIL %s\n' "$1"; }

# scan TREE: print every offending "file:line:text", none when clean.
scan() {
    ( cd "$1" || exit 1
      if git -c safe.directory='*' rev-parse --git-dir >/dev/null 2>&1; then
          git -c safe.directory='*' ls-files -z -- . ':!docs'
      else
          find . -path ./.git -prune -o -path ./docs -prune -o -type f -print0 |
              cat
      fi | xargs -0 grep -InHi -e "$OLD" 2>/dev/null || true ) | sed 's|^\./||' |
    while IFS= read -r hit; do
        f=${hit%%:*}
        case "$hit" in *"$TAG"*)
            for e in $EXCEPTIONS; do [ "$f" = "$e" ] && continue 2; done ;;
        esac
        printf '%s\n' "$hit"
    done
}

# plant TREE FILE: add a line naming the old owner to FILE.
plant() { printf '\nhttps://github.com/%s/auros-from-scratch/x\n' "$OLD" >> "$1/$2"; }

tree=${1:-.}
echo "portabilitytest: $tree"
found=$(scan "$tree")
if [ -z "$found" ]; then ok "no file outside docs/ names $OLD (pins excepted)"
else bad "files outside docs/ name the old repository:"; printf '%s\n' "$found" | cut -c1-160 | sed 's/^/           /'; fi

# --- the scan must go red when it should --------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/portability.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
( cd "$tree" && { git -c safe.directory='*' ls-files -z -- . ':!docs' 2>/dev/null ||
      find . -path ./.git -prune -o -path ./docs -prune -o -type f -print0; } |
  tr '\0' '\n' | grep -v '^$' | sed 's|^\./||' | tar -cf - -T - ) | tar -xf - -C "$tmp"
if [ -n "$(scan "$tmp")" ] && [ -z "$found" ]; then
    bad "the scratch copy is not clean, so the red cases prove nothing"
else
    for f in website/index.html tools/repo.sh README.md; do
        [ -f "$tmp/$f" ] || { bad "red case: $f is not in the tree"; continue; }
        cp "$tmp/$f" "$tmp/$f.keep"; plant "$tmp" "$f"
        [ -n "$(scan "$tmp")" ] && ok "red: a mention in $f is caught" || bad "a mention in $f went unnoticed"
        mv "$tmp/$f.keep" "$tmp/$f"
    done
    for f in $EXCEPTIONS; do
        [ -f "$tmp/$f" ] || { bad "red case: pinned file $f is not in the tree"; continue; }
        cp "$tmp/$f" "$tmp/$f.keep"; plant "$tmp" "$f"
        [ -n "$(scan "$tmp")" ] && ok "red: a second mention in pinned $f is caught" || bad "a second mention in pinned $f went unnoticed"
        mv "$tmp/$f.keep" "$tmp/$f"
    done
    # a pin in a file that is not an exception is not excused by the tag
    printf '\nX=https://github.com/%s/r/%s\n' "$OLD" "$TAG" >> "$tmp/tools/repo.sh"
    [ -n "$(scan "$tmp")" ] && ok "red: the pin's tag in any other file is not excused" || bad "the tag excused a file that is not an exception"
fi

echo "portabilitytest: $pass ok, $fail failed"
[ "$fail" = 0 ]
