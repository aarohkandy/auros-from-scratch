/* ═══════════════════════════════════════════════════════════════════
 *  ferry-copy — copy her files across, as HER, and never as root.
 *
 *  WHY THIS IS C. The first Ferry copied with `cp` and `mkdir -p` and
 *  `chown -R`, as root, into paths under her home. Her home is hers: any
 *  program running as her can put a symbolic link in it (`~/Pictures ->
 *  /etc/cron.d`), and root then writes Windows-side content wherever the
 *  link points. That is a local privilege escalation. A shell cannot fix
 *  it: `cp` follows links, and a check followed by a write is a race she
 *  wins. So the whole copy is here, and it is built on two rules:
 *
 *    1. THE COPY RUNS AS HER UID. The first thing this program does,
 *       before it opens a single path of hers or of the Windows disk, is
 *       open the few root-owned files it needs (the ledger, the manifest,
 *       the progress file), and then give up root for good: groups
 *       cleared, gid and uid set, no way back (PR_SET_NO_NEW_PRIVS, and
 *       a setuid(0) that must fail is checked). After that, a link she
 *       plants can only make HER write somewhere SHE could already write.
 *       Nothing she controls is ever written by root.
 *    2. NO LINK IS EVER FOLLOWED. Not on the Windows side (a junction or
 *       symlink inside Documents is reported, never entered) and not on
 *       hers (every destination directory is walked one name at a time
 *       with openat(O_NOFOLLOW); a link where a folder should be is
 *       refused and said out loud). Defence in depth: rule 2 keeps her
 *       files from silently landing somewhere else; rule 1 means that
 *       even if rule 2 had a hole, it is not a root hole.
 *
 *  Also, in one process for all six folders, so a 40 000-photo import
 *  costs bytes and not forks:
 *    - a first pass classifies everything (winattr.c's rules: a cloud
 *      placeholder is never copied as a stub) and totals the BYTES that
 *      will really be copied; the second pass copies. Progress is
 *      byte-weighted, and the time left is only said once it is known.
 *    - a file is written to a temp name, its mtime set, and moved into
 *      place with renameat2(RENAME_NOREPLACE): a half copy never has the
 *      real name, and a file already there is never overwritten -- the
 *      Windows copy lands beside it as "name (from Windows).ext", then
 *      "(from Windows 2)", and so on.
 *    - names Windows allows and ext4 does not (up to 765 bytes of UTF-8
 *      against a limit of 255) are shortened at a character boundary,
 *      keeping the extension, with a short hash so two long names that
 *      begin the same do not become one. Non-ASCII names pass through
 *      byte for byte.
 *    - the destination filesystem is flushed every few seconds and the
 *      manifest rows are written only after the flush, so a row in the
 *      manifest means the bytes are on disk.
 *
 *    ferry-copy [options] --job LABEL SRCDIR DESTDIR ...    copy folders
 *                         --file LABEL SRCFILE DESTFILE     copy one file
 *    ferry-copy put [options] DESTFILE < data               write a file as her
 *
 *  options   --uid N --gid N        who to become (never 0)
 *            --home DIR             her home; every destination is under it
 *            --stage NAME           ledger/manifest stage (default files)
 *            --notes FILE           ledger rows (category severity item detail)
 *            --manifest FILE        manifest rows; also read, to know what
 *                                   an earlier run of ours already wrote
 *            --state DIR            write DIR/state/STAGE.progress (JSON)
 *            --progress FILE        append every progress line (JSON)
 *            --plain                one plain-English line a second on stdout
 *            --dry-run              classify and count; write nothing
 *            --skip-dir NAME        never copy a folder of this name (any depth)
 *            --skip-file NAME       never copy a file of this name (any depth)
 *            --keep-existing        (put) never replace an existing file
 *            --backup SUFFIX        (put) keep the old file as FILE+SUFFIX
 *
 *  exit 0 all done · 1 error · 2 done, but some things were not copied
 *       3 refused (home is not hers) · 4 out of room · 5 file exists (put)
 * ═══════════════════════════════════════════════════════════════════ */
#define _GNU_SOURCE
#define WINATTR_AS_LIBRARY 1
#include "winattr.c"

#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <sys/prctl.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>

#define BUFSZ      (1u << 20)
#define MAXDEPTH   48
#define MAXPATHBUF 8192
#define MAXJOBS    16
#define MAXSKIP    32
#define NOTE_CAP   300        /* named ledger rows per kind, then "and N more" */

/* ── state ───────────────────────────────────────────────────────── */
enum { K_PLACEHOLDER, K_ENCRYPTED, K_REPARSE, K_UNKNOWN, K_LINK, K_FAILED,
       K_SUSPECT, K_COLLISION, K_RENAMED, K_UNREADABLE, K_NKINDS };

struct tally {
    uint64_t copied, already, placeholder, suspect, reparse, encrypted,
             unknown, links, failed, junk, renamed, collisions, bytes;
};

struct job {
    const char *label, *src, *dest;
    int is_file;
    int ok;                       /* planned and openable */
    struct tally t;
    uint64_t files_total, bytes_total, files_done;
};

static uid_t g_uid;
static gid_t g_gid;
static int   g_dry, g_plain;
static const char *g_stage = "files";
static const char *g_home;
static int   g_notes = -1, g_manifest = -1, g_prog = -1, g_progs = -1;
static int   g_homefd = -1;
static size_t g_namemax = 255;
static long  g_interval_ms = 1000;
static dev_t g_srcdev;

static const char *g_skipdir[MAXSKIP], *g_skipfile[MAXSKIP];
static int g_nskipdir, g_nskipfile;

static char **g_ours;             /* destinations an earlier run of ours wrote */
static size_t g_nours;

static uint64_t g_total_bytes, g_total_files, g_done_bytes, g_done_files,
                g_copied_bytes;
static struct timespec g_t0, g_last_tick, g_last_sync;
static uint64_t g_since_sync;
static int g_fatal;               /* out of room: stop everything */
static int g_incomplete;          /* something was not copied */
static unsigned char *g_buf;

static char *g_mbuf;              /* manifest rows waiting for the next flush */
static size_t g_mlen, g_mcap;

static uint64_t g_kind_n[K_NKINDS];

