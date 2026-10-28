# ═══════════════════════════════════════════════════════════════════
#  ferry-common.sh — the rules every Ferry tool obeys.
#
#  Sourced, never executed. Holds the four things that must be
#  identical in every stage or the guarantees are worthless:
#
#    1. the volume is mounted READ-ONLY, or not at all;
#    2. a hibernated or dirty volume is refused, with the reason said
#       out loud;
#    3. every write is idempotent — a Ferry that dies halfway and is
#       re-run does not duplicate, does not skip, does not overwrite;
#    4. anything not migrated is recorded, because the final report is
#       a product feature and a report is only worth the completeness
#       of what feeds it.
#
#  Style follows src/aurora/aurora: POSIX sh, `_`-prefixed locals (sh
#  has no lexical scope and busybox ash is the shell on the target),
#  no bashisms, no dependency beyond busybox + awk.
# ═══════════════════════════════════════════════════════════════════

FERRY_VERSION="0.1.0"

# Where Ferry keeps its mind. Everything here survives a reboot on
# purpose: first boot can be interrupted by a flat battery, and the
# second attempt must know what the first one already did.
: "${FERRY_STATE:=/var/lib/ferry}"
: "${FERRY_MNT:=/run/ferry/windows}"
: "${FERRY_ROOT:=}"          # an already-mounted Windows filesystem
: "${FERRY_DEV:=}"           # the block device to mount, if we mount
: "${FERRY_WINUSER:=}"       # which Windows profile to import
: "${FERRY_HOME:=}"          # destination home directory
: "${FERRY_OWNER:=}"         # destination user name
: "${FERRY_DRYRUN:=0}"
: "${FERRY_QUIET:=0}"
: "${FERRY_JSON:=0}"
: "${FERRY_FORCE:=0}"
: "${FERRY_PROGRESS:=}"      # optional file the UI tails, JSON lines
: "${FERRY_STAGE:=ferry}"
: "${FERRY_PLAIN:=0}"        # 1: plain words for her on stdout, chatter to stderr

# Tools and data ship together. Running straight out of the source tree
# has to work, because that is how this gets debugged.
FERRY_BIN=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /usr/lib/ferry)
if [ -d "$FERRY_BIN/data" ]; then FERRY_SHARE="$FERRY_BIN/data"
else FERRY_SHARE="${FERRY_SHARE:-/usr/share/ferry}"; fi
PATH="$FERRY_BIN:$FERRY_BIN/build:$PATH"
export PATH

# ── Voice. Same palette as aurora, so the whole system speaks with one.
#    The escapes are materialised now (a real ESC byte), not stored as
#    the two-character string "\033": these end up as printf ARGUMENTS,
#    where backslash escapes are not interpreted, so a literal "\033"
#    would print verbatim and colour nothing.
_ESC=$(printf '\033')
C_OK="${_ESC}[38;2;125;211;192m"; C_WARN="${_ESC}[38;2;242;184;128m"
C_ERR="${_ESC}[38;2;242;120;141m"; C_DIM="${_ESC}[38;2;110;120;134m"
C_RST="${_ESC}[0m"
# NO_COLOR, and a non-terminal stderr, drop the escapes: a UI capturing
# our stderr should not have to strip ANSI out of every line.
if [ -n "${NO_COLOR:-}" ] || [ ! -t 2 ]; then
    C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi
