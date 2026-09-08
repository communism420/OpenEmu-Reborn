# Worktree workflow

These instructions apply to OpenEmu Reborn. Existing OpenEmu scheme names,
signing identity and the canonical `OpenEmu-Intel-test` path remain unchanged
for compatibility; see [Project identity](project-identity.md).

Working on multiple PRs in parallel via `git worktree` is supported, but macOS makes it more friction-prone than the typical "one checkout" workflow. This doc explains the gotchas and the workflow that makes them tractable.

For this maintainer's normal local use, deliver only the single
`OpenEmu-Intel-test/` package at the main checkout's root using
`Scripts/replace-local-intel-build.sh`; see [Local signing](local-signing.md).
The per-worktree paths below are development intermediates, not additional
user-facing installations. After an isolated test, unregister/remove its exact
temporary app copy, keeping source trees and reusable compilation caches.

## The fundamental problem

macOS checks privacy permissions for the running app's signing identity and launch context; a filesystem path alone does not establish permission. Xcode's default DerivedData uses a different directory per checkout, making it easy to launch a different copy than the one shown in System Settings:

- Main repo build → `~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-aaaaa/.../OpenEmu.app`
- Worktree A build → `~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-bbbbb/.../OpenEmu.app`
- Worktree B build → `~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-ccccc/.../OpenEmu.app`

These copies may also have different signatures. Do not assume that an enabled System Settings entry grants access to every copy, or that launching the executable directly tests the same authorization context as launching the app through Finder.

## Keep per-branch build paths predictable

Use `Scripts/build-for-worktree.sh` instead of plain `xcodebuild`. It builds to a stable path keyed by the current branch:

```
~/Builds/openemu/<branch-name>/Build/Products/Debug/OpenEmu.app
```

The same branch returns to the same path. This makes the intended copy easier to find, but does not by itself preserve permission across rebuilds.

```bash
# Inside any worktree (or in main):
./Scripts/build-for-worktree.sh

# Builds to ~/Builds/openemu/<branch>/Build/Products/Debug/OpenEmu.app
# Auto-resolves a stable Apple Development signing identity if available.
```

The script also auto-resolves an Apple Development signing identity if you have one in your keychain. Without that, builds fall back to ad-hoc signing (`-`), which identifies a particular code build rather than a stable publisher. Keeping its path unchanged does not guarantee that permissions survive a rebuild. For an explicitly selected permanent local identity, see [Local signing](local-signing.md).

## First-time setup per branch

The first time you build a branch with `build-for-worktree.sh`:

1. Run the script. Note the printed app path.
2. Launch the app. macOS will prompt for any permissions the app needs.
3. Grant Input Monitoring (and anything else you need) for that path in **System Settings → Privacy & Security**.
4. Subsequent builds of the same branch land at the same path. Verify the running copy's permission again; a changed signing identity may require a new grant.

## Cores are shared across all worktrees + the installed app

This is the second worktree gotcha. OpenEmu loads cores from `~/Library/Application Support/OpenEmu/Cores/` regardless of which build is launching them. There is only one installed copy of each core at any time.

Practical implications:

- If you're testing a core fix in worktree A, but worktree B's last `Scripts/install-core.sh <Name>` left a different version of the same core installed, **you're testing the wrong code.**
- Switching between worktrees that touch the same core requires a re-install each time you want to test.
- The "installed cores" state isn't checkpointed by git — there's no equivalent of `git stash` for the cores directory.

The only way to keep cores straight: every time you switch which worktree you're testing, run `Scripts/install-core.sh <CoreName>` from that worktree before launching. `verify.sh --core <Name>` does this automatically.

## `main`'s state isn't in worktrees

This is fundamental git worktree behavior, not a bug. Each worktree is checked out at a specific branch. New commits to `main` don't appear in worktrees on other branches unless you explicitly merge or rebase.

To get the latest `main` into a worktree's branch:

```bash
# From inside the worktree
git fetch origin
git merge origin/main          # safe: adds a merge commit
# or
git rebase origin/main         # rewrites history; only do this on branches no one else uses
```

If you've already pushed the branch and the merge commit is fine, the merge approach is simpler. The rebase approach gives a cleaner history but requires force-pushing afterward.

## `verify.sh` from a worktree

