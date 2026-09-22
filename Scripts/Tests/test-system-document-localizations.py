#!/usr/bin/env python3
"""Exercise the real post-install tool with private, synthetic bundles only."""
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))


def read_strings(path):
    return json.loads(subprocess.check_output(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)]))


class SystemDocumentLocalizations(unittest.TestCase):
    def test_explicit_translations_and_incremental_regional_names(self):
        with tempfile.TemporaryDirectory(prefix="openemu-document-localizations-") as temporary:
            fixture = Path(temporary)
            executable = fixture / "post-install"
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
                "-module-cache-path", str(fixture / "ModuleCache"),
                str(ROOT / "OpenEmu/OESystemPluginPostInstall/main.swift"),
                "-o", str(executable),
            ], check=True)
            app = fixture / "Fixture.app"
            info = app / "Contents/Info.plist"
            write_plist(info, {
                "CFBundleIdentifier": "org.openemu.tests.DocumentLocalizations",
                "CFBundlePackageType": "APPL",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDocumentTypes": [],
            })
            source = fixture / "Source"
            for locale, strings in {
                "en": {"%@ Game": "%@ Game"},
                "zh-Hans": {"%@ Game": "%@ 游戏", "Arcade Game": "街机游戏",
                            "OpenEmu Game": "OpenEmu 游戏文件"},
            }.items():
                write_plist(source / (locale + ".lproj/InfoPlist.strings"), strings)
                write_plist(app / "Contents/Resources" / (locale + ".lproj/InfoPlist.strings"), strings)
            systems = app / "Contents/PlugIns/Systems"
            for name, suffix, regional_name in [
                ("Arcade", "arc", "Arcade"), ("Console", "con", "Old Console"),
            ]:
                write_plist(systems / (name + ".oesystemplugin/Contents/Info.plist"), {
                    "CFBundleIdentifier": "org.openemu.tests." + name,
                    "CFBundlePackageType": "BNDL",
                    "OESystemName": name,
                    "OERegionalizedSystemNames": {"jp": regional_name},
                    "OEFileSuffixes": [suffix, "bin"],
                })
            arguments = [str(executable), str(app), str(source)]
            subprocess.run(arguments, check=True)
            translated_path = app / "Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
            first = read_strings(translated_path)
            self.assertEqual(first["Arcade Game"], "街机游戏")
            self.assertEqual(first["OpenEmu Game"], "OpenEmu 游戏文件")
            self.assertEqual(first["Console Game"], "Old Console 游戏")

            # No resource recopy: a second incremental invocation must refresh
            # generated entries without overwriting explicit translations.
            console_path = systems / "Console.oesystemplugin/Contents/Info.plist"
            console = plistlib.loads(console_path.read_bytes())
            console["OERegionalizedSystemNames"]["jp"] = "New Console"
            write_plist(console_path, console)
            subprocess.run(arguments, check=True)
            second = read_strings(translated_path)
            self.assertEqual(second["Console Game"], "New Console 游戏")
            self.assertEqual(second["Arcade Game"], first["Arcade Game"])
            self.assertEqual(second["OpenEmu Game"], first["OpenEmu Game"])
            documents = plistlib.loads(info.read_bytes())["CFBundleDocumentTypes"]
            self.assertEqual(sum(t["CFBundleTypeName"] == "Arcade Game" for t in documents), 1)
            self.assertEqual(sum(t["CFBundleTypeName"] == "OpenEmu Game" for t in documents), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
