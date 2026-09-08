#!/usr/bin/env python3
"""Turn an OpenEmu + Core scheme into a core-only CI build scheme.

The combined workspace schemes intentionally build both the selected core and
OpenEmu so developers can launch the app from Xcode. CI builds OpenEmu in its
own job, so rebuilding it in every core matrix job is unnecessary. This script
removes only OpenEmu's BuildAction entry from the checkout copy of a scheme;
the LaunchAction and all other scheme settings stay in place.
"""

from __future__ import annotations

import argparse
import os
import stat
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NoReturn, Optional


OPENEMU_REFERENCE = {
    "BlueprintName": "OpenEmu",
    "BuildableName": "OpenEmu.app",
    "ReferencedContainer": "container:OpenEmu/OpenEmu.xcodeproj",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove OpenEmu from a combined core scheme's BuildAction for CI."
    )
    parser.add_argument("scheme", type=Path, help="path to an OpenEmu + Core .xcscheme")
    return parser.parse_args()


def direct_children(parent: ET.Element, tag: str) -> list[ET.Element]:
    return [child for child in parent if child.tag == tag]


def main() -> None:
    scheme_path = parse_args().scheme
    if not scheme_path.is_file():
        fail(f"scheme does not exist or is not a file: {scheme_path}")
    if not (
        scheme_path.name.startswith("OpenEmu + ")
        and scheme_path.name.endswith(".xcscheme")
    ):
        fail(f"expected an 'OpenEmu + <Core>.xcscheme' file: {scheme_path.name}")

    try:
        tree = ET.parse(scheme_path)
    except ET.ParseError as error:
        fail(f"invalid scheme XML in {scheme_path}: {error}")

    root = tree.getroot()
    if root.tag != "Scheme":
        fail(f"unexpected XML root {root.tag!r} in {scheme_path}")

    build_actions = direct_children(root, "BuildAction")
    if len(build_actions) != 1:
        fail(f"expected exactly one BuildAction, found {len(build_actions)}")
    build_action = build_actions[0]
    if build_action.get("buildImplicitDependencies") != "YES":
        fail("combined scheme must enable implicit dependencies")

    entries_containers = direct_children(build_action, "BuildActionEntries")
    if len(entries_containers) != 1:
        fail(
            "expected exactly one BuildActionEntries container, "
            f"found {len(entries_containers)}"
        )
    entries_container = entries_containers[0]
    entries = direct_children(entries_container, "BuildActionEntry")
    if len(entries) != 2:
        fail(f"expected exactly two BuildAction entries, found {len(entries)}")

    references: dict[ET.Element, ET.Element] = {}
    for entry in entries:
        entry_references = direct_children(entry, "BuildableReference")
        if len(entry_references) != 1:
            fail(
                "each BuildActionEntry must contain exactly one BuildableReference; "
                f"found {len(entry_references)}"
            )
        references[entry] = entry_references[0]

    openemu_entries = [
        entry
        for entry, reference in references.items()
        if all(reference.get(key) == value for key, value in OPENEMU_REFERENCE.items())
    ]
    if len(openemu_entries) != 1:
        fail(
            "expected exactly one OpenEmu BuildAction entry with the canonical "
            f"reference, found {len(openemu_entries)}"
        )

    core_entries = [entry for entry in entries if entry is not openemu_entries[0]]
    if len(core_entries) != 1:
        fail(f"expected exactly one core BuildAction entry, found {len(core_entries)}")
    core_reference = references[core_entries[0]]
    core_name = core_reference.get("BlueprintName")
    if not core_name or core_name == "OpenEmu":
        fail("remaining BuildAction entry is not a named core target")
    if core_reference.get("ReferencedContainer") == OPENEMU_REFERENCE["ReferencedContainer"]:
        fail("remaining BuildAction entry unexpectedly references the OpenEmu project")
    scheme_core_name = scheme_path.name.removeprefix("OpenEmu + ").removesuffix(
        ".xcscheme"
    )
    if core_name not in (scheme_core_name, f"Build & Install {scheme_core_name}"):
        fail(
            f"scheme name selects {scheme_core_name!r}, but its core target is "
            f"{core_name!r}"
        )

    launch_actions = direct_children(root, "LaunchAction")
    if len(launch_actions) != 1:
        fail(f"expected exactly one LaunchAction, found {len(launch_actions)}")
    launch_action_before = ET.tostring(launch_actions[0], encoding="unicode")

    entries_container.remove(openemu_entries[0])

    remaining_entries = direct_children(entries_container, "BuildActionEntry")
    if remaining_entries != core_entries:
        fail("post-edit validation failed: the core BuildAction entry changed")
    launch_action_after = ET.tostring(launch_actions[0], encoding="unicode")
    if launch_action_after != launch_action_before:
        fail("post-edit validation failed: LaunchAction changed")

    mode = stat.S_IMODE(scheme_path.stat().st_mode)
    temporary_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=scheme_path.parent,
            prefix=f".{scheme_path.name}.",
            delete=False,
        ) as temporary_file:
            temporary_path = Path(temporary_file.name)
            tree.write(temporary_file, encoding="UTF-8", xml_declaration=True)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, scheme_path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()

    print(f"Prepared core-only CI scheme for {core_name}: {scheme_path}")


if __name__ == "__main__":
    main()
