#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  ferry-copy and the stages, run AS ROOT, the way first boot runs them.
#
#  The bug this exists for: Ferry used to copy as root into paths under
#  her home. A link planted there by anything running as her
#  (`~/Pictures -> /etc/cron.d`) made root write Windows-side content
#  wherever it pointed -- a local root escalation. These tests plant
#  exactly those links, run the real thing as root, and look at what is
#  on the other side of every link afterwards.
#
#  And each guard is switched off in turn (the lines marked MUTATE-* in
#  copy.c are removed in a copy of the source) to show the test could
#  see the bug: with both guards gone, root writes into the victim.
#
#  Needs root. Run by tests/run.sh through `sudo -n`; where there is no
#  sudo the whole file says SKIP, loudly, and does not pass.
#
#    sudo sh tests/copy-root.sh
# ═══════════════════════════════════════════════════════════════════
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FERRY=$(dirname "$HERE")

if [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        exec sudo -n env "TMPDIR=${TMPDIR:-/tmp}" PATH="$PATH" sh "$0" "$@"
    fi
    echo "  SKIP the root tests (no root and no passwordless sudo): the privilege drop and the hostile-link fixtures were NOT exercised"
    exit 0
fi

export NO_COLOR=1
PATH="$FERRY:$FERRY/build:$PATH"
FC="$FERRY/build/ferry-copy"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ferryroot.XXXXXX")
chmod 755 "$TMP"
trap 'umount "$TMP/small" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
assert() { _l=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_l"; else bad "$_l"; fi; }
refute() { _l=$1; shift; if "$@" >/dev/null 2>&1; then bad "$_l"; else ok "$_l"; fi; }

U=61001; G=61002          # her: no passwd entry needed
echo "ferry-copy as root, for someone else:"

# Her home, a source she can read, and a victim only root can write.
mkhome() {   # NAME -> $TMP/NAME owned by her
    install -d -o $U -g $G -m 0750 "$TMP/$1"
}
SRC="$TMP/src"; mkdir -p "$SRC/sub" "$SRC/Pictures"
printf 'photo' > "$SRC/Pictures/a.jpg"; printf 'doc' > "$SRC/doc.txt"; printf 'deep' > "$SRC/sub/d.txt"
chmod -R a+rX "$SRC"
VICTIM="$TMP/victim"; install -d -o root -g root -m 0755 "$VICTIM"
rc() {  # run ferry-copy (given binary) as root for her; state in $TMP/st
    _bin=$1; shift
    mkdir -p "$TMP/st/state"
    "$_bin" --uid $U --gid $G --home "$HOME_" --notes "$TMP/st/notes" \
        --manifest "$TMP/st/manifest" --state "$TMP/st" "$@"
}
victim_clean() { [ -z "$(find "$VICTIM" -mindepth 1 | head -1)" ]; }

# ── she gets her files, owned by her ───────────────────────────────
mkhome h1; HOME_="$TMP/h1"
rc "$FC" --job Documents "$SRC" "$HOME_/Documents" >/dev/null 2>&1
eq "files are owned by her, not by root" "$(stat -c %u:%g "$HOME_/Documents/doc.txt")" "$U:$G"
eq "new folders are owned by her too" "$(stat -c %u:%g "$HOME_/Documents/sub")" "$U:$G"
eq "the copy is there" "$(cat "$HOME_/Documents/sub/d.txt")" deep
refute "nothing in her home is owned by root" sh -c "find '$HOME_' ! -user $U | grep -q ."
eq "ferry-copy will not copy as root" "$("$FC" --uid 0 --gid 0 --home "$HOME_" --job X "$SRC" "$HOME_/X" >/dev/null 2>&1; echo $?)" 3
mkdir -p "$TMP/notmine"; chown 0:0 "$TMP/notmine"
eq "a home that is not hers is refused (exit 3), nothing written" \
   "$("$FC" --uid $U --gid $G --home "$TMP/notmine" --job X "$SRC" "$TMP/notmine/X" >/dev/null 2>&1; echo $?):$(ls "$TMP/notmine" | wc -l | tr -d ' ')" "3:0"

# ── THE FIXTURE: links that would have made root write elsewhere ───
plant() {   # a home full of links to the victim, as a program running as her would leave it
    mkhome "$1"
    ln -s "$VICTIM" "$TMP/$1/Pictures"                 # her folder IS a link
    mkdir -p "$TMP/$1/Documents"; ln -s "$VICTIM" "$TMP/$1/Documents/sub"    # a link inside it
    ln -s "$VICTIM/pwned-file" "$TMP/$1/Documents/doc.txt"                    # a link where a file goes
    ln -s "$VICTIM/pwned-temp" "$TMP/$1/Documents/.ferrypart"                 # a link at the temp name
    chown -h $U:$G "$TMP/$1/Pictures" "$TMP/$1/Documents/sub" "$TMP/$1/Documents/doc.txt" "$TMP/$1/Documents/.ferrypart"
    chown $U:$G "$TMP/$1/Documents"
}
plant h2; HOME_="$TMP/h2"
rc "$FC" --job Pictures "$SRC/Pictures" "$HOME_/Pictures" --job Documents "$SRC" "$HOME_/Documents" >/dev/null 2>&1; _rc=$?
assert "the victim (root's) is untouched: nothing written through any of four links" victim_clean
eq "exit 2: some things could not be put where they belong" "$_rc" 2
assert "the refused folder is named, in plain words" grep -q 'link where this folder belongs' "$TMP/st/notes"
eq "the file behind a planted file-link was kept beside it" "$(cat "$HOME_/Documents/doc (from Windows).txt")" doc

# ── each guard, switched off, to see the fixture is capable ────────
mutant() {   # NAME SED-EXPR : builds $TMP/m-NAME from copy.c with the expression applied
    sed "$2" "$FERRY/copy.c" > "$TMP/copy-$1.c"
    cp "$FERRY/winattr.c" "$TMP/winattr.c"
    cc -O1 -std=gnu11 -w -o "$TMP/m-$1" "$TMP/copy-$1.c" 2>/dev/null
    cmp -s "$TMP/copy-$1.c" "$FERRY/copy.c" && return 1
    [ -x "$TMP/m-$1" ]
}
DROP='/MUTATE-DROP/d'
NOFOLLOW='s/O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); \/\* MUTATE-NOFOLLOW \*\//O_DIRECTORY | O_CLOEXEC);/'
[ "$(grep -c MUTATE-DROP "$FERRY/copy.c")" -ge 3 ] && ok "the privilege-drop lines are marked in copy.c" || bad "MUTATE-DROP markers missing"
[ "$(grep -c MUTATE-NOFOLLOW "$FERRY/copy.c")" -ge 1 ] && ok "the no-follow line is marked in copy.c" || bad "MUTATE-NOFOLLOW marker missing"

# (1) no drop: a link is still refused, but everything is written AS ROOT
if mutant nodrop "$DROP"; then
    mkhome h3; HOME_="$TMP/h3"
    rc "$TMP/m-nodrop" --job Documents "$SRC" "$HOME_/Documents" >/dev/null 2>&1
    eq "(proof) without the drop, her files are owned by root -- the ownership check sees it" \
       "$(stat -c %u "$HOME_/Documents/doc.txt" 2>/dev/null)" 0
else bad "could not build the no-drop mutant"; fi

# (2) no no-follow, drop intact: root-owned victim still safe, but a place of HERS elsewhere is not
if mutant nofollow "$NOFOLLOW"; then
    rm -rf "$VICTIM"/*; install -d -o $U -g $G "$TMP/hers-elsewhere"
    mkhome h4; HOME_="$TMP/h4"; ln -s "$TMP/hers-elsewhere" "$HOME_/Pictures"; chown -h $U:$G "$HOME_/Pictures"
    rc "$TMP/m-nofollow" --job Pictures "$SRC/Pictures" "$HOME_/Pictures" >/dev/null 2>&1
    assert "(proof) without no-follow, her files DO land through the link" test -e "$TMP/hers-elsewhere/a.jpg"
    ln -sfn "$VICTIM" "$HOME_/Pictures"
    rc "$TMP/m-nofollow" --job Pictures "$SRC/Pictures" "$HOME_/Pictures" >/dev/null 2>&1
    assert "...but with the drop still in, root's victim stays clean (the second guard holds alone)" victim_clean
    rm -rf "$TMP/hers-elsewhere"
else bad "could not build the no-follow mutant"; fi

# (3) both off: this is the old bug. Root writes into the victim.
if mutant both "$DROP;$NOFOLLOW"; then
    mkhome h5; HOME_="$TMP/h5"; ln -s "$VICTIM" "$HOME_/Pictures"; chown -h $U:$G "$HOME_/Pictures"
    rc "$TMP/m-both" --job Pictures "$SRC/Pictures" "$HOME_/Pictures" >/dev/null 2>&1
    assert "(proof) with both guards removed, root writes into the victim: the fixture can see the bug" test -e "$VICTIM/a.jpg"
    eq "...and as root, so it could have been /etc/cron.d" "$(stat -c %u "$VICTIM/a.jpg" 2>/dev/null)" 0
    rm -f "$VICTIM"/*
else bad "could not build the both-off mutant"; fi
assert "(after the experiments) the real binary is still the one that is clean" victim_clean

# ── the whole first-boot path, as root, over a hostile home ────────
WIN="$TMP/win"
sh "$HERE/mkfakewin.sh" "$WIN" >/dev/null 2>&1
chmod -R a+rX "$WIN"
HOME_="$TMP/h6"; install -d -o 65534 -g 65534 "$HOME_"
for d in Pictures Documents .mozilla .config .local Desktop; do
    ln -s "$VICTIM" "$HOME_/$d"; chown -h 65534:65534 "$HOME_/$d"
done
OWN=nobody   # a real account with uid 65534 and no home
runstage() {
    _s=$1; shift
    FERRY_STATE="$TMP/fstate" FERRY_HIVE_BACKEND=hivepeek "$FERRY/$_s" --root "$WIN" --home "$HOME_" --owner "$OWN" "$@" >/dev/null 2>&1
}
runstage ferry-files; runstage ferry-firefox; runstage ferry-settings --only wallpaper
assert "files, Firefox and wallpaper stages as root over a home of links: the victim is untouched" victim_clean
eq "...and nothing in her home was created by root" "$(find "$HOME_" ! -user 65534 | wc -l | tr -d ' ')" 0
assert "...and it was not vacuous: the links are still links and the stages did run" \
    sh -c "test -L '$HOME_/Pictures' && test -L '$HOME_/.mozilla' && grep -q 'link where this folder belongs' '$TMP/fstate/report.d/files.tsv'"
# the same stages when the home is honest
HOME_="$TMP/h7"; install -d -o 65534 -g 65534 "$HOME_"
rm -rf "$TMP/fstate"
runstage ferry-files; runstage ferry-firefox; runstage ferry-settings --only wallpaper
assert "an honest home gets its files" test -f "$HOME_/Desktop/report.docx"
assert "...and its Firefox profile" test -f "$HOME_/.mozilla/firefox/Profiles/a1b2c3d4.default-release/places.sqlite"
assert "...and its wallpaper" sh -c "ls '$HOME_'/.local/share/backgrounds/windows-wallpaper* >/dev/null"
eq "every file made under her home is hers" "$(find "$HOME_" ! -user 65534 | wc -l | tr -d ' ')" 0
assert "profiles.ini names the copied profile as the default" \
    sh -c "grep -q '^Default=1' '$HOME_/.mozilla/firefox/profiles.ini' && grep -q 'a1b2c3d4.default-release' '$HOME_/.mozilla/firefox/profiles.ini'"
refute "...and does not claim it for the Windows install" grep -q '^\[Install' "$HOME_/.mozilla/firefox/profiles.ini"

# ── no more room ────────────────────────────────────────────────────
mkdir -p "$TMP/small"
if mount -t tmpfs -o size=1m tmpfs "$TMP/small" 2>/dev/null; then
    install -d -o $U -g $G "$TMP/small/home"
    mkdir -p "$TMP/bigsrc"; head -c 4194304 /dev/urandom > "$TMP/bigsrc/big.bin"; printf 'tiny' > "$TMP/bigsrc/a.txt"; chmod -R a+rX "$TMP/bigsrc"
    HOME_="$TMP/small/home"
    OUT=$(rc "$FC" --plain --job Videos "$TMP/bigsrc" "$HOME_/Videos" 2>/dev/null); _rc=$?
    eq "a full disk stops the copy with exit 4" "$_rc" 4
    case "$OUT" in *"no more room"*) ok "...and says so in plain words" ;; *) bad "no plain message: $OUT" ;; esac
    refute "...and leaves no half-written file behind" sh -c "find '$HOME_' -name '.ferrypart*' -o -name big.bin | grep -q ."
    assert "...and the ledger says the disk filled up" grep -q 'the disk filled up' "$TMP/st/notes"
    umount "$TMP/small"
else
    echo "  SKIP the full-disk test (cannot mount a small tmpfs here)"
fi

echo
printf 'ferry-copy root tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
