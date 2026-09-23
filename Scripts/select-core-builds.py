#!/usr/bin/env python3
"""Select core jobs from reviewed PR paths, without asserting artifact reuse.

Non-PR events still build all 28 cores on both CPUs. A skipped job means its
inputs were not selected by this path policy, NOT that an old build has been
verified. The separate artifact-provenance and publication gates are unchanged.

The caller must supply both sides of renames/deletions, for example with:
    git diff --no-renames --name-only -z BASE HEAD > changed-paths
    python3 Scripts/select-core-builds.py --event pull_request \
        --changed-paths-null changed-paths
"""

import argparse
import json
from pathlib import Path


CORES = (
    "4DO", "Atari800", "Bliss", "BSNES", "CrabEmu", "DeSmuME", "Dolphin",
    "FCEU", "Flycast", "Gambatte", "GenesisPlus", "JollyCV", "Mednafen",
    "mGBA", "Mupen64Plus", "Nestopia", "O2EM", "Picodrive", "PokeMini",
    "Potator", "PPSSPP", "ProSystem", "SNES9x", "Stella", "VecXGL",
    "VirtualJaguar", "blueMSX",
)
CORE_DIRS = {"Potator": "Potator-Core", "Picodrive": "picodrive"}
RCHEEVOS_CORES = frozenset({
    "BSNES", "DeSmuME", "FCEU", "Gambatte", "GenesisPlus", "Mednafen", "mGBA",
    "Mupen64Plus", "Nestopia", "SNES9x", "Stella",
})

# Exact reviewed host-only fixtures; no blanket exception for Scripts/Tests/.
# None is invoked by a core build/scheme or changes a packaged core artifact.
# In particular build/sign/package/install/verify/provenance helpers are NOT
# exempt. New scripts must retain the full-build default until reviewed.
HOST_CHECKS = frozenset({
    "Scripts/check-localizations.py",
    "Scripts/Tests/test-localizations.py",
    "Scripts/Tests/test-system-document-localizations.py",
    "Scripts/Tests/test-artwork-migration.sh",
    "Scripts/Tests/ArtworkMigrationSmokeTests.swift",
    "Scripts/Tests/LOCALIZATION-AUDIT.md",
    "Scripts/Tests/test-interface-language.sh",
    "Scripts/Tests/InterfaceLanguageEntrypointProbe.swift",
    "Scripts/Tests/InterfaceLanguageSmokeTests.swift",
    "Scripts/Tests/test-helper-localization.sh",
    "Scripts/Tests/HelperLocalizationSmokeTests.m",
    "Scripts/Tests/HelperLocalizationSwiftProbe.swift",
    "Scripts/Tests/test-reborn-app-branding.py",
    "Scripts/Tests/test-data-folder-panel.sh",
    "Scripts/Tests/DataFolderPanelAppDriver.m",
    "Scripts/Tests/DataFolderPanelSmokeTests.swift",
})
SHARED_PREFIXES = (
    "OpenEmu-SDK/", "OpenEmuKit/", "OpenEmu-metal.xcworkspace/",
    # Core projects import responder headers from this host-owned directory.
    "OpenEmu/SystemPlugins/",
    # Workflow/toolchain changes need fresh builds, not just the path fixture.
    ".github/workflows/",
)


def select(event, changed_paths):
    if event != "pull_request":
        return {"cores": list(CORES), "mame": True, "reason": "full non-PR check"}
    if not isinstance(changed_paths, list) or any(
            not isinstance(path, str) or not path or path.startswith("/")
            or "\x00" in path or any(part in ("", ".", "..") for part in path.split("/"))
            for path in changed_paths):
        raise ValueError("expected repository-relative changed paths")

    selected = set()
    mame = False
    for path in changed_paths:
        if path in HOST_CHECKS:
            continue
        if path.startswith(SHARED_PREFIXES) or path.startswith("Scripts/"):
            return {"cores": list(CORES), "mame": True,
                    "reason": "shared build input or unreviewed script changed"}

        # Preserve the former host-project scope: the host's project.pbxproj,
        # scheme and Config.xcconfig are not themselves core project inputs.
        # Adding host source entries must not imply 56 core rebuilds. Core
        # projects select their own core below; the shared workspace selects
        # all above. Any future dependency on another host path needs an
        # explicit rule here, rather than a broad exemption for build tools.
        if path.startswith("OpenEmu/"):
            continue
        if path.startswith("docs/") or path in (
                "README.md", "README.ru.md", "AGENTS.md", "LICENSE"):
            continue

        for core in CORES:
            if path.startswith(CORE_DIRS.get(core, core) + "/"):
                selected.add(core)
        if path.startswith("Vendor/rcheevos/"):
            selected.update(RCHEEVOS_CORES)

        # Deliberately narrow optimization: MAME was previously always built.
        # Skip it only for wholly reviewed host/test/documentation changes.
        # MAME/, other cores and unknown dependencies retain that old check.
        mame = True

    return {"cores": [core for core in CORES if core in selected], "mame": mame,
            "reason": "PR path selection (not artifact reuse)"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", required=True)
    parser.add_argument("--changed-paths-null", type=Path,
                        help="NUL-delimited git diff --no-renames --name-only -z output")
    arguments = parser.parse_args()
    try:
        paths = []
        if arguments.event == "pull_request":
            if arguments.changed_paths_null is None:
                raise ValueError("PR selection requires the complete changed-paths file")
            raw = arguments.changed_paths_null.read_bytes()
            if raw and not raw.endswith(b"\x00"):
                raise ValueError("changed-paths file is not NUL-terminated")
            paths = [path.decode("utf-8", "surrogateescape") for path in raw.split(b"\x00")[:-1]]
        result = select(arguments.event, paths)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(result))


if __name__ == "__main__":
    main()