`verify.sh --worktree` uses the stable `~/Builds/openemu/<branch>/` path instead of DerivedData. Always pass `--worktree` when inside a linked worktree:

```bash
./Scripts/verify.sh --worktree --core <CoreName>
```

This builds to the stable path, installs the core, and runs the MD5 preflight (`verify-core-installed.sh`) to confirm the installed plugin matches the build. Without `--worktree`, verify.sh looks in DerivedData and may find a stale artifact from a previous session.

## Verification protocol for core changes

OpenEmu loads cores from `~/Library/Application Support/OpenEmu/Cores/`, not the build directory. There are three distinct binaries to track whenever you're doing core work in a worktree:

| What | Path |
|---|---|
| Worktree build | `~/Builds/openemu/<branch>/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core>` |
| DerivedData build | `~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core>` |
| Installed (what OpenEmu loads) | `~/Library/Application Support/OpenEmu/Cores/<Core>.oecoreplugin/Contents/MacOS/<Core>` |

After any core install, run the three-way MD5 check:

```bash
md5 \
  ~/Builds/openemu/<branch>/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core> \
  ~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core> \
  ~/Library/Application\ Support/OpenEmu/Cores/<Core>.oecoreplugin/Contents/MacOS/<Core>
```

What each hash tells you:

- **Worktree build hash** — the code you just compiled. This is the source of truth.
- **DerivedData hash** — may be stale from a previous session or a main-checkout build. Should be ignored if it's older than the worktree build.
- **Installed hash** — what OpenEmu will actually run. Must match the worktree build hash or your test result is invalid.

`Scripts/verify-core-installed.sh <CoreName>` automates the build-vs-installed comparison and prints both hashes. Use it, but read the hash output — don't rely on the exit code alone.

### What went wrong (incident log)

During FCEU grey-screen debugging, `install-core.sh` only searched DerivedData. The worktree build landed in `~/Builds/openemu/<branch>/` instead. The script found the stale DerivedData artifact and installed it without error. The preflight check also only looked at DerivedData, so it reported "installed matches latest build" — and both were true about the wrong binary. The bug was caught only by running a manual three-way MD5 comparison. Hours of "still broken" debugging were actually testing code that hadn't been installed.

The fix (PR #321) makes `install-core.sh` search both paths and prefer the most recently modified. The three-way check remains the definitive confirmation — run it after every install.

## Worktree session checklist

Run through this at the start of any session that touches cores in a worktree:

- [ ] Confirm you're in a worktree: `git worktree list` — `.git` will be a file, not a directory
- [ ] Build with: `./Scripts/verify.sh --worktree --core <Name>` (or `./Scripts/build-for-worktree.sh` for app-only)
- [ ] Install with: `./Scripts/install-core.sh <Name>` (searches both paths, prefers most recent)
- [ ] Verify with three-way hash — only declare done when installed hash matches worktree build hash
- [ ] If the hashes don't match: quit OpenEmu, re-run `install-core.sh`, re-check

## Cleanup

When you're done with a worktree:

```bash
# Remove the worktree (from the main repo, not the worktree itself)
git worktree remove ../openemu-pr287

# Optionally remove the build artifacts (this does not reset macOS permissions)
rm -rf ~/Builds/openemu/<branch-name>/
```

If you keep the build dir but delete the worktree, the next `git worktree add` for the same branch will reuse the build dir. Reusing the directory does not prove that macOS will grant access to the next build.

## What this workflow does not solve

- **Cores are still shared.** Solving this would require modifying OpenEmu's core-loading logic to accept a per-build cores path. Out of scope.
- **Helpers must be tested in the normal app launch context.** A stable helper path is not proof of permission for the app or its child processes.
- **If your signing identity changes between builds** (sometimes ad-hoc, sometimes certificate-signed), permissions may need re-granting. A consistent certificate reduces identity changes, but does not itself grant access or replace a check of the running app.

## When NOT to use worktrees

If the work you're doing genuinely requires testing one PR at a time and switching often, worktrees may add more overhead than they save. A single checkout with `git checkout` to switch branches is fine for most workflows. Worktrees are most useful when:

- You're actively comparing two implementations side-by-side
- You need to run two long-running operations (e.g. a build + a test) on different branches simultaneously
- You don't want to disrupt your editor's open files when switching branches