/* ── small things ────────────────────────────────────────────────── */
static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void die(const char *fmt, ...)
{
    va_list ap;
    fputs("ferry-copy: ", stderr);
    va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

static void xwrite(int fd, const char *p, size_t n)
{
    while (n) {
        ssize_t k = write(fd, p, n);
        if (k < 0) { if (errno == EINTR) continue; return; }
        p += k; n -= (size_t)k;
    }
}

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void clean_field(char *s)
{
    for (; *s; s++) if (*s == '\t' || *s == '\n' || *s == '\r') *s = ' ';
}

/* One ledger row. Same four columns ferry-common.sh's note() writes;
 * a file name with a tab or a newline in it cannot add a column. */
static void note(const char *sev, const char *item, const char *detail)
{
    char it[MAXPATHBUF + 512], de[1024], line[MAXPATHBUF + 2048];
    int n;
    if (g_notes < 0) return;
    snprintf(it, sizeof it, "%s", item);
    snprintf(de, sizeof de, "%s", detail);
    clean_field(it); clean_field(de);
    n = snprintf(line, sizeof line, "%s\t%s\t%s\t%s\n", g_stage, sev, it, de);
    if (n < 0) return;
    if ((size_t)n >= sizeof line) { n = (int)sizeof line - 1; line[n - 1] = '\n'; }
    xwrite(g_notes, line, (size_t)n);
}

/* A named ledger row, but only the first NOTE_CAP of each kind: a folder
 * of 200 000 online-only photos must not become a 200 000 line report. */
static void note_kind(int kind, const char *sev, const char *label,
                      const char *rel, const char *detail)
{
    char item[MAXPATHBUF + 512];
    g_kind_n[kind]++;
    if (g_kind_n[kind] > NOTE_CAP) return;
    snprintf(item, sizeof item, "%s/%s", label, rel);
    note(sev, item, detail);
}

static void note_overflow(void)
{
    static const struct { int kind; const char *sev, *what; } k[] = {
        { K_PLACEHOLDER, "skipped", "online-only files" },
        { K_ENCRYPTED,   "blocked", "encrypted files" },
        { K_REPARSE,     "skipped", "links and special folders" },
        { K_UNKNOWN,     "skipped", "files that could not be identified" },
        { K_LINK,        "skipped", "links" },
        { K_FAILED,      "partial", "files that could not be copied" },
        { K_SUSPECT,     "partial", "files to double-check" },
        { K_COLLISION,   "partial", "files that already had a copy" },
        { K_UNREADABLE,  "partial", "files that could not be read" },
    };
    size_t i;
    for (i = 0; i < sizeof k / sizeof k[0]; i++)
        if (g_kind_n[k[i].kind] > NOTE_CAP) {
            char d[160];
            snprintf(d, sizeof d, "and %llu more %s, not listed one by one",
                     (unsigned long long)(g_kind_n[k[i].kind] - NOTE_CAP), k[i].what);
            note(k[i].sev, "(more)", d);
        }
}

static void iso_now(char *out, size_t n)
{
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, n, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

/* Manifest rows are held until the destination has been flushed. src
 * and dst are file names: a tab or newline in one cannot add a column. */
static void mrow(const char *action, uint64_t size, const char *src, const char *dst)
{
    char ts[32], *cs = strdup(src), *cd = strdup(dst);
    size_t need = strlen(src) + strlen(dst) + 160;
    if (!cs || !cd) die("out of memory");
    clean_field(cs); clean_field(cd);
    iso_now(ts, sizeof ts);
    if (g_mlen + need > g_mcap) {
        g_mcap = (g_mcap + need) * 2;
        g_mbuf = realloc(g_mbuf, g_mcap);
        if (!g_mbuf) die("out of memory");
    }
    g_mlen += (size_t)sprintf(g_mbuf + g_mlen, "%s\t%s\t%s\t%llu\t%s\t%s\n", ts, g_stage, action,
                              (unsigned long long)size, cs, cd);
    free(cs); free(cd);
}

static void mflush(void)
{
    if (g_manifest >= 0 && g_mlen) {
        xwrite(g_manifest, g_mbuf, g_mlen);
        fdatasync(g_manifest);
    }
    g_mlen = 0;
}

static void sync_now(void)
{
    if (g_homefd >= 0 && !g_dry) syncfs(g_homefd);
    mflush();
    g_since_sync = 0;
    clock_gettime(CLOCK_MONOTONIC, &g_last_sync);
}

/* ── names ───────────────────────────────────────────────────────── */
static size_t cut_utf8(const char *s, size_t n)
{
    while (n > 0 && ((unsigned char)s[n] & 0xC0) == 0x80) n--;
    return n;
}

static uint32_t fnv(const char *s)
{
    uint32_t h = 2166136261u;
    for (; *s; s++) { h ^= (unsigned char)*s; h *= 16777619u; }
    return h;
}

/* The extension to keep, or NULL. Short, and not the whole name. */
static const char *ext_of(const char *name)
{
    const char *d = strrchr(name, '.');
    if (!d || d == name || strlen(d) > 16 || d[1] == '\0') return NULL;
    return d;
}

/* A name that fits this filesystem. Windows allows 255 UTF-16 units: up
 * to 765 bytes of UTF-8 against ext4's 255. Returns 1 when it changed. */
static int fit_name(const char *name, char *out, int is_dir)
{
    size_t len = strlen(name), keep, el;
    const char *e;
    if (len <= g_namemax) { memcpy(out, name, len + 1); return 0; }
    e = is_dir ? NULL : ext_of(name);
    el = e ? strlen(e) : 0;
    keep = g_namemax - 9 - el;          /* "~" + 8 hex digits */
    keep = cut_utf8(name, keep);
    snprintf(out, g_namemax + 1, "%.*s~%08x%s", (int)keep, name, fnv(name), e ? e : "");
    return 1;
}

/* "name (from Windows).ext", then "(from Windows 2)", ... */
static void coll_name(char *out, const char *name, int k, int is_dir)
{
    char suf[40];
    const char *e = is_dir ? NULL : ext_of(name);
    size_t stem = e ? (size_t)(e - name) : strlen(name);
    size_t el = e ? strlen(e) : 0, sl, room;
    if (k <= 1) snprintf(suf, sizeof suf, " (from Windows)");
    else        snprintf(suf, sizeof suf, " (from Windows %d)", k);
    sl = strlen(suf);
    room = g_namemax - sl - el;
    if (stem > room) stem = cut_utf8(name, room);
    snprintf(out, g_namemax + 1, "%.*s%s%s", (int)stem, name, suf, e ? e : "");
}

static int ieq(const char *a, const char *b) { return strcasecmp(a, b) == 0; }

static int is_junk(const char *n)
{
    return ieq(n, "desktop.ini") || ieq(n, "thumbs.db") || ieq(n, "ehthumbs.db") ||
           ieq(n, ".DS_Store");
}

static int skip_dir_name(const char *n)
{
    int i;
    for (i = 0; i < g_nskipdir; i++) if (ieq(n, g_skipdir[i])) return 1;
    return 0;
}
static int skip_file_name(const char *n)
{
    int i;
    for (i = 0; i < g_nskipfile; i++) if (ieq(n, g_skipfile[i])) return 1;
    return 0;
}

/* The old "My Pictures" junctions inside Documents exist on every
 * Windows PC and mean nothing to her; listing them is noise. */
static int legacy_link(const char *n)
{
    return ieq(n, "My Music") || ieq(n, "My Pictures") || ieq(n, "My Videos") ||
           ieq(n, "Application Data") || ieq(n, "Cookies") || ieq(n, "Local Settings") ||
           ieq(n, "NetHood") || ieq(n, "PrintHood") || ieq(n, "Recent") ||
           ieq(n, "SendTo") || ieq(n, "Start Menu") || ieq(n, "Templates");
}

/* ── what an earlier run of ours wrote ───────────────────────────── */
static int cmp_str(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

static void load_ours(const char *path)
{
    FILE *f = fopen(path, "r");
    char *line = NULL;
    size_t cap = 0, n = 0, acap = 0;
    ssize_t len;
    if (!f) return;
    while ((len = getline(&line, &cap, f)) > 0) {
        char *fld[6], *p = line;
        int i;
        if (line[len - 1] == '\n') line[len - 1] = '\0';
        for (i = 0; i < 6; i++) {            /* time stage action size src dst */
            fld[i] = p;
            p = strchr(p, '\t');
            if (!p) break;
            *p++ = '\0';
        }
        if (i < 5) continue;                 /* fewer than six fields */
        if (strcmp(fld[1], g_stage) != 0) continue;
        if (strcmp(fld[2], "copy") != 0 && strcmp(fld[2], "collision") != 0) continue;
        if (n == acap) {
            acap = acap ? acap * 2 : 1024;
            g_ours = realloc(g_ours, acap * sizeof *g_ours);
            if (!g_ours) die("out of memory");
        }
        g_ours[n++] = strdup(fld[5]);
    }
    free(line);
    fclose(f);
    g_nours = n;
    if (n) qsort(g_ours, n, sizeof *g_ours, cmp_str);
}

static int is_ours(const char *dst)
{
    return g_nours && bsearch(&dst, g_ours, g_nours, sizeof *g_ours, cmp_str);
}

/* ── becoming her ────────────────────────────────────────────────── */
static void become_her(void)
{
    uid_t r, e, s;
    if (g_uid == 0) { fputs("ferry-copy: refusing to copy as root (uid 0)\n", stderr); exit(3); }
    if (geteuid() != 0) {
        if (geteuid() != g_uid)
            die("only root can copy for another person (running as uid %u, asked for %u)",
                (unsigned)geteuid(), (unsigned)g_uid);
        prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
        return;
    }
    prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    if (setgroups(0, NULL) != 0) die("setgroups: %s", strerror(errno));             /* MUTATE-DROP */
    if (setresgid(g_gid, g_gid, g_gid) != 0) die("setresgid: %s", strerror(errno)); /* MUTATE-DROP */
    if (setresuid(g_uid, g_uid, g_uid) != 0) die("setresuid: %s", strerror(errno)); /* MUTATE-DROP */
    /* Prove it: all three ids are hers, and root cannot be regained. */
    if (getresuid(&r, &e, &s) != 0 || r != g_uid || e != g_uid || s != g_uid) die("could not give up root"); /* MUTATE-DROP */
    if (setuid(0) == 0) die("could not give up root (setuid(0) worked)"); /* MUTATE-DROP */
}

/* ── her side: walk down, one name at a time, never through a link ── */
static int open_home(void)
{
    struct stat st;
    int fd = open(g_home, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || st.st_uid != g_uid) { close(fd); errno = EPERM; return -1; }
    return fd;
}

/* One level: open (creating) directory `name` under `parent`, never
 * through a link. Returns an fd, or -1 with errno: ELOOP when a link
 * sits where the folder should be, ENOTDIR for a file. */
static int dir_step(int parent, const char *name)
{
    int fd;
    for (int tries = 0; tries < 2; tries++) {
        fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); /* MUTATE-NOFOLLOW */
        if (fd >= 0) return fd;
        if (errno != ENOENT) {
            struct stat st;
            /* O_NOFOLLOW|O_DIRECTORY on a link says ENOTDIR on Linux;
             * say ELOOP so the caller can name it correctly. */
            if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode))
                errno = ELOOP;
            return -1;
        }
        if (mkdirat(parent, name, 0755) != 0 && errno != EEXIST) return -1;
    }
    return -1;
}

