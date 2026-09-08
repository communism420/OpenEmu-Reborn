# OpenEmu-Intel — OpenEmu for Apple Silicon and Intel Macs

<p align="center">
  <img width="301" height="91" alt="logo" src="https://github.com/user-attachments/assets/e4c7ee8d-b526-4fa7-bf61-153dc1594372" />
</p>

<p align="center">
  <img width="2276" height="1550" alt="OpenEmu Library" src="https://github.com/user-attachments/assets/3797ba95-3e8c-49f6-9d3d-ab1cca6e70b9" />
</p>

---

## Current Status

**Actively maintained. Targets both Apple Silicon (`arm64`) and 64-bit Intel (`x86_64`) Macs.**

This community-maintained fork preserves the native Apple Silicon work from OpenEmu-Silicon while restoring support for Intel Macs. The app targets macOS 11.0 or later on both processor architectures.

> **Intel status:** Intel support is newly restored. Until an `x86_64` or universal build is published on this fork's **[Releases](https://github.com/communism420/OpenEmu-Intel/releases)** page, Intel users should build from source. Downloads from the upstream OpenEmu-Silicon project are Apple Silicon-only.

### Recent Updates
- RetroAchievements verified with official hardcore mode support across Phase 1 Systems, [see wiki for more details](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/RetroAchievements)
- Improved Gamecube performance via Dolphin and Wii is officially working, though still a bit experimental.
- Arcade is officially working via MAME, though remains experimental and requires additional testing.
- Sony PSP (PPSSPP), Dreamcast (Flycast) , and Nintendo DS (DeSmuME) have all recently been added and seem to stable for most users and hardware.
- Automatic Backup Folder for backing up battery saves and BIOS files
- Cheats now save and persist across game sessions

---

## Download

Get the latest build from this fork's **[Releases](https://github.com/communism420/OpenEmu-Intel/releases)** page. Before downloading, check that the asset is marked `x86_64`, `arm64`, or universal for your Mac.

If no compatible release is available yet, follow the source-build steps in [Contributing](.github/CONTRIBUTING.md). The upstream `openemu-silicon` Homebrew cask does not install an Intel build.

### Core availability on Intel

On Intel Macs, OpenEmu uses the legacy official OpenEmu 2.4.1 core catalog so it downloads releases that contain compatible `x86_64` binaries. That catalog was last updated in December 2023, so it is a compatibility bootstrap rather than a source of current core updates. Apple Silicon Macs continue to use the OpenEmu-Silicon core catalog.

Some newer or fork-only cores do not yet publish `x86_64` artifacts. Those cores may be unavailable through the Intel catalog and must be built locally from their Xcode scheme until an Intel or universal release is published. Compatibility of legacy core releases with current macOS should be tested per core. Never install an `arm64`-only core on an Intel Mac.

The in-tree Mupen64Plus core uses its cached interpreter on Intel. This avoids committing the precompiled `linkage.o` used by the old x64 dynarec, but Nintendo 64 emulation will be slower than a dynarec-enabled build. The existing Apple Silicon wrapper continues to use its pure-interpreter fallback while its ARM64 dynarec correctness issue remains unresolved.

---

## Supported Systems

> **Full details — working status, known issues, in-progress cores, and what's planned — are on the [Supported Systems](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Supported-Systems) wiki page.**

Quick summary: 30+ systems work today, including NES, SNES, Game Boy, GBA, N64, Nintendo DS, PlayStation, Dreamcast, GameCube/Wii, and more. A handful have known issues (PSP, Saturn, Game Boy Color categorization). PS2 has no core yet.

---

## Known Issues

- **Save state compatibility** — Save states belong to a particular core and core version. Some states created by older Intel cores are incompatible with current Apple Silicon core builds and can crash if loaded. **Back up your save states before your first launch** — see [Migrating from OpenEmu](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Migrating-from-OpenEmu) for details.
- Input Monitoring permission may need to be granted manually in System Settings → Privacy & Security.
- Core availability is not yet identical between `arm64` and `x86_64`; see the Intel note above.

