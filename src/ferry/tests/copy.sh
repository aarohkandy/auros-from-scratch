#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  ferry-copy, as an ordinary user (nothing here needs root).
#
#  What is proven, and how each proof would fail if the thing it checks
#  broke (a check that cannot fail is a decoration):
#
#    names        long and non-ASCII names, and the old "(from Windows)"
#                 naming bugs: exact expected names, compared byte for byte
#    links        a link on the Windows side is reported and not entered;
#                 a link where her folder should be is refused; the file
#                 behind each link is looked for afterwards
#    progress     weighted by BYTES: checked against a mutant that weights
#                 by files, which must fail the same check
#    resume       a second run copies nothing; our own interrupted output
#                 is replaced, a file she edited never is
#    put          atomic, keeps what exists on request, backs it up
#
#  The privileged half (giving up root, the hostile symlink that would
#  have been a root write) is tests/copy-root.sh.
#
#    sh tests/copy.sh        (run by tests/run.sh)
# ═══════════════════════════════════════════════════════════════════
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FERRY=$(dirname "$HERE")
FC="$FERRY/build/ferry-copy"
export NO_COLOR=1

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ferrycopy.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
assert() { _l=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_l"; else bad "$_l"; fi; }
refute() { _l=$1; shift; if "$@" >/dev/null 2>&1; then bad "$_l"; else ok "$_l"; fi; }

ME=$(id -u); MYGID=$(id -g)
# fc OUT-DIR args...: run ferry-copy as myself into a fresh state dir.
N=0
fc() {
    N=$((N+1)); S="$TMP/st$N"; mkdir -p "$S/state"
    env $FCENV "$FC" --uid "$ME" --gid "$MYGID" --home "$H" --notes "$S/notes" \
          --manifest "$S/manifest" --state "$S" --progress "$S/progress" "$@"
}
fc_same() {   # same state dir as the previous run (a resume)
    env $FCENV "$FC" --uid "$ME" --gid "$MYGID" --home "$H" --notes "$S/notes" \
          --manifest "$S/manifest" --state "$S" --progress "$S/progress" "$@"
}
FCENV="FERRY_COPY_X=1"

echo "ferry-copy (as an ordinary user):"

# ── names ──────────────────────────────────────────────────────────
H="$TMP/h1"; SRC="$TMP/s1"; mkdir -p "$H" "$SRC/a/dir.v2" "$SRC/Ünï/日本語"
printf 'plain' > "$SRC/plain.txt"
printf 'jp'    > "$SRC/Ünï/日本語/写真 ☃ 🙂.jpg"
printf 'v'     > "$SRC/a/dir.v2/file"
printf 'no ext' > "$SRC/README"
# 85 three-byte characters = 255 bytes: legal on both sides.
N255=$(python3 -c "print('日'*85, end='')")
printf 'edge' > "$SRC/$N255"
fc --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "a non-ASCII name arrives byte for byte" \
   "$(cat "$H/Documents/Ünï/日本語/写真 ☃ 🙂.jpg" 2>/dev/null)" jp
eq "a 255-byte UTF-8 name arrives as it was" \
   "$(cat "$H/Documents/$N255" 2>/dev/null)" edge

# Names Windows allows and this disk does not. The limit is lowered with
# the test seam so an ordinary filesystem can hold the source.
H="$TMP/h2"; SRC="$TMP/s2"; mkdir -p "$H" "$SRC"
L1=$(python3 -c "print('日'*30 + 'A.jpg', end='')")       # 95 bytes
L2=$(python3 -c "print('日'*30 + 'B.jpg', end='')")       # same first 90 bytes
L3=$(python3 -c "print('x'*80 + '.verylongextension_xx', end='')")
printf one > "$SRC/$L1"; printf two > "$SRC/$L2"; printf three > "$SRC/$L3"
FCENV="FERRY_COPY_NAMEMAX=60"; fc --job Pictures "$SRC" "$H/Pictures" >/dev/null 2>&1; FCENV="FERRY_COPY_X=1"
eq "all three over-long names were copied" "$(ls "$H/Pictures" | wc -l | tr -d ' ')" 3
_maxb=$(for f in "$H/Pictures"/*; do basename "$f" | wc -c; done | sort -n | tail -1)
[ "$_maxb" -le 61 ] && ok "no name is more than 60 bytes (the lowered limit)" || bad "a name is $_maxb bytes"
assert "two long names that start the same did not collapse into one" \
    sh -c "[ \"\$(cat '$H'/Pictures/*.jpg | tr -d '\\n')\" = onetwo ] || [ \"\$(cat '$H'/Pictures/*.jpg | tr -d '\\n')\" = twoone ]"
assert "a shortened name is still valid UTF-8" \
    sh -c "ls '$H/Pictures' | python3 -c 'import sys; sys.stdin.buffer.read().decode(\"utf-8\")'"
assert "the shortening is in the ledger, by the real name" \
    grep -q "was too long for this disk" "$S/notes"
assert "the .jpg ending survived the shortening" \
    sh -c "ls '$H/Pictures' | grep -c '\\.jpg\$' | grep -qx 2"

# ── collisions: nothing is ever overwritten, nothing is chosen ─────
H="$TMP/h3"; SRC="$TMP/s3"; mkdir -p "$H/Documents/a/dir.v2" "$SRC/a/dir.v2" "$SRC/a"
printf 'mine'     > "$H/Documents/x.txt"
printf 'windows'  > "$SRC/x.txt"
printf 'mine-f'   > "$H/Documents/a/dir.v2/file"
printf 'windows-f' > "$SRC/a/dir.v2/file"
printf 'mine-n'   > "$H/Documents/README"
printf 'windows-n' > "$SRC/README"
fc --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "her own file was not touched" "$(cat "$H/Documents/x.txt")" mine
eq "the Windows file landed beside it" "$(cat "$H/Documents/x (from Windows).txt")" windows
eq "a name with no extension gets the suffix at the end" \
   "$(cat "$H/Documents/README (from Windows)" 2>/dev/null)" windows-n
eq "a dot in a FOLDER name is not mistaken for an extension (a/dir.v2/file)" \
   "$(cat "$H/Documents/a/dir.v2/file (from Windows)" 2>/dev/null)" windows-f
refute "...and no folder called 'dir (from Windows).v2' was invented" \
   test -e "$H/Documents/a/dir (from Windows).v2"
assert "each collision is in the ledger" \
    sh -c "[ \$(grep -c 'was already there' '$S/notes') -eq 3 ]"
# a second run: the Windows copy is recognised, not copied again
fc_same --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "a second run adds no third copy" "$(ls "$H/Documents" | grep -c 'x ')" 1
# now (from Windows) is taken by something else: it must not be overwritten
printf 'someone-elses' > "$H/Documents/y (from Windows).txt"; printf 'mine-y' > "$H/Documents/y.txt"
printf 'windows-y' > "$SRC/y.txt"
fc --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "the second collision does not overwrite the first" \
   "$(cat "$H/Documents/y (from Windows).txt")" someone-elses
eq "...it takes the next number" \
   "$(cat "$H/Documents/y (from Windows 2).txt" 2>/dev/null)" windows-y

# ── files that are not what they seem ──────────────────────────────
H="$TMP/h4"; SRC="$TMP/s4"; mkdir -p "$H" "$SRC/real" "$TMP/outside"
printf 'SECRET' > "$TMP/outside/secret.txt"
printf 'ok' > "$SRC/real/f.txt"
ln -s "$TMP/outside" "$SRC/real/junction"          # a link out of the source
ln -s "$SRC" "$SRC/real/loop"                      # a link back into it
ln -s "$TMP/outside/secret.txt" "$SRC/real/note.txt" # a link to a file
mkdir -p "$SRC/real/deep"; ln -s .. "$SRC/real/deep/up"
mkfifo "$SRC/real/pipe" 2>/dev/null
fc --job Documents "$SRC/real" "$H/Documents" >/dev/null 2>&1; _rc=$?
eq "exit 2: done, but some things were not copied" "$_rc" 2
eq "the ordinary file came" "$(cat "$H/Documents/f.txt")" ok
refute "the file behind a link out of the source was not copied" \
    sh -c "grep -rqs SECRET '$H'"
refute "the linked folder is not in the copy" test -e "$H/Documents/junction"
refute "a link to a file is not turned into the file" test -e "$H/Documents/note.txt"
assert "each link is in the ledger by name" \
    sh -c "grep -q 'Documents/junction' '$S/notes' && grep -q 'Documents/loop' '$S/notes' && grep -q 'Documents/note.txt' '$S/notes'"
refute "a pipe did not hang or arrive" test -e "$H/Documents/pipe"
# the top of a job that is itself a link is refused, not followed
H="$TMP/h4b"; mkdir -p "$H"; ln -s "$TMP/outside" "$TMP/linked-src"
fc --job Pictures "$TMP/linked-src" "$H/Pictures" >/dev/null 2>&1
refute "a Windows folder that is a link is not copied" \
    sh -c "grep -rqs SECRET '$H'"
assert "...and says so" grep -q 'is a link' "$S/notes"

# a Windows junction that the filesystem shows as a plain folder is
# found by its attribute (the reparse bit), not by its type
H="$TMP/h4c"; SRC="$TMP/s4c"; mkdir -p "$H" "$SRC/ok" "$SRC/junc"
printf 'in-junction' > "$SRC/junc/inside.txt"; printf 'fine' > "$SRC/ok/f.txt"
printf '%s\t0x410\t0xA0000003\n' "$SRC/junc" > "$TMP/map4c"       # directory + reparse, junction tag
FCENV="FERRY_WINATTR_MAP=$TMP/map4c"; fc --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1; FCENV="FERRY_COPY_X=1"
eq "a junction shown as a folder is not entered" \
   "$(find "$H/Documents" -type f | sed "s|$H/Documents/||" | sort | tr '\n' ' ')" "ok/f.txt "
assert "...and is reported" grep -q 'Documents/junc' "$S/notes"

# ── her side: a link where her folder belongs ───────────────────────
H="$TMP/h5"; SRC="$TMP/s5"; mkdir -p "$H/Pictures" "$SRC/sub" "$TMP/away"
printf 'p' > "$SRC/top.jpg"; printf 'q' > "$SRC/sub/deep.jpg"
ln -s "$TMP/away" "$H/Pictures/sub"                 # she (or a program as her) made this
fc --job Pictures "$SRC" "$H/Pictures" >/dev/null 2>&1
refute "nothing was written through a link inside her folder" \
    sh -c "find '$TMP/away' -type f | grep -q ."
eq "the rest of the folder still came" "$(cat "$H/Pictures/top.jpg" 2>/dev/null)" p
assert "the refused folder is named in the ledger, in plain words" \
    grep -q 'link where this folder belongs' "$S/notes"
H="$TMP/h5b"; mkdir -p "$H"; ln -s "$TMP/away" "$H/Pictures"
fc --job Pictures "$SRC" "$H/Pictures" >/dev/null 2>&1; _rc=$?
refute "nothing was written through a link AT her folder" \
    sh -c "find '$TMP/away' -type f | grep -q ."
refute "a link at her folder is still a link afterwards (not replaced)" test ! -L "$H/Pictures"
assert "...and that is said" grep -q 'link where this folder belongs' "$S/notes"
# a file with the name of a link: the link is never written through
H="$TMP/h5c"; mkdir -p "$H/Pictures"; ln -s "$TMP/away/stolen" "$H/Pictures/top.jpg"
fc --job Pictures "$SRC" "$H/Pictures" >/dev/null 2>&1
refute "a planted link where a FILE goes is not written through" test -e "$TMP/away/stolen"
eq "...the Windows file was kept beside it instead" \
   "$(cat "$H/Pictures/top (from Windows).jpg" 2>/dev/null)" p
# a leftover temp name that is a link
H="$TMP/h5d"; mkdir -p "$H/Pictures"; ln -s "$TMP/away/pwned" "$H/Pictures/.ferrypart"
fc --job Pictures "$SRC" "$H/Pictures" >/dev/null 2>&1
refute "a planted link at the temp name is not written through" test -e "$TMP/away/pwned"
eq "...and the copy still worked" "$(cat "$H/Pictures/top.jpg" 2>/dev/null)" p
# a destination that is not inside her home at all
H="$TMP/h5e"; mkdir -p "$H"
fc --job Pictures "$SRC" "$TMP/away/Pictures" >/dev/null 2>&1
refute "a destination outside her home is refused" test -e "$TMP/away/Pictures"
refute "a '..' in a destination is refused" sh -c "
    '$FC' --uid $ME --gid $MYGID --home '$H' --job Pictures '$SRC' '$H/../away/Pictures' >/dev/null 2>&1;
    test -e '$TMP/away/Pictures'"
# a home that is not hers
H="$TMP/h5f"; mkdir -p "$H"
"$FC" --uid 1 --gid 1 --home "$H" --job P "$SRC" "$H/P" >/dev/null 2>&1; _rc=$?
refute "copying for another person is refused when not root" test "$_rc" = 0

# ── progress is by bytes ───────────────────────────────────────────
H="$TMP/h6"; mkdir -p "$H" "$TMP/s6a" "$TMP/s6b"
head -c 6291456 /dev/urandom > "$TMP/s6a/big.bin"
i=0; while [ $i -lt 50 ]; do printf 'tiny %d' $i > "$TMP/s6b/f$i.txt"; i=$((i+1)); done
FCENV="FERRY_COPY_INTERVAL_MS=0"; fc --job Videos "$TMP/s6a" "$H/Videos" --job Documents "$TMP/s6b" "$H/Documents" >/dev/null 2>&1; FCENV="FERRY_COPY_X=1"
check_weighted() {   # progress file: passes iff the bar is byte-weighted and sane
    python3 - "$1" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) > 5, "too few progress lines"
pcts = [r["pct"] for r in rows]
assert pcts == sorted(pcts), "progress went backwards"
assert pcts[-1] == 100, "never reached 100"
assert all(r["total"] == rows[0]["total"] for r in rows), "total moved"
# After the big file only 1 of 51 files is done, but nearly all the bytes are:
after_big = [r for r in rows if r["files_done"] <= 2 and r["pct"] >= 90]
assert after_big, "the bar did not follow the bytes"
PY
}
assert "progress follows bytes: one big file is most of the bar" check_weighted "$S/progress"
assert "the bar never goes backwards and ends at 100" check_weighted "$S/progress"
# the same check must FAIL on a build that weights by files
sed 's|pct = g_total_bytes ? (int)(g_done_bytes \* 100 / g_total_bytes) : 100; /\* MUTATE-PCT \*/|pct = g_total_files ? (int)(g_done_files * 100 / g_total_files) : 100;|' \
    "$FERRY/copy.c" > "$TMP/copy-pct.c"
cp "$FERRY/winattr.c" "$TMP/winattr.c"
if cmp -s "$TMP/copy-pct.c" "$FERRY/copy.c"; then bad "the progress mutation matched nothing"; else
    cc -O1 -std=gnu11 -w -o "$TMP/fc-pct" "$TMP/copy-pct.c" 2>/dev/null
    H="$TMP/h6m"; mkdir -p "$H"; MS="$TMP/stm"; mkdir -p "$MS/state"
    FERRY_COPY_INTERVAL_MS=0 "$TMP/fc-pct" --uid "$ME" --gid "$MYGID" --home "$H" --progress "$MS/progress" \
        --job Videos "$TMP/s6a" "$H/Videos" --job Documents "$TMP/s6b" "$H/Documents" >/dev/null 2>&1
    refute "(proof) a bar weighted by FILES fails the same check" check_weighted "$MS/progress"
fi
# the plain line: in her words, once the numbers are known
H="$TMP/h6p"; mkdir -p "$H"
OUT=$(FCENV="FERRY_COPY_INTERVAL_MS=0"; fc --plain --job Pictures "$TMP/s6b" "$H/Pictures" 2>/dev/null)
case "$OUT" in *"Copying your pictures: "*" of 50 files."*) ok "the plain line reads 'Copying your pictures: N of 50 files.'" ;; *) bad "plain line: $OUT" ;; esac
case "$OUT" in *"Copied your pictures: 50 files."*) ok "...and ends by saying what was done" ;; *) bad "no closing line: $OUT" ;; esac
case "$OUT" in *left*) bad "a copy that took no time claimed a time left: $OUT" ;; *) ok "no 'time left' before there is a rate to base it on" ;; esac
# the time left, from known numbers
eta() { "$FC" eta "$@"; }
eq "no estimate in the first seconds" "$(eta 2 10485760 99999999)" ""
eq "no estimate before a megabyte has really been copied" "$(eta 30 1000 99999999)" ""
eq "under a minute" "$(eta 30 31457280 10485760)" " Less than a minute left."
eq "a few minutes (60 MB in 60 s, 120 MB to go)" "$(eta 60 62914560 125829120)" " About 2 minutes left."
eq "a minute is not 'minutes'" "$(eta 60 62914560 62914560)" " About 1 minute left."
eq "hours when it is hours" "$(eta 100 1048576 377487360)" " About 10 hours left."
eq "nothing left, nothing said" "$(eta 60 62914560 0)" ""

