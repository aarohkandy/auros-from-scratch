# CURRENT STATE (written 2026-10-28, lead session on the fork)

`START-HERE.md` §0 asks for this file. It is the newest state; when it
disagrees with `RESUME-NOW.md` or a stream file, this file wins.

## 0. Where the code lives now

- Repository: **`aarohkandy/auros-from-scratch`**, branch **`main`** (the
  default). It is a fork of `ComputerDude771/auros-from-scratch`, where
  `main` = `claude/brave-hypatia-x72g1m` at `26b1f09` (2026-10-23, the branch
  that contains every older branch) plus the commits below. The old
  repository has no push access from here; its PR #1 is untouched.
- Every workflow now triggers on `main` as well as `claude/**`
  (`ab92e2d`). `docs/MOVING.md` said nothing needed editing for a move;
  that was wrong on exactly this point.
- `e2e.yml` and `windows.yml` are pinned by absolute URL to the old
  repository's prerelease **`v0.1.0-dd39389`** (installer SHA-256
  `89b49e4b…`, image `9e3e7b9d…`, 4,855,955,456 bytes) until this
  repository publishes its own. The fork's `image-desktop` branch is the
  September one and must not be used for pins.
- A Linux box with KVM is available to agents for local builds and
  tests (`/srv/auros`, root-owned checkout); GitHub Actions remains the
  authority for evidence.

## 1. What was found and fixed on 2026-10-28

| Commit | What |
|---|---|
| `ab92e2d` | **The real-Windows e2e never got past "edge: download, and keep it"** (every variant of `e2e-39899282173`). The driver matched the Downloads panel's header "More options" instead of the file's own "More actions" (which only exists while the pointer is on the row), opened the wrong menu four times and waited out the deadline. It now takes only a dots button inside the warning row, hovers the row's right end, and as a last resort presses that spot. Verification: the e2e run on this commit (`40765534800`). |
| `d1676a8`, `24374cc` | **`profiles.yml` lint and selftest were red on the handoff tree** and upstream never saw it (their gate skipped the lint on those commits). The hardening stream added `packages_security` and `zram_percent`/`earlyoom_*`; the lint read every package list but that one, and its "good kiosk" fixture had no `swap=`/`earlyoom=` line. Fixed in both the lint and the selftest's offline index; two new mutants prove the swap and earlyoom checks go red. |
| `5dfb71c` | **`windows.yml` job `gapselftest` was red although both refusals happened**: the pwsh step ended on a native command that is meant to exit non-zero. `exit 0` after "both refused", like every sibling step. |

## 2. Problems still open, most important first

1. **The published prerelease's own navtest fails on real Windows**
   (`windows-published`: "five problems fit on the page without
   scrolling"). The source on `main` already says "four problems"; the
   published `.exe` predates that. It passes once a build from today's
   source is published and the pins updated.
2. **No release from this repository yet.** The ship gate is unchanged:
   green `build` → `[publish RUN-ID]` prerelease → `e2e.yml` pinned to
   that exact `AurOS-Setup.exe` passes → `[publish RUN-ID] [latest]`.
3. **Pages is off on this repository** and `releases/latest` 404s, so
   the website's button does not work yet (owner clicks, §4).
4. The 2026-10-23 audits never finished: `docs/security/FINDINGS.md` and
   `docs/LAUNCH-READINESS.md` do not exist. Adapted copies of
   `tools/workflows/{security-audit,launch-readiness}.js` for this
   repository are being run by the lead; the files appear when they land.
5. Unowned, unblocked stream work being respawned now: M (portability for
   this move), S3 (fuzzing, hardening flags), R (Ferry copies as her
   user; local root escalation finding 4). Still unowned: S2 steps 2-5,
   S4 (encrypted disk, design only), S5 steps 1-5 (update channel), K
   step 5, P steps 2-5, H steps 2-5, S1's boot test. A2's fast path is
   unwired by design until proven; its three consent features (Wi-Fi
   key, BitLocker pause, the putback task) need the owner's explicit
   consent design and are not being built here.
6. `windows.yml` runs get cancelled by every newer push (one run per
   branch); with several agents pushing, read the newest completed run.

## 3. The plan (lead)

1. Watch `e2e-40765534800` (`releases/download/e2e-40765534800/live-base.txt`).
   If the download step passes and the journey reaches AurOS and the
   store, the harness is fixed; fix whatever stops next.
2. First green `build` on `main` → `git commit --allow-empty -m "[publish RUN-ID] …"`
   → repin `e2e.yml`/`windows.yml` to this repository's prerelease → e2e
   on it → `[publish RUN-ID] [latest]`.
3. Land the three audits (security, launch readiness, this file) and
   work the critical/high items with stream agents.
4. Then the owner's real-PC campaign (`docs/RELEASE.md` §5): nothing has
   run on a physical PC yet.

## 4. Owner-only clicks on `aarohkandy/auros-from-scratch`

The agents' token cannot do these (the auto-mode classifier refuses
them as creating a public surface):

1. Settings → Pages → Build and deployment → Source: **GitHub Actions**.
2. Settings → Environments → **github-pages** → Deployment branches: **No
   restriction** (or add `main`).
3. Later: Settings → Secrets → `AUROS_APT_SIGNING_KEY` (`docs/OWNER-SETUP.md` §4a).
4. Settings → Code security → private vulnerability reporting (for `SECURITY.md`).

Default branch is already `main` (done by API, 2026-10-28).