say()  { [ "$FERRY_QUIET" = 1 ] || printf '%s  ->%s %s\n' "$C_OK" "$C_RST" "$*" >&2; }
warn() { printf '%s  !!%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
dim()  { [ "$FERRY_QUIET" = 1 ] || printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RST" >&2; }
die()  { printf '%sferry:%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

# A refusal is a designed outcome, not a crash: it exits 3 so a caller
# can tell "we will not do this, and here is why" apart from "broke".
refuse() {
    printf '%sferry: refusing to continue%s\n  %s\n' "$C_ERR" "$C_RST" "$1" >&2
    [ -n "${2:-}" ] && printf '  %s%s%s\n' "$C_DIM" "$2" "$C_RST" >&2
    note blocked blocked "${3:-volume}" "$1"
    exit 3
}

# ── JSON escaping. Everything Ferry prints as JSON goes through here;
#    a filename is attacker-controlled data on a machine we did not
#    build, and one unescaped quote turns a report into a parse error.
jstr() {
    printf '%s' "$1" | awk '
    BEGIN { RS="\0" }
    {
        gsub(/\\/, "\\\\")
        gsub(/"/,  "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "")
        gsub(/\n/, "\\n")
        printf "%s", $0
    }'
}
jbool() { [ "${1:-0}" = 1 ] && printf 'true' || printf 'false'; }

# ── State layout.
ferry_state_init() {
    for _d in "$FERRY_STATE" "$FERRY_STATE/state" "$FERRY_STATE/report.d" \
              "$FERRY_STATE/plan"; do
        [ -d "$_d" ] || mkdir -p "$_d" || die "cannot create $_d"
    done
    [ -f "$FERRY_STATE/manifest.tsv" ] || : > "$FERRY_STATE/manifest.tsv"
}

now() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown; }

# ── Stage bookkeeping. `ferry run` reads these to skip what is already
#    done, which is the whole of resumability: a stage is a transaction
#    boundary, and file-level idempotency covers the inside of one.
stage_begin() {
    FERRY_STAGE=$1
    ferry_state_init
    printf 'running\t%s\n' "$(now)" > "$FERRY_STATE/state/$1.status"
}
stage_done() {
    printf 'done\t%s\t%s\n' "$(now)" "${2:-}" > "$FERRY_STATE/state/$1.status"
}
stage_fail() {
    printf 'failed\t%s\t%s\n' "$(now)" "${2:-}" > "$FERRY_STATE/state/$1.status"
}
stage_status() {
    cut -f1 "$FERRY_STATE/state/$1.status" 2>/dev/null || echo pending
}

# ── Progress. Ferry runs behind a UI that must be able to show a bar
#    without a socket, a daemon, or a protocol: the latest line lives in
#    a file the UI polls, and the full stream is appended to
#    $FERRY_PROGRESS when someone wants to tail it.
progress() {
    _st=$1 _done=$2 _total=$3 _msg=${4:-}
    _pct=0
    [ "$_total" -gt 0 ] 2>/dev/null && _pct=$(( _done * 100 / _total ))
    ferry_state_init
    _line=$(printf '{"type":"progress","stage":"%s","pct":%d,"done":%d,"total":%d,"message":"%s","at":"%s"}' \
            "$_st" "$_pct" "$_done" "$_total" "$(jstr "$_msg")" "$(now)")
    printf '%s\n' "$_line" > "$FERRY_STATE/state/$_st.progress"
    [ -n "$FERRY_PROGRESS" ] && printf '%s\n' "$_line" >> "$FERRY_PROGRESS"
    return 0
}

# ── The report ledger. One line per thing that did not fully migrate,
#    or that migrated with a caveat. ferry-report renders these; nothing
#    else is allowed to be the source of truth for what happened.
#      category  severity  item  detail
#    severity: blocked | partial | skipped | manual | info
note() {
    ferry_state_init
    _f="$FERRY_STATE/report.d/$FERRY_STAGE.tsv"
    _l=$(printf '%s\t%s\t%s\t%s' "$1" "$2" \
         "$(printf '%s' "$3" | tr '\t\n' '  ')" \
         "$(printf '%s' "$4" | tr '\t\n' '  ')")
    # Dedup so a resumed run does not say everything twice.
    if [ -f "$_f" ] && grep -qxF "$_l" "$_f" 2>/dev/null; then return 0; fi
    printf '%s\n' "$_l" >> "$_f"
    return 0
}

# ── The manifest. Every destination byte Ferry creates is written here
#    BEFORE it is useful to anyone, including the collisions it declined
#    to overwrite. "Never overwrite without recording" is enforced by
#    making the recording the only way to write.
record() {
    ferry_state_init
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$FERRY_STAGE" "$1" "${2:-0}" \
        "$(printf '%s' "${3:-}" | tr '\t\n' '  ')" \
        "$(printf '%s' "${4:-}" | tr '\t\n' '  ')" \
        >> "$FERRY_STATE/manifest.tsv"
    return 0
}

# ── Common options, shared by every tool so the flags mean the same
#    thing everywhere. Sets _consumed to the number of args eaten.
common_opt() {
    case ${1:-} in
        --root)     FERRY_ROOT=${2:?--root needs a path};       _consumed=2 ;;
        --device)   FERRY_DEV=${2:?--device needs a device};    _consumed=2 ;;
        --user)     FERRY_WINUSER=${2:?--user needs a name};    _consumed=2 ;;
        --home)     FERRY_HOME=${2:?--home needs a path};       _consumed=2 ;;
        --owner)    FERRY_OWNER=${2:?--owner needs a user};     _consumed=2 ;;
        --state)    FERRY_STATE=${2:?--state needs a path};     _consumed=2 ;;
        --progress) FERRY_PROGRESS=${2:?--progress needs a path}; _consumed=2 ;;
        --dry-run)  FERRY_DRYRUN=1; _consumed=1 ;;
        --quiet)    FERRY_QUIET=1;  _consumed=1 ;;
        --json)     FERRY_JSON=1;   _consumed=1 ;;
        --force)    FERRY_FORCE=1;  _consumed=1 ;;
        --plain)    FERRY_PLAIN=1;  _consumed=1 ;;
        *)          _consumed=0 ;;
    esac
}