# ── resume, mtime, mode, dry-run ───────────────────────────────────
H="$TMP/h7"; SRC="$TMP/s7"; mkdir -p "$H" "$SRC/d"
printf 'one' > "$SRC/d/a.txt"; chmod 0777 "$SRC/d/a.txt"; touch -d '2019-05-04 03:02:01' "$SRC/d/a.txt"
fc --dry-run --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
refute "a dry run writes nothing" test -e "$H/Documents"
fc --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "the modification time came across" "$(stat -c %Y "$H/Documents/d/a.txt")" "$(stat -c %Y "$SRC/d/a.txt")"
eq "a Windows file is not executable here" "$(stat -c %a "$H/Documents/d/a.txt")" 644
refute "no temp file left behind" sh -c "find '$H' -name '.ferrypart*' | grep -q ."
_n1=$(grep -c . "$S/manifest")
fc_same --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "a re-run copies nothing and records nothing new" "$(grep -c . "$S/manifest")" "$_n1"
# our own interrupted output (right time, wrong size, in our manifest) is replaced;
# the same file edited by her (different time) never is
printf 'on' > "$H/Documents/d/a.txt"; touch -d '2019-05-04 03:02:01' "$H/Documents/d/a.txt"
fc_same --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "a half-written copy of ours is made whole" "$(cat "$H/Documents/d/a.txt")" one
printf 'edited by her' > "$H/Documents/d/a.txt"
fc_same --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "a file she edited is never replaced" "$(cat "$H/Documents/d/a.txt")" "edited by her"
eq "...the Windows one is beside it" "$(cat "$H/Documents/d/a (from Windows).txt")" one
# the same short copy, but NOT in our manifest, is hers
H="$TMP/h7b"; mkdir -p "$H/Documents/d"; printf 'on' > "$H/Documents/d/a.txt"; touch -d '2019-05-04 03:02:01' "$H/Documents/d/a.txt"
fc --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1
eq "a file we did not write is never replaced, even if it looks the same" "$(cat "$H/Documents/d/a.txt")" on

