# Adapting OpenEmu-Silicon in Reborn

This integration imports the 13 upstream commits after `6f1c295d` through
`b32b7e12d694090eba05c52873e1c0b4d6b1fd11`. It does not replace Reborn with
the Silicon application, change the signing keys, or publish a new release.
The requested Reborn `1.0.1` update also completes the included translation
tables, adds [per-profile language selection](interface-language.md), and adapts
native folder panels to the available screen and sheet space.

## What is carried forward

- Jaguar aspect ratio correction and wrapped controller labels.
- Faster library/grid updates, gameplay pause/teardown fixes, and updated
  RetroAchievements behavior and login transport.
- Cheat search, online cheat providers, validation and feedback storage.
- The native-core changes and their upstream version bumps, including the
  updated MAME source pin and shared rcheevos library.
- Upstream workflow action pins, while retaining Reborn's two-architecture
  verification and release checks.

## Deliberate adaptations

| Upstream change | Reborn behavior |
| --- | --- |
| Delete the external RetroArch integration | Keep the translator, bridge target, scanner, picker and system input adapters. |
| Remove installed RetroArch wrappers and defaults on startup | No removal sweep. Existing external-core selections and files remain. |
| Warn that save states belong to a retired core | Only the historical `-Bridge` test cores are retired; an installed `-RetroArch` core can still load its states. |
| Refresh plugins before the plugin list is cached | Refresh retained RetroArch stubs before plugin enumeration. |
| Rewrite and re-sign plugin feed metadata | Keep Reborn's signed host catalogs and pinned archive verification; do not rewrite plugin feeds. |
| Silicon app version, documentation and ownership | Preserve Reborn's identity, version line, repository owner, storage and signing contracts. |
| New cheat database/feedback files | Use the selected library folder and guarded directory creation; include them in library removal. |
| Asynchronous artwork decoding for smoother scrolling | Keep asynchronous UI reads, but use a definitive synchronous disk read for migration and integrity checks. A cold image cache must not be mistaken for corrupt artwork. |

Native OpenEmu plugins remain the default when no explicit selection is saved.
Compatible external libretro `.dylib` files remain opt-in through Preferences →
Cores. Keeping this integration does not claim that every RetroArch core or
hardware-rendering backend works. See [the libretro architecture](libretro-architecture.md).
Save states are still specific to the core and version that created them.

The retained bridge is version 5. It resolves the BIOS, battery-save and content
directories after the host has attached the core's owner, so the external core
receives the selected profile's paths. Wrapper refreshes now copy, update, sign
and verify a staging bundle before replacing the installed wrapper. A copy or
signing failure must leave the installed version and external-library path intact.

The new MAME revision is `fac13e827b7b8cfa4ee4f5760198d31241e2a544` in
`OpenEmu-Silicon/mame`. Its source package records the repository from the
committed pin, instead of incorrectly naming the previous MAME repository.

VirtualJaguar's plugin version is `2.1.1.1`: this is a Reborn wrapper revision
for the inherited 4:3 aspect-ratio correction, not a new upstream emulator
release. The previous published plugin was `2.1.1`; keeping that number would
prevent the updater from offering the correction to users with an installed
copy. Public core feeds stay unchanged until the new signed archives pass
verification and are published.

## Verification

Run the host verification floor, then the integration and provenance guards:

```sh
./Scripts/verify.sh --arch "$(uname -m)" --release --ad-hoc-sign
python3 Scripts/Tests/test-silicon-sync.py
python3 Scripts/Tests/test-package-mame-source.py
python3 Scripts/Tests/test-core-artifact-reuse.py
bash Scripts/check-core-feed-urls.sh
bash Scripts/Tests/test-libretro-bridge.sh /absolute/path/to/just-built/Release
bash Scripts/Tests/test-libretro-stub-refresh.sh
bash Scripts/Tests/test-artwork-migration.sh
```

The artwork fixture compiles the actual image model against a private in-memory
database. It checks cold-cache conversion, asynchronous UI loading, and corrupt
or missing source files without touching the user's artwork or library.

The source guards are not gameplay tests. The ROM-free bridge fixture loads a
tiny synthetic external library through the actual built translator and checks
the selected profile paths, two-player input, analog input, save-state round trips
and battery-save lifecycle
for NES/DS system identifiers. It does not install a core in the real profile or
establish compatibility with any game. Shared framework and rcheevos changes
also require native core builds on both `x86_64` and `arm64` in CI. Keep the
source revision, test results and exact core archives together. Before reporting
runtime results, install the newly built core into an isolated, identified data
folder and run `Scripts/verify-core-installed.sh` with the same folder and build
directory. Never substitute an older installed plugin for the core being tested.

Do not update appcast/catalog versions just because a source build succeeds.
Only advertise verified, signed and publicly available release archives.
