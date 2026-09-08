# MAME Core for OpenEmu

This directory contains the OpenEmu MAME core wrapper, based on OpenEmu/UME-Core, with the changes needed to build natively for Apple Silicon or Intel against this fork.

Status: WIP. The build script now has explicit `arm64` and `x86_64` paths, but the Intel path is not yet covered by CI or a native runtime smoke test because the large MAME source dependency is not vendored. Treat Intel MAME support as experimental until that validation is complete. Polygonal 3D arcade rendering also still needs validation/debugging; use Sega Virtua Racing as the main repro case from issue #500.

## Source dependency

The MAME headless source is intentionally not committed here because it is very large. Prepare it with:

```sh
./Scripts/prepare-mame-core.sh
```

That clones `stuartcarnie/mame` at the pinned commit in `deps-mame-revision.txt` into `MAME/deps/mame` and applies `patches/mame-headless-clang21-apple.patch`.

The patch also backports MAME commit `b5fafba307ba7acc2aea90681c71a3d43aa9cac3`, which fixes a V60 float-to-integer conversion issue reported upstream as causing glitched Virtua Racing / Sega Model 1 graphics on aarch64.

## Build

To reproduce the full local build:

```sh
./Scripts/build-mame-core.sh
```

The script uses the current Mac architecture by default. To select one explicitly:

```sh
./Scripts/build-mame-core.sh --arch x86_64
./Scripts/build-mame-core.sh --arch arm64
```

The script automatically mirrors the checkout to a temporary no-space path when the repository path contains whitespace, because MAME's project generator cannot reliably build from paths such as `Open Emu`.

The script does the following:

1. Prepares `MAME/deps/mame` if needed.
2. Builds `mamearcade_headless.dylib` for the selected architecture with the headless OSD.
3. Builds `OpenEmuBase.framework` into the same DerivedData path.
4. Builds `MAME.oecoreplugin`.

Product path:

```text
MAME/build/XcodeDerived/Build/Products/Release/MAME.oecoreplugin
```

## Manual build notes

```sh
cd MAME/deps/mame
make NOWERROR=1 REGENIE=1 macosx_x64_clang \
  OSD="headless" verbose=1 TARGETOS="macosx" CONFIG="release" \
  TARGET=mame SUBTARGET=arcade MACOSX_DEPLOYMENT_TARGET=11.0 \
  -j"$(sysctl -n hw.ncpu)"
install_name_tool -id mamearcade_headless.dylib mamearcade_headless.dylib
```

Use `macosx_arm64_clang` instead when building on Apple Silicon.

Then build `OpenEmuBase` and the `MAME` project with the same `-derivedDataPath`.

## Local testing

Install the built plugin with the repo helper, which avoids stale bundle merges:

```sh
./Scripts/install-core.sh MAME --release
./Scripts/verify-core-installed.sh MAME --release
```

Use a MAME 0.250-compatible ROM set. Validate both:

- A known sprite-based arcade game, to confirm the core path works.
- Sega Virtua Racing, to investigate the missing polygon issue from #500.
