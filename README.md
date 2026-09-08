# OpenEmu Reborn

**A fan-made revival of OpenEmu for Apple Silicon and Intel Macs, based on OpenEmu-Silicon.**

[Русская версия](README.ru.md) · [Source](https://github.com/communism420/OpenEmu-Reborn) · [Build instructions](.github/CONTRIBUTING.md)

OpenEmu Reborn keeps the idea that made OpenEmu special: a native Mac app that brings a game library, controllers and many retro systems together in one place. It carries forward [OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon), with **Apple Silicon (`arm64`) and 64-bit Intel (`x86_64`) as equal build targets**.

This is an independent fan project maintained by [@communism420](https://github.com/communism420), not an official OpenEmu release or a product endorsed by the original team or OpenEmu-Silicon. The repository was previously named **OpenEmu-Intel**.

## Version 1.0.0

**1.0.0 starts the OpenEmu Reborn version series.** It does not reset OpenEmu's history, change emulator core versions, or imply that every game has been tested on both architectures.

The current working version includes:

- Native build targets for Apple Silicon and Intel, with architecture checks for the app and core plugins.
- A first-launch data-folder choice for the library, app preferences, BIOS, saves and other app-owned files.
- Selective data removal in Settings, with confirmation and a select-all option for categories inside the chosen folder. External game files are not deletion targets.
- A **No Shader** option through the common renderer, independent of console or core.
- The library, controller support, save states and emulator integrations inherited from OpenEmu and OpenEmu-Silicon.

The latest local test package is **Intel-only**, not universal. Recent local fixes have not yet been run on a physical Apple Silicon Mac. A successful build is not a compatibility guarantee for every game.

## Download and requirements

There is no published OpenEmu Reborn release yet. Future packages belong on this repository's [Releases page](https://github.com/communism420/OpenEmu-Reborn/releases). Until then, use the [source-build guide](.github/CONTRIBUTING.md).

The app's deployment baseline is **macOS 11.0 or later** on an **Apple Silicon or 64-bit Intel Mac**. Individual cores and features may impose additional requirements. Both architectures does not mean every historical MacBook: 32-bit Intel and PowerPC are not supported targets.

Choose a package explicitly marked for your architecture. Native Apple Silicon needs an `arm64` app **and compatible cores**; Intel needs `x86_64`. A package is universal only when all required binaries contain both architectures. Upstream OpenEmu-Silicon downloads and its Homebrew cask are not Reborn releases or Intel packages.

ROMs and BIOS files are not supplied. Use your own game files and the BIOS required by the relevant system.

### Signing and permissions

Local test packages are not notarized releases. A signature does not automatically grant Input Monitoring permission or guarantee that another Mac will allow the app to open. Follow the [test-build guide](docs/intel-test-build.md); do not disable system-wide security protections.

The maintainer's private signing key stays on the maintainer's Mac. Users do not need that key, a paid developer account or Xcode to run a compatible packaged app. Building from source is a separate workflow.

## Systems and cores

The project integrates cores for NES, SNES, Game Boy / GBC, Game Boy Advance, Nintendo 64, Nintendo DS, PlayStation, PSP, Sega Genesis, Dreamcast, GameCube, Wii and more. The [native core inventory](AGENTS.md#supported-cores-as-of-2026) is not a game-by-game compatibility certificate.

The Intel test package contains 28 native core bundles. App-only updates can reuse them without recompilation. **A new app version does not mean the cores were updated to the latest upstream emulator versions.** See [test-build notes](docs/intel-test-build.md) for provenance and limitations.

Core availability still differs between architectures. Apple Silicon uses the OpenEmu-Silicon catalog; Intel uses the legacy official OpenEmu catalog as a compatibility fallback. Some fork-only Intel cores must be built from source or supplied in a package. The mirrored `Appcasts/` directory is not a new architecture-aware core update service.

The Nintendo 64 integration currently uses interpreter fallbacks, with a performance cost. Save states can depend on core, version and architecture; back them up before changing these. RetroAchievements support also depends on the system and core: inherited integrations are not a claim of separate Reborn certification.

## Existing installations and data

Rebranding preserves the bundle identifier, storage identifiers and existing signing identity. **It does not erase data or reset macOS permissions.** Back up before changing builds; avoid running multiple copies against one library.

Some technical names intentionally remain `OpenEmu`: the workspace, scheme, modules, executable and `OpenEmu.app` bundle. The maintainer's single local test directory remains `OpenEmu-Intel-test/`. These compatibility names do not mean the project is Intel-only.

See [Data folder and reset](docs/data-folder.md), [No Shader](docs/no-shader.md) and [Local signing and replacement](docs/local-signing.md).

## Where Reborn comes from

1. [OpenEmu/OpenEmu](https://github.com/OpenEmu/OpenEmu) — the original app, library experience and plugin architecture.
2. [bazley82/OpenEmuARM64](https://github.com/bazley82/OpenEmuARM64) — an ARM64-focused continuation built on the original work.
3. [OpenEmu-Silicon/OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon) — Reborn's direct upstream and basis for Apple Silicon support and newer integrations.
4. **OpenEmu Reborn** — an independent continuation welcoming both Apple Silicon and Intel users.

Most code comes from these projects and emulator authors. Their authorship, copyright notices and individual licenses remain intact. See [Credits](.github/CREDITS.md).

## Documentation and contributing

- [Contributing and building](.github/CONTRIBUTING.md)
- [Support and compatibility reports](.github/SUPPORT.md)
- [Data folder and reset](docs/data-folder.md)
- [Intel test package](docs/intel-test-build.md)
- [Local signing and safe replacement](docs/local-signing.md)
- [Privacy](docs/privacy-policy.md) and [security reporting](.github/SECURITY.md)

The [OpenEmu-Silicon wiki](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki) is an upstream reference, not Reborn's release or compatibility documentation. Its installation and architecture-specific instructions may differ.

Code, documentation, translations and test reports are welcome. Include your Mac model, architecture, macOS version, app version and core when reporting a problem. Use this repository's enabled collaboration channels, not an upstream tracker for Reborn-specific bugs.

Development uses AI assistance. It does not replace build checks, human decisions or real-hardware testing. Reports must distinguish tested behavior from intended support.

## License

Reborn does not relicense inherited code. See [LICENSE](LICENSE) and each file's copyright header; most inherited app files carry the OpenEmu Team's BSD 3-Clause terms. Cores have their own licenses. Keep required notices when distributing source or binaries. The project is free; bundled components such as Picodrive also carry non-commercial restrictions.