# ═══ The Windows volume ═════════════════════════════════════════════

# NTFS is case-preserving but ntfs3 mounts are case-sensitive, and every
# path Ferry gets comes out of the registry with whatever capitalisation
# the program that wrote it happened to use. Resolve component by
# component or half the imports silently find nothing.
path_ci() {
    _base=$1 _rel=$2
    [ -n "$_base" ] || return 1
    if [ -e "$_base/$_rel" ]; then printf '%s\n' "$_base/$_rel"; return 0; fi
    _cur=$_base
    _oifs=$IFS; IFS='/'
    # shellcheck disable=SC2086
    set -- $_rel
    IFS=$_oifs
    for _c in "$@"; do
        [ -n "$_c" ] || continue
        if [ -e "$_cur/$_c" ]; then _cur="$_cur/$_c"; continue; fi
        _hit=$(ls -a "$_cur" 2>/dev/null | awk -v w="$_c" '
            BEGIN { lw = tolower(w) } tolower($0) == lw { print; exit }')
        [ -n "$_hit" ] || return 1
        _cur="$_cur/$_hit"
    done
    printf '%s\n' "$_cur"
}

# `C:\Users\bob\Documents` -> `Users/bob/Documents`, and the drive letter
# in _WIN_DRIVE. UNC paths (\\server\share) are not on this disk at all
# and are rejected so a caller reports them rather than inventing one.
win_to_rel() {
    _p=$1
    _WIN_DRIVE=""
    case "$_p" in
        '\\\\'*|'//'*) return 1 ;;
        [A-Za-z]:*)    _WIN_DRIVE=$(printf '%s' "$_p" | cut -c1)
                       _p=$(printf '%s' "$_p" | cut -c3-) ;;
    esac
    printf '%s\n' "$_p" | tr '\\' '/' | sed 's,^/*,,; s,/*$,,'
}

# Expand the %TOKENS% the registry stores instead of paths.
#
# Done with shell string surgery rather than sed on purpose: the
# replacement text is a Windows path, and every backslash in it is a
# metacharacter to sed. `%USERPROFILE%` -> `C:\Users\Bob` through sed
# gives `C:SERSBOB`, because GNU sed reads the `\U` as "uppercase the
# rest". That bug would have silently emptied every imported folder.
#
# Unknown tokens are left standing, so the caller sees a path it cannot
# use and reports it, instead of receiving a plausible wrong path.
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

token_value() {
    _drv=C:
    case "$_WIN_PROFILE" in [A-Za-z]:*) _drv=$(printf '%s' "$_WIN_PROFILE" | cut -c1-2) ;; esac
    case "$(lower "$1")" in
        userprofile)   printf '%s' "$_WIN_PROFILE" ;;
        homedrive)     printf '%s' "$_drv" ;;
        homepath)      printf '%s' "$(printf '%s' "$_WIN_PROFILE" | cut -c3-)" ;;
        appdata)       printf '%s\\AppData\\Roaming' "$_WIN_PROFILE" ;;
        localappdata)  printf '%s\\AppData\\Local' "$_WIN_PROFILE" ;;
        temp|tmp)      printf '%s\\AppData\\Local\\Temp' "$_WIN_PROFILE" ;;
        username)      printf '%s' "${_WIN_USERNAME:-}" ;;
        systemdrive)   printf '%s:' "${_WIN_SYSDRIVE:-C}" ;;
        systemroot|windir) printf '%s:\\Windows' "${_WIN_SYSDRIVE:-C}" ;;
        public)        printf '%s:\\Users\\Public' "${_WIN_SYSDRIVE:-C}" ;;
        programdata|allusersprofile) printf '%s:\\ProgramData' "${_WIN_SYSDRIVE:-C}" ;;
        programfiles)  printf '%s:\\Program Files' "${_WIN_SYSDRIVE:-C}" ;;
        onedrive|onedriveconsumer|onedrivecommercial)
            [ -n "${_WIN_ONEDRIVE:-}" ] || return 1
            printf '%s' "$_WIN_ONEDRIVE" ;;
        *) return 1 ;;
    esac
}