---

## Requirements

- macOS 11.0 (Big Sur) or later
- An Apple Silicon Mac or a 64-bit Intel Mac

---

## About This Project

The original OpenEmu is still an amazing piece of Mac software. [stuartcarnie](https://github.com/stuartcarnie) brought Metal rendering to the app in 2019. [MaddTheSane](https://github.com/MaddTheSane) ported the emulation cores to ARM64 starting in 2021. [cyco](https://github.com/cyco), [clobber](https://github.com/clobber), [J-rg](https://github.com/J-rg), and the rest of the OpenEmu team built the application, the plugin architecture, and the library experience over more than a decade. That work is the foundation everything here stands on.

The original project went quiet around 2024 after the last release. By that time, the original team had already done significant work on the ARM64 cores. The ARM64 core work was real and substantial, but it was never assembled into a release — the last official binary (December 2023) was stated as Intel-only. [bazley82](https://github.com/bazley82) published a downloadable ARM64 build in early 2026, pulling together the ARM64-capable core submodules the original team had prepared into a single repo and release. OpenEmu-Silicon continued from there: RetroAchievements shipped across 9+ cores; a Libretro Bridge was built to load RetroArch cores directly inside OpenEmu; ScreenScraper cover art was integrated; Dreamcast was migrated from Reicast to Flycast; save persistence, system detection, and the core update pipeline were all fixed; and the app was hardened for macOS 26 (Tahoe). This fork carries that work forward while making Intel a supported build target again.

**Lineage:**
- [OpenEmu/OpenEmu](https://github.com/OpenEmu/OpenEmu) — the original project
- [bazley82/OpenEmuARM64](https://github.com/bazley82/OpenEmuARM64) — ARM64 build, built on the original team's core work and what I started building upon
- [OpenEmu-Silicon/OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon) — the actively developed Apple Silicon fork
- **This repo** — dual-architecture work maintained by [@communism420](https://github.com/communism420)

---

## A Note on AI-Assisted Development

The vast majority of the code in this repo is still from the original developers. I have not changed the underlying architecture or approach for the app (apart form having it in a single repo to make it easier for a small team to maintain), it is still the same work done by an exceptional team of engineers. I work on this project with AI assisted development practices. These tools help me write and debug code I couldn't write alone. That said, I review every change, test everything, and make all the calls about direction and quality. I'm transparent about this because honesty with the community matters more than maintaining an illusion of expertise I don't have. The goal is to keep something good alive and make it genuinely usable for players.

---

## Documentation

| Doc | What's in it |
|-----|-------------|
| [Wiki](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki) | User guides: getting started, BIOS files, importing, CD games, controllers, troubleshooting |
| [Migrating from OpenEmu](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Migrating-from-OpenEmu) | Switching from the original OpenEmu: what carries over, what doesn't, and how to back up |
| [Supported Systems](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Supported-Systems) | Every system: working status, known issues, in-progress cores, what's planned, and BIOS requirements |
| [`CREDITS.md`](.github/CREDITS.md) | Everyone who contributed — original OpenEmu team, ARM64 port, core sources, illustrators, and this repo's contributors |

---

## Contributing

Issues, PRs, and testing feedback are all welcome. If something breaks for you, open an issue and describe your Mac model, macOS version, and which system/game you were running. That context is the most valuable thing you can provide.

If you want to contribute code, check the open issues for good starting points. A clear PR description of what it fixes is the best kind of contribution.

---

## License

This project is a derivative of [OpenEmu](https://github.com/OpenEmu/OpenEmu). Most of the main app and SDK still carries the OpenEmu Team's original **BSD 3-Clause** copyright header, which is what actually governs those files — see [`LICENSE`](LICENSE) for the full text and how it applies. Individual emulation cores carry their own licenses (GPL v2, MPL 2.0, LGPL 2.1, and others) — see each core's directory for details.

Note: [picodrive](https://github.com/notaz/picodrive) includes a non-commercial clause. This project is and will remain free.