/* DEST (absolute, under home) -> an open fd for that directory. */
static int ensure_dir(const char *dest, int *why)
{
    size_t hl = strlen(g_home);
    char tmp[MAXPATHBUF], *p, *save = NULL;
    int fd, nfd;
    *why = 0;
    while (hl > 1 && g_home[hl - 1] == '/') hl--;
    if (strncmp(dest, g_home, hl) != 0 || (dest[hl] != '/' && dest[hl] != '\0')) {
        *why = EXDEV; errno = EXDEV; return -1;       /* not under her home */
    }
    snprintf(tmp, sizeof tmp, "%s", dest + hl);
    fd = dup(g_homefd);
    for (p = strtok_r(tmp, "/", &save); p; p = strtok_r(NULL, "/", &save)) {
        if (!strcmp(p, ".")) continue;
        if (!strcmp(p, "..")) { close(fd); *why = EINVAL; errno = EINVAL; return -1; }
        nfd = dir_step(fd, p);
        close(fd);
        if (nfd < 0) { *why = errno; return -1; }
        fd = nfd;
    }
    return fd;
}

/* ── progress ────────────────────────────────────────────────────── */
static const char *plain_noun(const char *label, char *buf, size_t n)
{
    size_t i;
    if (ieq(label, "Desktop")) return "desktop";
    if (!strncasecmp(label, "Firefox", 7)) return "Firefox bookmarks and settings";
    if (!strncasecmp(label, "Wallpaper", 9)) return "wallpaper";
    for (i = 0; i + 1 < n && label[i]; i++) buf[i] = (char)tolower((unsigned char)label[i]);
    buf[i] = '\0';
    return buf;
}

/* Time left, only when it can be said honestly: some real copying has
 * happened, for long enough to have a rate. `copied` counts bytes really
 * written, not files that were already there (which cost no time). */