expand_tokens() {
    _s=$1 _out="" _pct='%'
    while :; do
        case "$_s" in
            *"$_pct"*"$_pct"*) : ;;
            *) break ;;
        esac
        _pre=${_s%%"$_pct"*}
        _rest=${_s#*"$_pct"}
        _tok=${_rest%%"$_pct"*}
        _post=${_rest#*"$_pct"}
        if _val=$(token_value "$_tok"); then
            _out="$_out$_pre$_val"
        else
            _out="$_out$_pre$_pct$_tok$_pct"
        fi
        _s=$_post
    done
    printf '%s%s\n' "$_out" "$_s"
}

# ── Volume health. Prints `STATE<TAB>REASON`.
#    clean | hibernated | dirty | unknown
#
#    Hibernation is the one that matters in practice, and not because of
#    corruption risk — we only ever mount read-only. It is because a
#    hibernated volume is STALE: the newest version of the user's work
#    is in the hibernation image, not in the files. Importing from it
#    copies yesterday's spreadsheet and tells the user it is today's.
#    Windows 8+ "Fast Startup" makes an ordinary shutdown produce
#    exactly this state, so it is the common case, not the rare one.
vol_state() {
    _root=$1 _dev=${2:-}

    _hib=$(path_ci "$_root" "hiberfil.sys" 2>/dev/null || true)
    if [ -n "$_hib" ] && [ -s "$_hib" ]; then
        _sig=$(dd if="$_hib" bs=4 count=1 2>/dev/null | od -An -tx1 2>/dev/null \
               | tr -d ' \n')
        case "$_sig" in
            00000000|"") : ;;   # hibernation enabled, no image: harmless
            *) printf 'hibernated\thiberfil.sys holds a live hibernation image (signature %s)\n' "$_sig"
               return 0 ;;
        esac
    fi

    if command -v ntfs-3g.probe >/dev/null 2>&1 && [ -n "$_dev" ]; then
        ntfs-3g.probe --readonly "$_dev" >/dev/null 2>&1
        case $? in
            0)  : ;;
            14) printf 'hibernated\tntfs-3g reports the volume is hibernated\n'; return 0 ;;
            15) printf 'dirty\tntfs-3g reports an unclean unmount\n'; return 0 ;;
            16) printf 'dirty\tthe volume is locked by another system\n'; return 0 ;;
            13) printf 'dirty\tntfs-3g reports the volume is corrupt\n'; return 0 ;;
            *)  printf 'unknown\tntfs-3g.probe could not classify the volume\n'; return 0 ;;
        esac
    fi
    if command -v ntfsinfo >/dev/null 2>&1 && [ -n "$_dev" ]; then
        if ntfsinfo -m "$_dev" 2>/dev/null | grep -qi 'volume is dirty'; then
            printf 'dirty\tthe NTFS volume dirty flag is set; Windows wants to run chkdsk\n'
            return 0
        fi
    fi

    # No probe tool available. Say so rather than claim a clean bill of
    # health we did not check for.
    if [ -z "$_dev" ] || ! command -v ntfs-3g.probe >/dev/null 2>&1; then
        printf 'clean\tno dirty flag and no hibernation image found (dirty-bit probe unavailable)\n'
        return 0
    fi
    printf 'clean\tno hibernation image, no dirty flag\n'
}

# Every importing stage calls this first. Detection does not — its job
# is to explain the refusal to the user, so it must survive it.
require_clean_volume() {
    _root=$1 _dev=${2:-}
    _vs=$(vol_state "$_root" "$_dev")
    _state=$(printf '%s' "$_vs" | cut -f1)
    _why=$(printf '%s' "$_vs" | cut -f2)
    case "$_state" in
        clean) return 0 ;;
        hibernated)
            refuse "the Windows partition is hibernated — $_why" \
"Fully shut Windows down and try again. On Windows 8 or newer, 'Shut down' is
   not enough by default: hold Shift while clicking Restart, or turn off Fast
   Startup in Control Panel > Power Options > Choose what the power buttons do.
   Ferry will not import from a hibernated disk, because the newest copy of
   your files is inside the hibernation image, not in the files themselves." \
            "windows-volume" ;;
        dirty)
            refuse "the Windows partition is marked dirty — $_why" \
