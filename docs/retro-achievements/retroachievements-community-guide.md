# RetroAchievements — User and Contributor Guide

[RetroAchievements](https://retroachievements.org) is a community platform that adds an achievement system to classic games played through emulators. OpenEmu Reborn integrates RA support through [rcheevos](https://github.com/RetroAchievements/rcheevos), the same client library used by RetroArch and other supported emulators.

This guide is for **users and contributors** testing inherited RA behavior. Developers should read [the implementation guide](retroachievements-implementation-guide.md). The [#438 compliance evidence](retroachievements-compliance-evidence.md) describes upstream OpenEmu-Silicon work, not new Reborn approval or runtime verification. Reborn `1.0.0` is an app version, not a core update; the latest local fixes have not been runtime-tested on Apple Silicon. See [Project identity](../project-identity.md).

---

## Table of Contents

- [Core Support Status](#core-support-status)
- [Getting Started](#getting-started)
- [Testing Achievement Behavior](#testing-achievement-behavior)
- [Reporting RA Issues](#reporting-ra-issues)
- [Filing RA-Side Tickets](#filing-ra-side-tickets)
- [Working with the RA Community](#working-with-the-ra-community)
- [Contributing as an RA Liaison](#contributing-as-an-ra-liaison)

---

## Core Support Status

The table below summarizes inherited native-core integrations, not a Reborn per-game test or approval record. [Upstream issue #258](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/258) is historical rollout context, not this project's tracker.

| Core | System(s) | RA Status |
|------|-----------|-----------|
| mGBA | Game Boy Advance, Game Boy, Game Boy Color | ✅ Supported |
| GenesisPlus | Genesis, SMS, Game Gear, SG-1000, Sega CD | ✅ Supported |
| FCEU | NES / Famicom | ✅ Supported |
| Nestopia | NES, Famicom Disk System | ✅ Supported |
| SNES9x | Super Nintendo | ✅ Supported |
| BSNES | Super Nintendo | ✅ Supported |
| Gambatte | Game Boy, Game Boy Color | ✅ Supported |
| Mupen64Plus | Nintendo 64 | ✅ Supported |
| Mednafen | PlayStation, PC Engine, Atari Lynx, Neo Geo Pocket | ✅ Supported |
| picodrive | 32X, Sega CD | 🔄 In Progress |
| Flycast | Dreamcast | 🔄 In Progress |
| Dolphin | GameCube, Wii | 🔄 In Progress |
| Mednafen (ext.) | Saturn, Virtual Boy, WonderSwan, PC-FX | 🔲 Planned |
| DeSmuME | Nintendo DS | 🔲 Planned |
| PPSSPP | PSP | 🔲 Planned |
| Stella | Atari 2600 | 🔲 Planned |
| ProSystem | Atari 7800 | 🔲 Planned |
| Atari800 | Atari 5200, Atari 8-bit | 🔲 Planned |
| VecXGL, Bliss, O2EM, 4DO, blueMSX, PokeMini, Potator | Various | 🔲 Planned |

**Legend:**
- ✅ Supported — integrated and tested against known achievement sets
- 🔄 In Progress — actively being worked on
- 🔲 Planned — tracked in the rollout issue; contributors welcome

> **Note:** The #438 rollout and submission records concern upstream OpenEmu-Silicon. They do not establish an official listing or approval for OpenEmu Reborn.

---

## Getting Started

### What you need

- A RetroAchievements account — free at [retroachievements.org](https://retroachievements.org)
- A ROM of a game with an achievement set (browse the [game list](https://retroachievements.org/gameList.php))
- An OpenEmu Reborn build containing the RA integration; no Reborn release has been published yet

### Enabling RA in OpenEmu Reborn

1. Open **OpenEmu Reborn → Preferences → Achievements**
2. Log in with your RetroAchievements credentials
3. Your token is stored in the encrypted `.oe_credentials` file in your selected data folder; see the [privacy policy](../privacy-policy.md)

Once logged in, achievement notifications appear as an overlay during gameplay and as system notifications. Earned achievements sync to your retroachievements.org profile.

---

## Testing Achievement Behavior

Good RA testing is methodical. For each core you're testing:

### Basic smoke test

1. Launch a game with a known achievement set in the relevant core.
2. Verify the achievement list loads (you should see it in the achievements panel if applicable, or confirm on retroachievements.org after login).
3. Trigger a simple, early-game achievement by following its known trigger condition (listed on the achievement's page on retroachievements.org).
4. Verify the achievement notification fires and the achievement is marked earned on retroachievements.org.

### After a core update

When a core's source or binary is updated, repeat the smoke test for that core before calling the update verified. An app version change alone does not update core versions. If you discover a regression, note:
- Core version before and after the bump
- Which achievement(s) were affected
- Whether the regression is in achievement triggering, memory reading, or server communication

### What to document

For each test session, post findings as a comment on the relevant GitHub issue (or open one):
- Core name and commit hash or version
- macOS version and chip generation
- Game title and region
- Achievement name and trigger condition
- Pass / fail, and any console or log output

---

## Reporting RA Issues

Check existing [OpenEmu Reborn PRs](https://github.com/communism420/OpenEmu-Reborn/pulls) first. Issues are currently disabled: use a draft PR for a reproducible report, or the bug report template if Issues are enabled later. Do not send Reborn-specific failures to the upstream tracker.

When you do open an issue, use the **Bug Report** template and include:
- Whether this is in a supported core (see the table above)
- Whether the issue occurs with RA **disabled** too — this helps determine if it's an RA-specific regression
- The game title, achievement name, and the expected trigger condition
- Your RA account username (so the maintainer can check your profile if needed)

Apply the `retro-achievements` label plus the relevant core label.

---

## Filing RA-Side Tickets

Not every RA bug belongs in OpenEmu Reborn's issue tracker. If the problem is in the achievement set itself — wrong memory address, wrong trigger condition, wrong point value — file it on the RetroAchievements side.

To file an RA-side ticket:
1. Go to the game's page on retroachievements.org
2. Click the achievement in question
3. Use the **Open Ticket** button (requires an RA account)
4. Select the correct type (Achievement did not trigger / Achievement triggered at the wrong time / etc.)
5. Include the emulator name (**OpenEmu Reborn**) and version in the ticket body

When you file an RA-side ticket related to OpenEmu Reborn, link to it from the corresponding Reborn draft PR (or issue if enabled) so the resolution can be tracked in both places.

---

## Working with the RA Community

RetroAchievements has a large, active community of achievement set developers who have strong motivation to make sure emulators work correctly. This is a valuable contributor pipeline for OpenEmu Reborn.

### Where RA developers hang out

- **RetroAchievements forums** — retroachievements.org/forums, especially the **Emulator Support** board
- **RetroAchievements Discord** — the `#coders` channel is where achievement set developers and emulator integration developers interact
- **Individual achievement set threads** — each game has its own thread where set authors discuss known issues

### If OpenEmu Reborn gains an official RA listing

Post in the RA **Emulator Support** forum to announce it. The RA team actively spotlights newly listed emulators — coordinate with RA staff via their Discord to time the announcement. Frame it as: here's what's supported, here's what's in progress, here's how to file issues.

RA achievement set developers will file bugs against OpenEmu Reborn when they find them. When they do:
- Treat them as high-quality reporters — they understand the memory conditions deeply
- Ask for the achievement name, game title, and expected trigger condition
- Tag the issue `retro-achievements` + the relevant core label

---

## Contributing as an RA Liaison

An RA Liaison is a community role for people who want to help maintain the bridge between OpenEmu Reborn and the RetroAchievements community. It doesn't require writing code.

**What it involves:**
- Testing newly integrated cores against known achievement sets and documenting results
- Monitoring the RA forums and Discord for OpenEmu Reborn mentions and bug reports
- Filing or triaging GitHub issues when RA bugs are reported in the RA community
- Helping distinguish emulator bugs (file here) from achievement set bugs (file upstream with RA)
- Maintaining documented Reborn compatibility results, with the exact app/core versions and architecture

**How to get started:**
Use a draft PR, or a Discussion if enabled, to introduce yourself. Documented tests of an exact app/core build are useful contributions.

---

*Questions? Use a draft PR in OpenEmu Reborn, or Discussions if enabled later. [Upstream issue #258](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/258) remains historical background, not this project's support channel.*