static const char *eta_for(double el, uint64_t copied, uint64_t remain, char *buf, size_t n)
{
    double left;
    int m;
    buf[0] = '\0';
    if (remain == 0 || el < 5.0 || copied < (1u << 20)) return buf;
    left = (double)remain / ((double)copied / el);
    m = (int)((left + 59) / 60);
    if (left < 45)             snprintf(buf, n, " Less than a minute left.");
    else if (left < 90 * 60)   snprintf(buf, n, " About %d minute%s left.", m, m == 1 ? "" : "s");
    else                       snprintf(buf, n, " About %d hours left.", (int)((left + 1799) / 3600));
    return buf;
}

static const char *eta_text(char *buf, size_t n)
{
    double el = now_s() - ((double)g_t0.tv_sec + (double)g_t0.tv_nsec / 1e9);
    return eta_for(el, g_copied_bytes, g_total_bytes > g_done_bytes ? g_total_bytes - g_done_bytes : 0, buf, n);
}

static void progress(struct job *j, int final)
{
    struct timespec t;
    char noun[64], eta[96], line[640], js[1024], at[32], msg[400];
    int pct;
    clock_gettime(CLOCK_MONOTONIC, &t);
    if (!final && g_interval_ms > 0) {
        long ms = (t.tv_sec - g_last_tick.tv_sec) * 1000L + (t.tv_nsec - g_last_tick.tv_nsec) / 1000000L;
        if (ms < g_interval_ms) return;
    }
    g_last_tick = t;
    plain_noun(j->label, noun, sizeof noun);
    pct = g_total_bytes ? (int)(g_done_bytes * 100 / g_total_bytes) : 100; /* MUTATE-PCT */
    if (!final && pct > 99) pct = 99;
    if (final) snprintf(msg, sizeof msg, "Copied your %s: %llu file%s.", noun,
                        (unsigned long long)j->files_done, j->files_done == 1 ? "" : "s");
    else       snprintf(msg, sizeof msg, "Copying your %s: %llu of %llu files.%s", noun,
                        (unsigned long long)j->files_done, (unsigned long long)j->files_total,
                        eta_text(eta, sizeof eta));
    if (g_plain) {
        int n = snprintf(line, sizeof line, "%s\n", msg);
        xwrite(1, line, (size_t)n);
    }
    if (g_prog >= 0 || g_progs >= 0) {
        int n;
        iso_now(at, sizeof at);
        n = snprintf(js, sizeof js,
            "{\"type\":\"progress\",\"stage\":\"%s\",\"pct\":%d,\"done\":%llu,\"total\":%llu,"
            "\"files_done\":%llu,\"files_total\":%llu,\"folder\":\"%s\",\"message\":\"%s\",\"at\":\"%s\"}\n",
            g_stage, pct, (unsigned long long)g_done_bytes, (unsigned long long)g_total_bytes,
            (unsigned long long)g_done_files, (unsigned long long)g_total_files, noun, msg, at);
        if (g_prog >= 0) { if (ftruncate(g_prog, 0) == 0) (void)!pwrite(g_prog, js, (size_t)n, 0); }
        if (g_progs >= 0) xwrite(g_progs, js, (size_t)n);
    }
}

/* ── one file ────────────────────────────────────────────────────── */
enum { R_COPIED, R_ALREADY, R_FAILED, R_FATAL };

static int same_file(const struct stat *a, const struct stat *b)
{
    long d;
    if (!S_ISREG(b->st_mode) || a->st_size != b->st_size) return 0;
    d = (long)(a->st_mtim.tv_sec - b->st_mtim.tv_sec);
    return d >= -2 && d <= 2;
}

static int rename_noreplace(int dfd, const char *from, const char *to)
{
    if (syscall(SYS_renameat2, dfd, from, dfd, to, 1u /* RENAME_NOREPLACE */) == 0) return 0;
    if (errno == EINVAL || errno == ENOSYS) {          /* filesystem without it */
        if (linkat(dfd, from, dfd, to, 0) == 0) { unlinkat(dfd, from, 0); return 0; }
    }
    return -1;
}

static void join(char *out, size_t n, const char *a, const char *b)
{
    snprintf(out, n, "%s%s%s", a, (*b && a[strlen(a) - 1] != '/') ? "/" : "", b);
}

/* Place one file at dfd/name. `srcabs` and the destination path strings
 * are only for the manifest and the messages. */