"Boot Windows once and let it finish checking the disk, then shut down
   properly. Importing from a filesystem Windows has not finished repairing
   can copy half-written files." "windows-volume" ;;
        *)
            [ "$FERRY_FORCE" = 1 ] && { warn "volume state unknown ($_why); --force given, continuing"; return 0; }
            refuse "cannot establish the state of the Windows partition — $_why" \
"Install ntfs-3g (for ntfs-3g.probe) so Ferry can check the dirty flag, or
   re-run with --force if you are certain Windows was shut down cleanly." \
            "windows-volume" ;;
    esac
}

# Mount read-only. There is no code path in Ferry that mounts otherwise;
# the `ro` is passed twice (driver option and mount flag) on purpose,
# because one typo here is the difference between a migration and a
# destroyed Windows install.
# Is this mount point mounted, and read-only? /proc/mounts lists the
# options as one comma-separated word ("ro,relatime,..."), with "ro" FIRST,
# so it is never preceded by a comma or a bracket. The first version of
# this check looked for one and so failed every mount it was ever given:
# Ferry could not mount a Windows disk at all, and no test noticed
# because no test mounted anything (tests/ntfs.sh does now).
mounted_ro() {
    awk -v m="$1" '$2 == m { n = split($4, o, ","); r = 0; w = 0
                             for (i = 1; i <= n; i++) { if (o[i] == "ro") r = 1; if (o[i] == "rw") w = 1 }
                             found = 1; ok = (r && !w) }
                   END { exit !(found && ok) }' /proc/mounts 2>/dev/null
}

# FERRY_MOUNT_FS: which drivers to try, in order (the tests pick one).
mount_ro() {
    _dev=$1 _mnt=$2
    mkdir -p "$_mnt" || return 1
    if mountpoint -q "$_mnt" 2>/dev/null; then return 0; fi
    for _fs in ${FERRY_MOUNT_FS:-ntfs3 ntfs ntfs-3g}; do
        if mount -t "$_fs" -o ro,noatime,nosuid,nodev,noexec \
                 "$_dev" "$_mnt" 2>/dev/null; then
            # Belt and braces: verify the kernel agrees it is read-only.
            if mounted_ro "$_mnt"; then
                return 0
            fi
            umount "$_mnt" 2>/dev/null || true
            return 1
        fi
    done
    return 1
}
unmount_ro() { umount "$1" 2>/dev/null || true; }

# A Windows install is exactly one thing: System32 under a Windows dir.
# Not the presence of `Users`, which every disk imaged from a backup has.
is_windows_root() {
    [ -n "$(path_ci "$1" "Windows/System32" 2>/dev/null)" ]
}

# ═══ Registry ═══════════════════════════════════════════════════════

# ferry-hive prefers hivexget and falls back to our own reader; this
# wrapper exists so no stage has to care which one answered.
hive_get() {
    ferry-hive get "$1" "$2" "$3" 2>/dev/null || return 1
}
hive_values() { ferry-hive values "$1" "$2" 2>/dev/null || return 1; }
hive_keys()   { ferry-hive keys   "$1" "$2" 2>/dev/null || return 1; }

# ═══ Destination ════════════════════════════════════════════════════

# Who are we importing FOR. On a first boot there is exactly one real
# user; guessing wrong would scatter somebody's documents into /root, so
# there is no fallback to root's own home: no person, no import.
# FERRY_UID / FERRY_GID are what ferry-copy becomes before it touches a
# single path of hers.
resolve_target() {
    if [ -z "$FERRY_OWNER" ]; then
        FERRY_OWNER=$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" { print $1; exit }' \
                      /etc/passwd 2>/dev/null || true)
        # A developer running from a checkout, not as root: themselves.
        if [ -z "$FERRY_OWNER" ] && [ "$(id -u)" != 0 ]; then FERRY_OWNER=$(id -un); fi
    fi
    [ -n "$FERRY_OWNER" ] || die "there is no person on this computer to bring the files to"
    FERRY_UID=$(id -u "$FERRY_OWNER" 2>/dev/null) && FERRY_GID=$(id -g "$FERRY_OWNER" 2>/dev/null) \
        || die "no such user '$FERRY_OWNER'"
    if [ -z "$FERRY_HOME" ]; then
        FERRY_HOME=$(awk -F: -v u="$FERRY_OWNER" '$1 == u { print $6; exit }' \
                     /etc/passwd 2>/dev/null || true)
    fi
    [ -n "$FERRY_HOME" ] || die "cannot find the home folder of '$FERRY_OWNER'"
}

