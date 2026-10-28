#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  ferry-copy over a REAL NTFS volume (a loop-mounted image).
#
#  Everything else in the suite uses a folder on ext4 that imitates
#  NTFS with xattrs. That cannot show the things only NTFS does:
#    - a file name Windows allows and this disk does not (120 Japanese
#      characters is 360 bytes of UTF-8; the limit here is 255);
#    - a small file whose bytes live inside the MFT record, which the
#      kernel reports as 0 blocks (it was flagged "may be a cloud
#      placeholder" - every small document of hers);
#    - whether the person's own uid can read what `mount_ro` mounted;
#    - a symbolic link on the volume, as ntfs-3g shows it.
#  The volume is mounted by the same mount_ro() Ferry uses, with the
#  same options, and read by an unprivileged uid.
#
#  Needs root, mkfs.ntfs, ntfs-3g and losetup; says SKIP without them.
#    sudo sh tests/ntfs.sh
# ═══════════════════════════════════════════════════════════════════
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FERRY=$(dirname "$HERE")

if [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        exec sudo -n env "TMPDIR=${TMPDIR:-/tmp}" PATH="$PATH" sh "$0" "$@"
    fi
    echo "  SKIP the NTFS tests (no root and no passwordless sudo): real NTFS was NOT exercised"
    exit 0
fi
for _t in mkfs.ntfs ntfs-3g losetup; do
    command -v "$_t" >/dev/null 2>&1 || PATH="$PATH:/sbin:/usr/sbin"
    command -v "$_t" >/dev/null 2>&1 || { echo "  SKIP the NTFS tests ($_t is not installed): real NTFS was NOT exercised"; exit 0; }
done

export NO_COLOR=1
PATH="$FERRY:$FERRY/build:$PATH"
FC="$FERRY/build/ferry-copy"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ferryntfs.XXXXXX")
chmod 755 "$TMP"
LOOP=""
cleanup() { umount "$TMP/m" 2>/dev/null; [ -z "$LOOP" ] || losetup -d "$LOOP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
assert() { _l=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_l"; else bad "$_l"; fi; }

echo "ferry-copy over real NTFS:"
U=61001; G=61002
truncate -s 48M "$TMP/img"
mkfs.ntfs -F -Q -L WIN "$TMP/img" >/dev/null 2>&1 || { echo "  SKIP mkfs.ntfs failed here"; exit 0; }
LOOP=$(losetup -f --show "$TMP/img") || { echo "  SKIP no loop device here"; exit 0; }
mkdir -p "$TMP/m"
mount -t ntfs-3g "$LOOP" "$TMP/m" 2>/dev/null || { echo "  SKIP cannot mount NTFS read-write to build the fixture"; exit 0; }
D="$TMP/m/Users/Bob/Documents"; mkdir -p "$D/Ünï"
LONG=$(python3 -c "print('日本語' * 40 + '.txt', end='')")           # 120 characters, 360 bytes
printf 'small' > "$D/a.txt"
head -c 300000 /dev/urandom > "$D/big.bin"
printf 'long' > "$D/$LONG"
printf 'accent' > "$D/Ünï/ç.txt"
ln -s /etc/hostname "$D/lnk"
BIGSUM=$(sha256sum < "$D/big.bin")
umount "$TMP/m"

for drv in ntfs3 ntfs-3g; do
    echo " ($drv)"
    H="$TMP/h-$drv"; install -d -o $U -g $G "$H"
    # the real mount_ro(), exactly as `ferry run` mounts a disk, with one driver chosen
    ( . "$FERRY/ferry-common.sh"; FERRY_MOUNT_FS=$drv; mount_ro "$LOOP" "$TMP/m" ) \
        || { if mountpoint -q "$TMP/m"; then bad "mount_ro failed although the volume mounted"; else echo "  SKIP the $drv driver is not available here"; fi; continue; }
    ok "mount_ro mounts the volume read-only ($drv) and agrees it is read-only"
    SRC="$TMP/m/Users/Bob/Documents"
    mkdir -p "$TMP/st-$drv/state"
    "$FC" --uid $U --gid $G --home "$H" --notes "$TMP/st-$drv/notes" --manifest "$TMP/st-$drv/manifest" \
        --state "$TMP/st-$drv" --job Documents "$SRC" "$H/Documents" >/dev/null 2>&1; rc=$?
    case $rc in 0|2) ok "the copy ran ($drv), exit $rc" ;; *) bad "ferry-copy exited $rc on $drv" ;; esac
    eq "she can read what the read-only mount gave and the small file arrived" "$(cat "$H/Documents/a.txt" 2>/dev/null)" small
    eq "a 300 KB file is intact" "$(sha256sum < "$H/Documents/big.bin" 2>/dev/null)" "$BIGSUM"
    eq "a file in an accented folder arrived" "$(cat "$H/Documents/Ünï/ç.txt" 2>/dev/null)" accent
    _long=$(find "$H/Documents" -maxdepth 1 -name '日本語*' | head -1)
    eq "the 360-byte Windows name arrived, shortened to fit" "$(cat "$_long" 2>/dev/null)" long
    [ -n "$_long" ] && [ "$(basename "$_long" | wc -c)" -le 256 ] && ok "...and the new name is within 255 bytes" || bad "the long name is not within 255 bytes: $_long"
    case "$_long" in *.txt) ok "...and kept its .txt" ;; *) bad "the extension was lost: $_long" ;; esac
    assert "...and the ledger says what happened" grep -q "was too long for this disk" "$TMP/st-$drv/notes"
    assert "a small file is not called a possible cloud placeholder" \
        sh -c "! grep -q 'online-only file)' '$TMP/st-$drv/notes'"
    eq "everything is hers" "$(find "$H" ! -user $U | wc -l | tr -d ' ')" 0
    if [ "$drv" = ntfs-3g ]; then
        [ ! -e "$H/Documents/lnk" ] && ok "a symbolic link on the volume was not copied" || bad "the link was copied"
        assert "...and is in the ledger" grep -q 'Documents/lnk' "$TMP/st-$drv/notes"
    fi
    umount "$TMP/m"
