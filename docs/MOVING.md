# Getting everything onto your computer, and moving to a new repository

## One command: download everything (or update it if you already have it)

Paste into Terminal on a Mac (or Linux). It puts the whole project in
`~/Desktop/auros`: every file and folder, at the newest version. Run the
same command again any time to update it.

```sh
D=~/Desktop/auros; R=https://github.com/aarohkandy/auros-from-scratch.git; B=main; if [ -d "$D/.git" ]; then git -C "$D" pull --ff-only; else git clone --single-branch --branch "$B" "$R" "$D"; fi; cd "$D"
```

- `D` is the folder (change it if you like, e.g. `D=~/Desktop/"auros v0.0.1"`).
- `R` is the repository address, `B` the branch. **These two are the only
  things that change when you move repositories.**
- `--single-branch` is deliberate: the repository also holds an old branch
  (`image-desktop`) with about 7 GB of superseded image pieces you don't need.

### What the folder contains, and what it doesn't

Contains: all source code, build scripts, tests, workflows, the website,
every design and handoff document (`docs/handoff/RESUME-NOW.md` is the
entry point), screenshots and research.

Does not contain, by design (each is rebuilt from the folder):
- **The built installer and OS image** (about 1.8 GB). They are published as
  GitHub Release files and rebuilt by `.github/workflows/build.yml` +
  `release.yml` from this folder.
- Test evidence from the Windows VM runs (published as `e2e-*` prereleases).
- GitHub settings and secrets (see `docs/OWNER-SETUP.md`).

## Moving to a new repository

1. Create the new, empty repository on GitHub (public, so Actions minutes stay
   free and runners have KVM).
2. From the folder above:
   ```sh
   git remote set-url origin https://github.com/NEWOWNER/NEWREPO.git
   git push -u origin HEAD:main
   ```
   (`main`, or keep the branch name; then use that as `B` in the one command.)
3. Do `docs/OWNER-SETUP.md` sections 1, 2 and 4 on the new repository
   (Pages, default branch, secrets).
4. Push a commit whose subject contains the build/publish words in
   `docs/HANDOFF-RUNBOOK.md` to rebuild and publish the installer there.

Nothing in the code should need editing for a move: workflows read the
repository from GitHub (`${{ github.repository }}`), scripts ask
`tools/repo.sh`, and the website and installer derive their download
address from it at build time. `sh tools/portabilitytest.sh` (a step of
`tests.yml`) fails if any file outside `docs/` names the old repository,
except the two lines that pin `e2e.yml` and `windows.yml` to the release
`v0.1.0-dd39389`, which exists only in the original repository; delete
those pins when the new repository publishes its own release.

**What an earlier version of this page got wrong.** It said nothing needed
editing for a move. Until 2026-10-28 every workflow ran only on pushes to
`claude/**` branches, so a repository whose branch is called `main` built,
tested and published nothing. The workflows now also run on `main`
(`build.yml`, `tests.yml`, `pages.yml`, `e2e.yml`, ...), so pushing `main`
to the new repository works as described above. A branch with another name
still needs adding to the `on: push: branches:` lists.