# XDG user dirs, honouring a localized user-dirs.dirs if the desktop has
# already written one (a French install wants Documents in Documents,
# a German one in Dokumente).
xdg_dir() {
    _key=$1 _default=$2
    _f="$FERRY_HOME/.config/user-dirs.dirs"
    if [ -f "$_f" ]; then
        _v=$(sed -n "s/^[[:space:]]*$_key=\"\{0,1\}\(.*\)\"\{0,1\}[[:space:]]*\$/\1/p" \
             "$_f" | head -1 | sed 's/"$//')
        if [ -n "$_v" ]; then
            _v=$(printf '%s' "$_v" | sed "s|^\$HOME|$FERRY_HOME|")
            # Only a place under her home, and never a way out of it: the
            # file is hers to edit, and what it says becomes a path.
            case "$_v" in
                "$FERRY_HOME"/*)
                    case "/$_v/" in */../*|*/./*) ;; *) printf '%s\n' "$_v"; return 0 ;; esac ;;
            esac
        fi
    fi
    printf '%s\n' "$FERRY_HOME/$_default"
}

# ═══ Copying ════════════════════════════════════════════════════════
#
# NOTHING IN FERRY WRITES INTO HER HOME AS ROOT. Her home is hers: a
# program running as her can put a symbolic link anywhere in it, and a
# root `cp`, `mkdir -p`, `chown -R` or `> file` would follow it. Every
# write there goes through ferry-copy, which gives up root before it
# opens a path of hers and never follows a link (src/ferry/copy.c). The
# test suite greps this tree for the old habits and plants hostile links
# to prove it.

# Copy folders or files as her. Arguments after the options are
# `--job LABEL SRCDIR DESTDIR` / `--file LABEL SRCFILE DESTFILE`.
# Notes ferry-copy wrote are folded into the report. Exit codes:
# 0 all done, 2 done but some things were not copied (already in the
# report), anything else is a stop.
her_copy() {
    _hc_notes="$FERRY_STATE/plan/$FERRY_STAGE.notes"
    : > "$_hc_notes"
    _hc_rc=0
    ferry-copy --uid "$FERRY_UID" --gid "$FERRY_GID" --home "$FERRY_HOME" \
        --stage "$FERRY_STAGE" --notes "$_hc_notes" \
        --manifest "$FERRY_STATE/manifest.tsv" --state "$FERRY_STATE" \
        ${FERRY_PROGRESS:+--progress "$FERRY_PROGRESS"} \
        $([ "${FERRY_PLAIN:-0}" = 1 ] && echo --plain) \
        $([ "$FERRY_DRYRUN" = 1 ] && echo --dry-run) \
        "$@" || _hc_rc=$?
    merge_notes "$_hc_notes"
    return "$_hc_rc"
}

# Append ferry-copy's ledger rows to this stage's ledger, skipping rows
# already there (a resumed run must not say everything twice).
merge_notes() {
    ferry_state_init
    _mn_l="$FERRY_STATE/report.d/$FERRY_STAGE.tsv"
    [ -f "$_mn_l" ] || : > "$_mn_l"
    awk 'NR==FNR { seen[$0] = 1; next } !($0 in seen) { seen[$0] = 1; print }' \
        "$_mn_l" "$1" >> "$_mn_l"
    rm -f "$1"
}

# Write stdin to one file in her home, as her (atomically, no link
# followed). Extra options: --keep-existing, --backup SUFFIX.
her_put() {
    _hp_dest=$1; shift
    [ "$FERRY_DRYRUN" = 1 ] && { cat >/dev/null; return 0; }
    ferry-copy put --uid "$FERRY_UID" --gid "$FERRY_GID" --home "$FERRY_HOME" \
        "$@" "$_hp_dest"
}

# ── Deterministic UUIDs. NetworkManager wants a UUID per connection;
#    a random one would make every re-run create a duplicate connection
#    for the same network. Derived from the name instead, so a second
#    run produces the same UUID and therefore the same file.
stable_uuid() {
    _h=$(printf 'ferry:%s' "$1" | md5sum 2>/dev/null | cut -c1-32)
    [ -n "$_h" ] || _h=$(printf 'ferry:%s' "$1" | cksum | tr -d ' ' | cut -c1-32)
    while [ ${#_h} -lt 32 ]; do _h="${_h}0"; done
    printf '%s-%s-4%s-8%s-%s\n' \
        "$(printf '%s' "$_h" | cut -c1-8)"  "$(printf '%s' "$_h" | cut -c9-12)" \
        "$(printf '%s' "$_h" | cut -c14-16)" "$(printf '%s' "$_h" | cut -c18-20)" \
        "$(printf '%s' "$_h" | cut -c21-32)"
}

# ═══ Profiles and known folders ═════════════════════════════════════
#
# Shared by detect, files, firefox and settings on purpose. If two
# stages disagreed about where a user's Documents folder is, one of them
# would import nothing and say it succeeded.

win_hive() {   # SOFTWARE | SYSTEM | SECURITY | SAM
    path_ci "$FERRY_ROOT" "Windows/System32/config/$1" 2>/dev/null || return 1
}

# Every profile the machine knows about, authoritative source first.
# Prints:  SID <tab> USERNAME <tab> WINDOWS_PATH <tab> KIND
# KIND is `user` or `system`; nothing is dropped silently, because a
# profile we hid is a profile the user cannot ask us to import.
list_profiles() {
    _soft=$(win_hive SOFTWARE || true)
    _any=0
    if [ -n "$_soft" ]; then
        for _sid in $(hive_keys "$_soft" 'Microsoft\Windows NT\CurrentVersion\ProfileList' 2>/dev/null); do
            _pip=$(hive_get "$_soft" \
                   "Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\$_sid" \
                   ProfileImagePath 2>/dev/null || true)
            [ -n "$_pip" ] || continue
            _nm=$(printf '%s' "$_pip" | sed 's,.*\\,,')
            _kind=user
            case "$_sid" in S-1-5-21-*) ;; *) _kind=system ;; esac
            case "$_pip" in *ServiceProfiles*|*systemprofile*) _kind=system ;; esac
            case "$_nm" in defaultuser*|Default|Public|"All Users") _kind=system ;; esac
            printf '%s\t%s\t%s\t%s\n' "$_sid" "$_nm" "$_pip" "$_kind"
            _any=1
        done
    fi
    # Fallback: the SOFTWARE hive was unreadable. Directory names are a
    # worse answer (they miss redirected profiles and keep deleted ones)
    # but a worse answer beats "no users found" on a disk full of them.
    if [ "$_any" = 0 ]; then
        _users=$(path_ci "$FERRY_ROOT" "Users" 2>/dev/null || true)
        [ -n "$_users" ] || return 0
        for _d in "$_users"/*; do
            [ -d "$_d" ] || continue
            _nm=$(basename "$_d")
            _kind=user
            case "$_nm" in defaultuser*|Default*|Public|"All Users"|desktop.ini) _kind=system ;; esac
            printf '-\t%s\t%s\t%s\n' "$_nm" "C:\\Users\\$_nm" "$_kind"
        done
    fi
}

# Pick the profile to import. Sets _WIN_USERNAME, _WIN_PROFILE (Windows
# path), _WIN_PROFILE_DIR (absolute, on the mount), _WIN_SID, _WIN_NTUSER
# and _WIN_ONEDRIVE. Everything downstream reads these.
select_profile() {
    _want=${1:-$FERRY_WINUSER}
    _rows=$(list_profiles | awk -F'\t' '$4 == "user"')
    [ -n "$_rows" ] || return 1
    if [ -n "$_want" ]; then
        _row=$(printf '%s\n' "$_rows" | awk -F'\t' -v w="$_want" \
               'tolower($2) == tolower(w) { print; exit }')
    else
        _n=$(printf '%s\n' "$_rows" | wc -l)
        if [ "$_n" -gt 1 ]; then
            # Refuse to guess between real people's accounts.
            _row=""
        else
            _row=$_rows
        fi
    fi
    [ -n "$_row" ] || return 1

    _WIN_SID=$(printf '%s' "$_row" | cut -f1)
    _WIN_USERNAME=$(printf '%s' "$_row" | cut -f2)
    _WIN_PROFILE=$(printf '%s' "$_row" | cut -f3)
    _WIN_PROFILE_DIR=$(path_ci "$FERRY_ROOT" "$(win_to_rel "$_WIN_PROFILE")" 2>/dev/null || true)
    [ -n "$_WIN_PROFILE_DIR" ] || return 1
    _WIN_NTUSER=$(path_ci "$_WIN_PROFILE_DIR" "NTUSER.DAT" 2>/dev/null || true)
    _WIN_ONEDRIVE=$(onedrive_root "$_WIN_NTUSER")
    return 0
}

# OneDrive's own idea of where it syncs, which is not always
# %USERPROFILE%\OneDrive and is what %OneDrive% in a redirected known
# folder expands to.
onedrive_root() {
    _h=${1:-}
    [ -n "$_h" ] && [ -f "$_h" ] || { printf ''; return 0; }
    for _acct in Personal Business1 Business2; do
        _v=$(hive_get "$_h" "Software\\Microsoft\\OneDrive\\Accounts\\$_acct" \
             UserFolder 2>/dev/null || true)
        if [ -n "$_v" ]; then printf '%s\n' "$_v"; return 0; fi
    done
    printf ''
}

# The six folders the spec names, with the registry value that owns each
# and where they land on this side. Value names are not guessable —
# Documents is `Personal` and Downloads is a raw GUID — so they live in
# exactly one place.
#   LABEL | registry value | XDG key | default folder
FERRY_FOLDERS='Desktop|Desktop|XDG_DESKTOP_DIR|Desktop
Documents|Personal|XDG_DOCUMENTS_DIR|Documents
Downloads|{374DE290-123F-4565-9164-39C4925E467B}|XDG_DOWNLOAD_DIR|Downloads
Pictures|My Pictures|XDG_PICTURES_DIR|Pictures
Music|My Music|XDG_MUSIC_DIR|Music
Videos|My Video|XDG_VIDEOS_DIR|Videos'

USF_KEY='Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
SF_KEY='Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'

# Where one known folder actually is. NEVER assume the default: a
# OneDrive "back up your folders" prompt silently moves Desktop,
# Documents and Pictures into the sync root, and on a machine where that
# was accepted, importing %USERPROFILE%\Documents imports an empty
# folder and reports success.
#
# Prints: STATUS <tab> ABSOLUTE_PATH <tab> SOURCE <tab> RAW_REGISTRY_VALUE
# STATUS: ok | missing | off-volume | unc
resolve_known_folder() {
    _valname=$1 _default=$2
    _raw="" _src=default
    if [ -n "${_WIN_NTUSER:-}" ] && [ -f "$_WIN_NTUSER" ]; then
        _raw=$(hive_get "$_WIN_NTUSER" "$USF_KEY" "$_valname" 2>/dev/null || true)
        [ -n "$_raw" ] && _src=user-shell-folders
        if [ -z "$_raw" ]; then
            _raw=$(hive_get "$_WIN_NTUSER" "$SF_KEY" "$_valname" 2>/dev/null || true)
            [ -n "$_raw" ] && _src=shell-folders
        fi
    fi
    [ -n "$_raw" ] || _raw="$_WIN_PROFILE\\$_default"
    _exp=$(expand_tokens "$_raw")
    case "$_exp" in
        '\\\\'*) printf 'unc\t\t%s\t%s\n' "$_src" "$_raw"; return 0 ;;
        *%*)         printf 'unresolved\t\t%s\t%s\n' "$_src" "$_raw"; return 0 ;;
    esac
    # A redirect onto another drive letter points at a disk we have not
    # mounted (a second internal drive, a USB disk that is not here).
    # Say so; never quietly fall back to the default path, which would
    # import an empty folder and call it a success.
    #
    # The drive letter is read here rather than from win_to_rel because
    # win_to_rel runs in a command substitution — a subshell — and any
    # variable it sets dies with it.
    case "$_exp" in
        [A-Za-z]:*)
            _a=$(printf '%s' "$_exp" | cut -c1 | tr 'a-z' 'A-Z')
            _b=$(printf '%s' "${_WIN_SYSDRIVE:-C}" | tr 'a-z' 'A-Z')
            if [ "$_a" != "$_b" ]; then
                printf 'off-volume\t\t%s\t%s\n' "$_src" "$_raw"; return 0
            fi ;;
    esac
    _rel=$(win_to_rel "$_exp") || { printf 'unc\t\t%s\t%s\n' "$_src" "$_raw"; return 0; }
    _abs=$(path_ci "$FERRY_ROOT" "$_rel" 2>/dev/null || true)
    if [ -z "$_abs" ] || [ ! -d "$_abs" ]; then
        printf 'missing\t\t%s\t%s\n' "$_src" "$_raw"; return 0
    fi
    printf 'ok\t%s\t%s\t%s\n' "$_abs" "$_src" "$_raw"
}