done

# ── the same checks, proven able to fail ────────────────────────────
echo " (proofs)"
# (1) the first version of the read-only check refused every mount
( . "$FERRY/ferry-common.sh"
  mounted_ro() { grep -q " $1 .*[(,]ro[,)]" /proc/mounts; }      # the old regex
  FERRY_MOUNT_FS=ntfs3; mount_ro "$LOOP" "$TMP/m" ) >/dev/null 2>&1; _old=$?
if mountpoint -q "$TMP/m"; then umount "$TMP/m"; bad "(proof) the old check left a mount behind"
elif [ $_old -ne 0 ]; then ok "(proof) the old /proc/mounts check refuses a perfectly good read-only mount, as it did on every machine"
else bad "(proof) the old check did not fail: this test cannot see that bug"; fi
# (2) without the 'small file' rule, a 3-byte document is flagged as a possible cloud stub
sed 's/if (st->st_size <= 1024) return "hydrated";/if (0) return "hydrated";/' "$FERRY/winattr.c" > "$TMP/winattr.c"
sed 's|#include "winattr.c"|#include "winattr.c"|' "$FERRY/copy.c" > "$TMP/copy.c"
cc -O1 -std=gnu11 -w -o "$TMP/fc-nosmall" "$TMP/copy.c" 2>/dev/null
if ! cmp -s "$TMP/winattr.c" "$FERRY/winattr.c" && [ -x "$TMP/fc-nosmall" ]; then
    ( . "$FERRY/ferry-common.sh"; FERRY_MOUNT_FS=ntfs3; mount_ro "$LOOP" "$TMP/m" ) >/dev/null 2>&1
    H="$TMP/h-mut"; install -d -o $U -g $G "$H"; mkdir -p "$TMP/st-mut/state"
    "$TMP/fc-nosmall" --uid $U --gid $G --home "$H" --notes "$TMP/st-mut/notes" \
        --job Documents "$TMP/m/Users/Bob/Documents" "$H/Documents" >/dev/null 2>&1
    umount "$TMP/m" 2>/dev/null
    assert "(proof) without the rule, small documents ARE flagged as possible stubs" grep -q 'online-only file)' "$TMP/st-mut/notes"
else bad "(proof) could not build the no-small-file-rule mutant"; fi

echo
printf 'ferry-copy NTFS tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