# ── skip lists (Firefox) ────────────────────────────────────────────
H="$TMP/h8"; SRC="$TMP/s8"; mkdir -p "$H" "$SRC/cache2/entries" "$SRC/storage"
printf k > "$SRC/key4.db"; printf K > "$SRC/KEY4.DB"; printf p > "$SRC/prefs.js"; printf c > "$SRC/cache2/entries/x"
printf s > "$SRC/storage/ok.txt"
fc --skip-dir cache2 --skip-file key4.db --job Firefox/p "$SRC" "$H/p" >/dev/null 2>&1
eq "named files and folders are skipped at any depth, any case" \
   "$(cd "$H/p" && find . -type f | sort | tr '\n' ' ')" "./prefs.js ./storage/ok.txt "

# ── put ────────────────────────────────────────────────────────────
H="$TMP/h9"; mkdir -p "$H"
put() { "$FC" put --uid "$ME" --gid "$MYGID" --home "$H" "$@"; }
printf 'v1' | put "$H/.config/a.conf" >/dev/null 2>&1
eq "put makes the folders and the file" "$(cat "$H/.config/a.conf")" v1
printf 'v2' | put --keep-existing "$H/.config/a.conf" >/dev/null 2>&1; _rc=$?
eq "--keep-existing exits 5 and leaves the file" "$_rc:$(cat "$H/.config/a.conf")" "5:v1"
printf 'v3' | put --backup .old "$H/.config/a.conf" >/dev/null 2>&1
eq "put replaces..." "$(cat "$H/.config/a.conf")" v3
eq "...and keeps the old one beside it" "$(cat "$H/.config/a.conf.old")" v1
ln -s "$TMP/away" "$H/.local"
printf 'x' | put "$H/.local/share/f" >/dev/null 2>&1
refute "put does not write through a link in her home" test -e "$TMP/away/share"
printf 'y' | put "$TMP/away/outside" >/dev/null 2>&1
refute "put refuses a place outside her home" test -e "$TMP/away/outside"

