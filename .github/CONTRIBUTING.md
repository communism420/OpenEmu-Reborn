# Contributing to OpenEmu Reborn

OpenEmu Reborn is an independent, fan-maintained revival based on [OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon), targeting Apple Silicon (`arm64`) and 64-bit Intel (`x86_64`) Macs. Contributions of all kinds are welcome — code, documentation, testing, triage, and compatibility reporting. Version `1.0.0` starts a new application version line, not new emulator-core versions. Recent local fixes still need Apple Silicon runtime verification; see [project identity and scope](../docs/project-identity.md).

Issues are currently disabled and no Reborn release has been published. Use a [pull request](https://github.com/communism420/OpenEmu-Reborn/pulls) for a proposed change or non-confidential report. References below to Issues or Discussions apply only if those features are enabled; do not open Reborn reports in upstream repositories instead.

---

## Ways to Contribute

You don't need to write code to make a meaningful contribution.

| Role | What it involves | How to start |
|------|-----------------|--------------|
| **Issue Triager** | Applying labels, asking for repro steps, closing duplicates, flagging `good first issue` candidates | Engage with a few issues, then ask the maintainer for triage permissions |
| **Compatibility Tester** | Testing games on the latest build, documenting results in the wiki | Open a Discussion and introduce yourself |
| **RetroAchievements Liaison** | Testing RA integration per-core, filing upstream RA tickets, maintaining the compatibility table | See [docs/retro-achievements/retroachievements-community-guide.md](../docs/retro-achievements/retroachievements-community-guide.md) |
| **Wiki / Docs Maintainer** | Keeping installation guides, core pages, and build instructions accurate | Open a PR or comment on a docs issue |
| **Code Contributor** | Bug fixes, feature work, core updates | Read on |

Not sure where to start? Open a Discussion in the Q&A category and say what you're interested in.

---

## Setting Up Your Dev Environment

### Requirements

- macOS 11.0 (Big Sur) or later — macOS 14 (Sonoma) or later recommended
- Xcode with the latest stable toolchain, including the Metal toolchain
- An Apple Silicon (`arm64`) or 64-bit Intel (`x86_64`) Mac
- No additional Homebrew dependencies required for the main app

### Steps

```bash
# 1. Fork and clone (core sources are already flattened into this repository)
git clone https://github.com/YOUR_USERNAME/OpenEmu-Reborn.git
cd OpenEmu-Reborn

# 2. Copy credential stubs (required — real credentials are never committed)
cp OpenEmu/ScreenScraperDevCredentials.template.swift OpenEmu/ScreenScraperDevCredentials.swift
cp OpenEmu/OEGoogleDriveSecrets.template.swift OpenEmu/OEGoogleDriveSecrets.swift

# 3. Open the workspace (not the .xcodeproj)
open OpenEmu-metal.xcworkspace
```

Select the **OpenEmu** scheme and build for **My Mac**, or verify from the command line:

```bash
ARCH="$(uname -m)"
xcodebuild build \
  -workspace OpenEmu-metal.xcworkspace \
  -scheme OpenEmu \
  -configuration Debug \
  -destination "platform=macOS,arch=$ARCH" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Or use the project's verify script, which also runs a codesign check:

```bash
./Scripts/verify.sh --arch "$(uname -m)"
```

Pass `--arch arm64` on Apple Silicon or `--arch x86_64` on Intel when you need to select the architecture explicitly. Changes to architecture-sensitive code should pass for both architectures in CI.

### Common Setup Issues

**Core source missing:** Core directories are regular directories in this fork, not submodules. Do not run `git submodule update`; check that your clone completed and that you opened `OpenEmu-metal.xcworkspace`.

**Missing credential files:** If the build fails with "no such file" errors for Swift credential files, re-run the `cp` commands above. Template files are in the repo; real ones are not and are never committed.

**Wrong architecture:** Make sure the build destination matches your Mac: `arm64` for Apple Silicon or `x86_64` for Intel. In Xcode, select **My Mac** and check the scheme's architecture settings.

**Missing Metal toolchain:** Some command-line builds may fail with misleading errors from subprojects or external dependencies if the Metal toolchain is not installed. Make sure the Metal toolchain is included in your Xcode installation.

### Worktree builds

If you're working in a git worktree, use `./Scripts/build-for-worktree.sh` and `./Scripts/verify.sh --arch "$(uname -m)" --worktree`. Keep local user-facing publication in the single `OpenEmu-Intel-test` folder. A stable path alone does not guarantee macOS permission persistence; see [docs/worktree-workflow.md](../docs/worktree-workflow.md) and [local signing](../docs/local-signing.md).

---

## Submitting a Pull Request

1. **Agree on the scope first** for anything beyond a trivial fix. When Issues are enabled, search and open or comment on the relevant issue. Otherwise explain the proposal in a draft PR.
2. **Branch from `main`**. Name your branch descriptively: `fix/snes-audio-regression` or `feat/retroachievements-badge`.
3. **Keep PRs focused.** One logical change per PR. If your fix touches three systems, open three PRs.
4. **Fill out the PR template completely.** It asks what changed, how you tested it, and whether AI tools were used.
5. **Review is best-effort.** This is a fan-maintained project without a guaranteed response schedule.

### PR Checklist

- [ ] Builds cleanly on the local Mac with no new warnings (`./Scripts/verify.sh --arch "$(uname -m)"`)
- [ ] Architecture-sensitive changes pass the `arm64` and `x86_64` CI jobs
- [ ] Tested the affected core or system with at least one game
- [ ] Flattened core sources are updated cleanly if cores were changed
- [ ] AI tool use disclosed in PR description if applicable
- [ ] No build logs, binaries, or credentials committed

---

## AI-Assisted Contributions

AI tools (Claude, Cursor, Copilot) are used in the development of this project. Contributions using AI assistance are welcome. However, AI-generated code introduces specific risks — subtle regressions, incorrect memory handling, and plausible-looking but wrong emulation behavior that passes a surface review.

**The policy:**

1. **Disclose AI use in your PR description.** "Drafted with Claude Code" or "used Cursor for scaffolding" is sufficient — not a penalty.
2. **You must be able to explain every line on request.** If a reviewer asks "why does this work?" and you don't know, the PR will be closed. You are responsible for the code you submit.
3. **Explain the problem and agreed scope in the PR.** Include an issue link when Issues are enabled; otherwise use the draft PR itself for that discussion.
4. **Low-effort AI PRs — vague description, no testing, no explained scope — will be closed without review.** This is a capacity constraint, not a judgment.

---

## Good First Issues

Issues tagged [`good first issue`](https://github.com/communism420/OpenEmu-Reborn/issues?q=is%3Aopen+label%3A%22good+first+issue%22) are chosen because:

- The scope is well-defined
- The relevant file or function is identified in the issue body
- An approach or known constraints are described
- No deep codebase knowledge required

Comment on an issue before you start work to avoid duplicates.

---

## Working on RetroAchievements Integration

The inherited RA integration history is tracked in [upstream issue #258](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/258); it is not Reborn's issue tracker or evidence of Reborn approval. The implementation pattern and known pitfalls are documented in [docs/retro-achievements/retroachievements-implementation-guide.md](../docs/retro-achievements/retroachievements-implementation-guide.md). Read that before wiring up a new core.

For testing RA as a user or tester rather than as a developer, see [docs/retro-achievements/retroachievements-community-guide.md](../docs/retro-achievements/retroachievements-community-guide.md).

---

## Working on the Libretro Bridge

The libretro host loads externally built RetroArch cores. See the current [libretro architecture](../docs/libretro-architecture.md); the [upstream Libretro Bridge wiki](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/The-Libretro-Bridge) is background, not Reborn-specific support documentation.

Bridge work branches from `main`. The integration branch (`feat/libretro-bridge`) has merged. Coordinate before touching `OpenEmu-SDK/OpenEmuBase/OEGameCore.h/.m` — that file is the base class for every core and is the highest-conflict file in the repo.

---

## Non-Code Roles

### Issue Triage

Triagers can apply and remove labels, close duplicates, mark issues `needs-info`, and flag `good first issue` candidates. They cannot merge PRs or push to main.

Engage with a few issues first — ask clarifying questions, look for duplicates — then ask the maintainer for triage permissions.

### Compatibility Testing

The [upstream wiki](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki) records upstream compatibility, not verification of Reborn builds. To contribute Reborn results:

1. Test a game on a clearly identified Reborn build; include its architecture
2. Note: core name, macOS version, processor model (Intel or M-series), and what you observed
3. Submit a documentation PR with your findings, or use Issues/Discussions if enabled

### RetroAchievements Testing

See [docs/retro-achievements/retroachievements-community-guide.md](../docs/retro-achievements/retroachievements-community-guide.md) for how to test achievement behavior per-core and how to file upstream RA tickets.

---

## Recognition

Every contributor — code or otherwise — is named in release notes and Progress Reports. If you've contributed and weren't credited, open an issue and we'll fix it.

---

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Be constructive, be patient, be kind to people doing this work for free.

---

*Questions? Use a [draft PR](https://github.com/communism420/OpenEmu-Reborn/pulls), or a Discussion if that feature is enabled.*