static int place_file(struct job *j, int sfd, const struct stat *sst, int dfd,
                      const char *name, const char *dparent, const char *srcabs,
                      const char *rel)
{
    char fin[300], cand[300], dst[MAXPATHBUF], rel2[MAXPATHBUF];
    struct stat dst_st;
    const char *use;
    int collided = 0, replace = 0, k, tfd = -1, renamed;
    uint64_t done = 0, sz = (uint64_t)sst->st_size;
    struct timespec ts[2];

    renamed = fit_name(name, fin, 0);
    use = fin;
    if (fstatat(dfd, use, &dst_st, AT_SYMLINK_NOFOLLOW) == 0) {
        char full[MAXPATHBUF];
        join(full, sizeof full, dparent, use);
        if (same_file(sst, &dst_st)) { return R_ALREADY; }
        /* Our own interrupted output (a power cut kept the name and the
         * time but not the bytes): same time as the source, listed in
         * our manifest. Replacing that loses nothing. A file the person
         * has edited has a different time, and is never touched. */
        if (is_ours(full) && S_ISREG(dst_st.st_mode) && dst_st.st_size != sst->st_size &&
            labs((long)(dst_st.st_mtim.tv_sec - sst->st_mtim.tv_sec)) <= 2) {
            replace = 1;
        } else {
            for (k = 1; k < 1000; k++) {
                coll_name(cand, fin, k, 0);
                if (fstatat(dfd, cand, &dst_st, AT_SYMLINK_NOFOLLOW) != 0) break;
                if (same_file(sst, &dst_st)) return R_ALREADY;
                join(full, sizeof full, dparent, cand);
                if (is_ours(full) && S_ISREG(dst_st.st_mode) && dst_st.st_size != sst->st_size &&
                    labs((long)(dst_st.st_mtim.tv_sec - sst->st_mtim.tv_sec)) <= 2) { replace = 1; break; }
            }
            if (k >= 1000) { g_done_bytes += sz; return R_FAILED; }
            use = cand;
            collided = 1;
        }
    }
    if (g_dry) { j->t.copied++; return R_COPIED; }

    for (int tries = 0; tries < 2 && tfd < 0; tries++) {
        tfd = openat(dfd, ".ferrypart", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (tfd < 0 && errno == EEXIST) unlinkat(dfd, ".ferrypart", 0);   /* ours, left by a crash */
        else if (tfd < 0) break;
    }
    if (tfd < 0) { g_done_bytes += sz; return errno == ENOSPC || errno == EDQUOT ? R_FATAL : R_FAILED; }

    (void)!posix_fadvise(sfd, 0, 0, POSIX_FADV_SEQUENTIAL);
    for (;;) {
        ssize_t r = read(sfd, g_buf, BUFSZ);
        size_t off = 0;
        if (r < 0) {
            if (errno == EINTR) continue;
            goto fail;
        }
        if (r == 0) break;
        while (off < (size_t)r) {
            ssize_t w = write(tfd, g_buf + off, (size_t)r - off);
            if (w < 0) {
                if (errno == EINTR) continue;
                if (errno == ENOSPC || errno == EDQUOT) { close(tfd); unlinkat(dfd, ".ferrypart", 0); if (sz > done) g_done_bytes += sz - done; return R_FATAL; }
                goto fail;
            }
            off += (size_t)w;
        }
        done += (uint64_t)r;
        g_done_bytes += (uint64_t)r;
        g_copied_bytes += (uint64_t)r;
        g_since_sync += (uint64_t)r;
        progress(j, 0);
    }
    if (done != sz) goto fail;                       /* it changed under us, or a hole */
    ts[0] = sst->st_mtim; ts[1] = sst->st_mtim;
    futimens(tfd, ts);
    if (close(tfd) != 0) { tfd = -1; goto fail; }
    tfd = -1;
    if (replace) {
        if (renameat(dfd, ".ferrypart", dfd, use) != 0) goto fail;
    } else if (rename_noreplace(dfd, ".ferrypart", use) != 0) {
        if (errno == EEXIST) {                       /* someone made it meanwhile: keep both */
            coll_name(cand, fin, 1, 0);
            use = cand; collided = 1;
            if (rename_noreplace(dfd, ".ferrypart", use) != 0) goto fail;
        } else goto fail;
    }
    join(dst, sizeof dst, dparent, use);
    clean_field(dst);
    mrow(collided ? "collision" : "copy", sz, srcabs, dst);
    if (collided) {
        j->t.collisions++;
        snprintf(rel2, sizeof rel2, "something with this name was already there; the Windows copy was saved next to it as \"%s\"", use);
        note_kind(K_COLLISION, "partial", j->label, rel, rel2);
    }
    if (renamed) {
        j->t.renamed++;
        snprintf(rel2, sizeof rel2, "the name was too long for this disk, so it was saved as \"%s\"", fin);
        note_kind(K_RENAMED, "partial", j->label, rel, rel2);
    }
    return R_COPIED;

fail:
    if (tfd >= 0) close(tfd);
    unlinkat(dfd, ".ferrypart", 0);
    if (sz > done) g_done_bytes += sz - done;
    return R_FAILED;
}

/* ── the walk ────────────────────────────────────────────────────── */
struct vfr { dev_t dev; ino_t ino; };

static void tally_class(struct job *j, const char *cls, uint64_t size, int plan)
{
    if (!strcmp(cls, "hydrated") || !strcmp(cls, "suspect")) {
        if (plan) { j->files_total++; j->bytes_total += size; }
        return;
    }
}

static void finish_file(struct job *j, uint64_t sz)
{
    j->files_done++;
    g_done_files++;
    (void)sz;
}

/* mode: 0 = plan (count), 1 = copy */
static void walk(struct job *j, int mode, int sfd, int dfd, char *rel, size_t rlen,
                 char *dparent, int depth, struct vfr *stack)
{
    DIR *d;
    struct dirent *de;
    int dupfd = openat(sfd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dupfd < 0) { note_kind(K_UNREADABLE, "partial", j->label, rel[0] ? rel : ".", "could not be opened to read"); return; }
    d = fdopendir(dupfd);
    if (!d) { close(dupfd); return; }

    while ((de = readdir(d)) != NULL && !g_fatal) {
        const char *name = de->d_name;
        struct stat st;
        char abs[2 * MAXPATHBUF], rel2[MAXPATHBUF], dp2[2 * MAXPATHBUF];
        size_t n2;
        if (!strcmp(name, ".") || !strcmp(name, "..")) continue;

        n2 = rlen ? rlen + 1 + strlen(name) : strlen(name);
        if (n2 + 2 >= MAXPATHBUF) { if (mode == 1) note_kind(K_UNKNOWN, "skipped", j->label, name, "its folder path is too long to follow"); continue; }
        if (rlen) snprintf(rel2, sizeof rel2, "%s/%s", rel, name); else snprintf(rel2, sizeof rel2, "%s", name);
        snprintf(abs, sizeof abs, "%s/%s", j->src, rel2);

        if (fstatat(sfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            if (mode == 1) note_kind(K_UNREADABLE, "partial", j->label, rel2, "could not be read from the Windows disk");
            continue;
        }

        if (S_ISLNK(st.st_mode)) {
            if (mode == 1 && !(depth <= 1 && legacy_link(name))) {
                j->t.links++; g_incomplete = 1;
                note_kind(K_LINK, "skipped", j->label, rel2,
                          "a shortcut or link, not a real folder or file; it was not followed");
            }
            continue;
        }

        if (S_ISDIR(st.st_mode)) {
            int nfd, ndfd = -1, why = 0;
            uint32_t at = 0, tg = 0;
            int have, k, cyc = 0;
            char fin[300], cand[300];
            if (skip_dir_name(name)) continue;
            if (st.st_dev != g_srcdev) {
                if (mode == 1) { g_incomplete = 1; note_kind(K_REPARSE, "skipped", j->label, rel2, "another disk is attached here; it was not entered"); }
                continue;
            }
            for (k = 0; k < depth; k++) if (stack[k].dev == st.st_dev && stack[k].ino == st.st_ino) cyc = 1;
            if (cyc || depth + 1 >= MAXDEPTH) {
                if (mode == 1) note_kind(K_REPARSE, "skipped", j->label, rel2, cyc ? "this folder leads back into itself; it was not followed again" : "folders are nested too deeply to follow");
                continue;
            }
            nfd = openat(sfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (nfd < 0) {
                if (mode == 1) { note_kind(K_UNREADABLE, "partial", j->label, rel2, "this folder could not be opened"); }
                continue;
            }
            have = wa_read(nfd, abs, &at, &tg);
            if (have && (at & FA_REPARSE_POINT)) {
                if (mode == 1 && !(depth <= 1 && legacy_link(name))) {
                    j->t.reparse++; g_incomplete = 1;
                    note_kind(K_REPARSE, "skipped", j->label, rel2, "a Windows junction or special folder, not a real folder; it was not followed");
                }
                close(nfd);
                continue;
            }
            if (mode == 1 && !g_dry) {
                int fit = fit_name(name, fin, 1);
                struct stat ds;
                (void)fit;
                snprintf(dp2, sizeof dp2, "%s", fin);
                if (fstatat(dfd, fin, &ds, AT_SYMLINK_NOFOLLOW) == 0 && !S_ISDIR(ds.st_mode)) {
                    if (S_ISLNK(ds.st_mode)) {
                        j->t.failed++;
                        note_kind(K_FAILED, "partial", j->label, rel2, "your home has a link where this folder belongs, so nothing was put there");
                        close(nfd);
                        continue;
                    }
                    for (k = 1; k < 1000; k++) {         /* a file is in the way: keep both */
                        coll_name(cand, fin, k, 1);
                        if (fstatat(dfd, cand, &ds, AT_SYMLINK_NOFOLLOW) != 0 || S_ISDIR(ds.st_mode)) break;
                    }
                    snprintf(fin, sizeof fin, "%s", cand);
                }
                ndfd = dir_step(dfd, fin);
                why = errno;
                if (ndfd < 0) {
                    j->t.failed++;
                    note_kind(K_FAILED, "partial", j->label, rel2,
                              why == ELOOP ? "your home has a link where this folder belongs, so nothing was put there"
                                           : "this folder could not be created");
                    close(nfd);
                    continue;
                }
                snprintf(dp2, sizeof dp2, "%s/%s", dparent, fin);
            } else {
                snprintf(dp2, sizeof dp2, "%s/%s", dparent, name);
            }
            stack[depth].dev = st.st_dev; stack[depth].ino = st.st_ino;
            walk(j, mode, nfd, ndfd, rel2, n2, dp2, depth + 1, stack);
            close(nfd);
            if (ndfd >= 0) close(ndfd);
            continue;
        }

        if (!S_ISREG(st.st_mode)) {
            if (mode == 1) { note_kind(K_UNKNOWN, "skipped", j->label, rel2, "not an ordinary file (a device or pipe); skipped"); j->t.unknown++; }
            continue;
        }

        /* an ordinary file */
        {
            int fd;
            uint32_t at = 0, tg = 0;
            int have;
            const char *cls;
            struct stat fst;
            if (is_junk(name)) { if (mode == 1) j->t.junk++; continue; }
            if (skip_file_name(name)) continue;
            fd = openat(sfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
            if (fd < 0) {
                if (mode == 1) { j->t.failed++; note_kind(K_UNREADABLE, "partial", j->label, rel2, "could not be read from the Windows disk, so it was not copied"); g_incomplete = 1; }
                continue;
            }
            if (fstat(fd, &fst) != 0 || !S_ISREG(fst.st_mode)) { close(fd); continue; }
            have = wa_read(fd, abs, &at, &tg);
            cls = classify(&fst, at, tg, have);

            if (mode == 0) { tally_class(j, cls, (uint64_t)fst.st_size, 1); close(fd); continue; }

            if (!strcmp(cls, "hydrated") || !strcmp(cls, "suspect")) {
                int r;
                uint64_t sz = (uint64_t)fst.st_size;
                if (!strcmp(cls, "suspect")) {
                    j->t.suspect++;
                    note_kind(K_SUSPECT, "partial", j->label, rel2,
                              "it may not have been copied completely (it looked like an online-only file); open it to check");
                }
                r = g_dry ? R_COPIED : place_file(j, fd, &fst, dfd, name, dparent, abs, rel2);
                if (g_dry) g_done_bytes += sz;
                if (r == R_COPIED) { j->t.copied++; j->t.bytes += sz; }
                else if (r == R_ALREADY) { j->t.already++; g_done_bytes += sz; }
                else if (r == R_FATAL) { g_fatal = 1; }
                else {
                    j->t.failed++; g_incomplete = 1;
                    note_kind(K_FAILED, "partial", j->label, rel2, "could not be copied (it could not be read or written), so it is not in your new folder");
                    {   char full[MAXPATHBUF]; join(full, sizeof full, dparent, name); clean_field(full); mrow("failed", 0, abs, full); }
                }
                finish_file(j, sz);
                progress(j, 0);
                if (g_since_sync >= (32u << 20) || (now_s() - ((double)g_last_sync.tv_sec + (double)g_last_sync.tv_nsec / 1e9)) >= 2.0)
                    sync_now();
            } else if (!strcmp(cls, "placeholder")) {
                char dd[300];
                j->t.placeholder++; g_incomplete = 1;
                snprintf(dd, sizeof dd, "online-only OneDrive file (%llu bytes on the internet, nothing on this disk). In OneDrive, right-click it and choose 'Always keep on this device', then bring your files across again",
                         (unsigned long long)fst.st_size);
                note_kind(K_PLACEHOLDER, "skipped", j->label, rel2, dd);
            } else if (!strcmp(cls, "encrypted")) {
                j->t.encrypted++; g_incomplete = 1;
                note_kind(K_ENCRYPTED, "blocked", j->label, rel2,
                          "locked with Windows file encryption; it can only be opened with your Windows sign-in, so it was not copied");
            } else if (!strcmp(cls, "reparse")) {
                j->t.reparse++; g_incomplete = 1;
                note_kind(K_REPARSE, "skipped", j->label, rel2, "a Windows link, not a real file; it was not followed");
            } else {
                j->t.unknown++; g_incomplete = 1;
                note_kind(K_UNKNOWN, "skipped", j->label, rel2, "could not tell what kind of file this is, so it was not copied");
            }
            close(fd);
        }
    }
    closedir(d);
}

/* ── jobs ────────────────────────────────────────────────────────── */
static void job_summary(struct job *j)
{
    char d[400], item[200];
    snprintf(item, sizeof item, "%s", j->label);
    snprintf(d, sizeof d, "%llu copied, %llu already present, %llu OneDrive placeholders, %llu to verify, %llu reparse points, %llu encrypted",
             (unsigned long long)j->t.copied, (unsigned long long)j->t.already,
             (unsigned long long)j->t.placeholder, (unsigned long long)j->t.suspect,
             (unsigned long long)j->t.reparse, (unsigned long long)j->t.encrypted);
    note("info", item, d);
}

static int open_src_root(struct job *j, int *devok)
{
    struct stat st;
    int fd = open(j->src, (j->is_file ? O_RDONLY : (O_RDONLY | O_DIRECTORY)) | O_NOFOLLOW | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    *devok = 0;
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0) { close(fd); return -1; }
    if (j->is_file ? !S_ISREG(st.st_mode) : !S_ISDIR(st.st_mode)) { close(fd); errno = ENOTDIR; return -1; }
    g_srcdev = st.st_dev;
    *devok = 1;
    return fd;
}

static void plan_job(struct job *j)
{
    int ok, fd;
    struct vfr stack[MAXDEPTH];
    char rel[MAXPATHBUF] = "", dp[MAXPATHBUF];
    fd = open_src_root(j, &ok);
    if (fd < 0) {
        struct stat ls;
        if (lstat(j->src, &ls) == 0 && S_ISLNK(ls.st_mode)) errno = ELOOP;    /* the kernel says ENOTDIR */
        note("skipped", j->label, errno == ELOOP
             ? "this Windows folder is a link, not a real folder, so it was not followed"
             : "this Windows folder could not be opened");
        g_incomplete = 1;
        return;
    }
    if (j->is_file) {
        struct stat st;
        uint32_t at = 0, tg = 0;
        int have = wa_read(fd, j->src, &at, &tg);
        fstat(fd, &st);
        tally_class(j, classify(&st, at, tg, have), (uint64_t)st.st_size, 1);
        close(fd);
        j->ok = 1;
        return;
    }
    snprintf(dp, sizeof dp, "%s", j->dest);
    walk(j, 0, fd, -1, rel, 0, dp, 0, stack);
    close(fd);
    j->ok = 1;
}

static void copy_job(struct job *j)
{
    int ok, fd, dfd, why = 0;
    struct vfr stack[MAXDEPTH];
    char rel[MAXPATHBUF] = "", dp[MAXPATHBUF];
    char dir[MAXPATHBUF];
    const char *leaf = NULL;
    memset(&j->t, 0, sizeof j->t);
    j->files_done = 0;
    if (!j->ok) return;
    if (j->is_file) {
        const char *sl = strrchr(j->dest, '/');
        snprintf(dir, sizeof dir, "%.*s", (int)(sl ? sl - j->dest : 0), j->dest);
        leaf = sl ? sl + 1 : j->dest;
    } else {
        snprintf(dir, sizeof dir, "%s", j->dest);
    }
    if (g_dry) dfd = -1;
    else {
        dfd = ensure_dir(dir, &why);
        if (dfd < 0) {
            char d[300];
            snprintf(d, sizeof d, why == ELOOP
                     ? "your home has a link where this folder belongs, so nothing was put there"
                     : why == EXDEV ? "its place is not inside your home, so nothing was put there"
                     : "its place in your home could not be made, so nothing was put there");
            note("blocked", j->label, d);
            g_incomplete = 1;
            g_done_bytes += j->bytes_total;     /* nothing more will happen for it */
            return;
        }
    }
    fd = open_src_root(j, &ok);
    if (fd < 0) { if (dfd >= 0) close(dfd); return; }
    if (j->is_file) {
        struct stat st;
        uint32_t at = 0, tg = 0;
        int have, r;
        const char *cls;
        fstat(fd, &st);
        have = wa_read(fd, j->src, &at, &tg);
        cls = classify(&st, at, tg, have);
        if (!strcmp(cls, "hydrated") || !strcmp(cls, "suspect")) {
            r = g_dry ? R_COPIED : place_file(j, fd, &st, dfd, leaf, dir, j->src, leaf);
            if (r == R_COPIED) j->t.copied++; else if (r == R_ALREADY) { j->t.already++; g_done_bytes += (uint64_t)st.st_size; }
            else { j->t.failed++; g_incomplete = 1; note("partial", j->label, "could not be copied"); }
            finish_file(j, (uint64_t)st.st_size);
        } else { g_incomplete = 1; note("skipped", j->label, "this file is online-only or protected, so it was not copied"); }
    } else {
        snprintf(dp, sizeof dp, "%s", dir);
        walk(j, 1, fd, dfd, rel, 0, dp, 0, stack);
    }
    close(fd);
    if (dfd >= 0) close(dfd);
    sync_now();
    progress(j, 1);
    if (!j->is_file) job_summary(j);
}

/* ── put: one small file, written as her ─────────────────────────── */
static int do_put(const char *dest, int keep, const char *backup)
{
    char dir[MAXPATHBUF], *buf = NULL, bk[300];
    size_t len = 0, cap = 0;
    const char *sl = strrchr(dest, '/'), *leaf;
    int dfd, why, tfd, rc = 0;
    ssize_t r;
    if (!sl) die("put needs an absolute destination");
    snprintf(dir, sizeof dir, "%.*s", (int)(sl - dest), dest);
    leaf = sl + 1;
    if (!*leaf || strlen(leaf) > g_namemax) die("bad file name");
    for (;;) {
        if (len + 65536 > cap) { cap = cap ? cap * 2 : 65536; buf = realloc(buf, cap); if (!buf) die("out of memory"); }
        r = read(0, buf + len, cap - len);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        len += (size_t)r;
        if (len > (16u << 20)) die("input too large");
    }
    dfd = ensure_dir(dir, &why);
    if (dfd < 0) { fprintf(stderr, "ferry-copy: %s: %s\n", dir, strerror(why)); return 3; }
    if (keep) {
        struct stat st;
        if (fstatat(dfd, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0) { close(dfd); return 5; }
    }
    unlinkat(dfd, ".ferrypart", 0);
    tfd = openat(dfd, ".ferrypart", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (tfd < 0) die("cannot write in %s: %s", dir, strerror(errno));
    {
        size_t off = 0;
        while (off < len) {
            ssize_t w = write(tfd, buf + off, len - off);
            if (w < 0) { if (errno == EINTR) continue; unlinkat(dfd, ".ferrypart", 0); die("write: %s", strerror(errno)); }
            off += (size_t)w;
        }
    }
    fsync(tfd);
    close(tfd);
    if (backup && *backup && strlen(leaf) + strlen(backup) < g_namemax) {
        struct stat st;
        snprintf(bk, sizeof bk, "%s%s", leaf, backup);
        if (fstatat(dfd, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(st.st_mode) &&
            fstatat(dfd, bk, &st, AT_SYMLINK_NOFOLLOW) != 0)
            (void)!linkat(dfd, leaf, dfd, bk, 0);          /* the old file stays, under its other name */
    }
    if (keep) {
        if (rename_noreplace(dfd, ".ferrypart", leaf) != 0) { rc = errno == EEXIST ? 5 : 1; unlinkat(dfd, ".ferrypart", 0); }
    } else if (renameat(dfd, ".ferrypart", dfd, leaf) != 0) {
        unlinkat(dfd, ".ferrypart", 0); rc = 1;
    }
    close(dfd);
    free(buf);
    return rc;
}

/* ── main ────────────────────────────────────────────────────────── */
int main(int argc, char **argv)
{
    struct job jobs[MAXJOBS];
    int njobs = 0, a = 1, put = 0, keep = 0, i;
    const char *notes = NULL, *manifest = NULL, *state = NULL, *progf = NULL, *backup = NULL;
    const char *putdest = NULL, *e;
    int have_uid = 0, have_gid = 0;

    if (argc == 5 && !strcmp(argv[1], "eta")) {      /* for the tests: what would it say? */
        char b[96];
        puts(eta_for(atof(argv[2]), strtoull(argv[3], NULL, 10), strtoull(argv[4], NULL, 10), b, sizeof b));
        return 0;
    }
    if (a < argc && !strcmp(argv[a], "put")) { put = 1; a++; }
    for (; a < argc; a++) {
        const char *o = argv[a];
#define ARG(n) do { if (a + (n) >= argc) die("%s needs %d argument(s)", o, (n)); } while (0)
        if      (!strcmp(o, "--uid"))      { ARG(1); g_uid = (uid_t)strtoul(argv[++a], NULL, 10); have_uid = 1; }
        else if (!strcmp(o, "--gid"))      { ARG(1); g_gid = (gid_t)strtoul(argv[++a], NULL, 10); have_gid = 1; }
        else if (!strcmp(o, "--home"))     { ARG(1); g_home = argv[++a]; }
        else if (!strcmp(o, "--stage"))    { ARG(1); g_stage = argv[++a]; }
        else if (!strcmp(o, "--notes"))    { ARG(1); notes = argv[++a]; }
        else if (!strcmp(o, "--manifest")) { ARG(1); manifest = argv[++a]; }
        else if (!strcmp(o, "--state"))    { ARG(1); state = argv[++a]; }
        else if (!strcmp(o, "--progress")) { ARG(1); progf = argv[++a]; }
        else if (!strcmp(o, "--backup"))   { ARG(1); backup = argv[++a]; }
        else if (!strcmp(o, "--plain"))    g_plain = 1;
        else if (!strcmp(o, "--dry-run"))  g_dry = 1;
        else if (!strcmp(o, "--keep-existing")) keep = 1;
        else if (!strcmp(o, "--skip-dir"))  { ARG(1); if (g_nskipdir < MAXSKIP) g_skipdir[g_nskipdir++] = argv[++a]; else a++; }
        else if (!strcmp(o, "--skip-file")) { ARG(1); if (g_nskipfile < MAXSKIP) g_skipfile[g_nskipfile++] = argv[++a]; else a++; }
        else if (!strcmp(o, "--job") || !strcmp(o, "--file")) {
            ARG(3);
            if (njobs == MAXJOBS) die("too many jobs");
            memset(&jobs[njobs], 0, sizeof jobs[0]);
            jobs[njobs].is_file = o[2] == 'f';
            jobs[njobs].label = argv[a + 1]; jobs[njobs].src = argv[a + 2]; jobs[njobs].dest = argv[a + 3];
            njobs++; a += 3;
        }
        else if (put && o[0] != '-' && !putdest) putdest = o;
        else die("unknown option '%s'", o);
    }
    if (!have_uid || !have_gid || !g_home) die("--uid, --gid and --home are required");
    if (put ? !putdest : !njobs) die("nothing to do");
    map_path = getenv("FERRY_WINATTR_MAP");
    if (map_path && !*map_path) map_path = NULL;
    if ((e = getenv("FERRY_COPY_NAMEMAX")) && atoi(e) >= 40 && atoi(e) < 255) g_namemax = (size_t)atoi(e);
    if ((e = getenv("FERRY_COPY_INTERVAL_MS"))) g_interval_ms = atol(e);
    if (g_home[0] != '/') die("--home must be an absolute path");

    /* ── as root: the few files that are root's, opened once ── */
    if (notes && !put) {
        g_notes = open(notes, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (g_notes < 0) die("cannot open %s: %s", notes, strerror(errno));
    }
    if (manifest && !put) {
        load_ours(manifest);
        g_manifest = open(manifest, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (g_manifest < 0) die("cannot open %s: %s", manifest, strerror(errno));
    }
    if (state && !put && !g_dry) {
        char p[MAXPATHBUF];
        snprintf(p, sizeof p, "%s/state/%s.progress", state, g_stage);
        g_prog = open(p, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
    }
    if (progf && !put) g_progs = open(progf, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);

    become_her();                                                    /* ← root ends here */

    g_homefd = g_dry ? -1 : open_home();
    if (!g_dry && g_homefd < 0) {
        fprintf(stderr, "ferry-copy: %s is not a folder that belongs to uid %u (%s); nothing was copied\n",
                g_home, (unsigned)g_uid, strerror(errno));
        return 3;
    }
    umask(022);
    if (put) return do_put(putdest, keep, backup);

    g_buf = malloc(BUFSZ);
    if (!g_buf) die("out of memory");
    clock_gettime(CLOCK_MONOTONIC, &g_t0);
    g_last_tick = g_t0; g_last_sync = g_t0;

    for (i = 0; i < njobs; i++) {
        plan_job(&jobs[i]);
        g_total_bytes += jobs[i].bytes_total;
        g_total_files += jobs[i].files_total;
    }
    {
        struct statvfs sv;
        if (!g_dry && fstatvfs(g_homefd, &sv) == 0 &&
            (uint64_t)sv.f_bavail * sv.f_frsize < g_total_bytes) {
            char d[240];
            snprintf(d, sizeof d, "there may not be enough room: about %llu MB to copy and %llu MB free",
                     (unsigned long long)(g_total_bytes >> 20),
                     (unsigned long long)(((uint64_t)sv.f_bavail * sv.f_frsize) >> 20));
            note("partial", "Disk space", d);
        }
    }
    for (i = 0; i < njobs && !g_fatal; i++) {
        copy_job(&jobs[i]);
    }
    note_overflow();
    mflush();
    if (g_fatal) {
        note("blocked", "Disk space", "the disk filled up while copying, so some of your files are not in your new folders. Free some space and bring your files across again");
        if (g_plain) { static const char m[] = "There is no more room on this computer, so some files were not copied.\n"; xwrite(1, m, sizeof m - 1); }
        return 4;
    }
    return g_incomplete ? 2 : 0;
}