# ── the old habits are gone from the shell ─────────────────────────
# Root's shell must not write in her home: no cp/mv/ln/mkdir/chown/tee or
# redirection aimed at it. (Everything there goes through her_copy and
# her_put, i.e. ferry-copy.) The lint is proven by planting each habit.
lint_home_writes() {   # prints offending lines; exit 0 when there are none
    ! grep -nE 'safe_copy|chown|(^|[^_a-z])own +"|(mkdir|cp|mv|ln|install|tee|touch|rm) .*(FERRY_HOME|_dest|_wpdest)|(^|[^-])>>? *"?\$\{?(FERRY_HOME|_dest)|chmod .*FERRY_HOME' "$@" \
        | grep -v '^[^:]*:[0-9]*: *#'
}
assert "no Ferry script writes in her home itself" lint_home_writes "$FERRY"/ferry "$FERRY"/ferry-files "$FERRY"/ferry-firefox "$FERRY"/ferry-settings "$FERRY"/ferry-wifi "$FERRY"/ferry-detect "$FERRY"/ferry-hive "$FERRY"/ferry-report "$FERRY"/ferry-common.sh
for _habit in 'mkdir -p "$FERRY_HOME/.config"' 'cp -p "$_f" "$_dest/x"' 'chown -R "$FERRY_OWNER" "$_dest"' 'echo hi > "$FERRY_HOME/x"' 'safe_copy a b'; do
    printf '%s\n' "$_habit" > "$TMP/habit.sh"
    refute "(proof) the lint catches: $_habit" lint_home_writes "$TMP/habit.sh"
done

# ── what the classifier says about a small file with no blocks ─────
# (NTFS keeps a small file inside its record; the kernel says 0 blocks.)
WA="$FERRY/build/ferry-winattr"
: > "$TMP/resident"; truncate -s 500 "$TMP/resident"
: > "$TMP/stub";     truncate -s 5000000 "$TMP/stub"
eq "a 500-byte file with no blocks is a real file (it lives in the record)" "$("$WA" "$TMP/resident" | cut -f1)" hydrated
eq "a 5 MB file with no blocks and no attribute is still doubted" "$("$WA" "$TMP/stub" | cut -f1)" suspect

echo
printf 'ferry-copy tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
