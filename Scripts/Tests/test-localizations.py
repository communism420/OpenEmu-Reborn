#!/usr/bin/env python3
"""Private localization fixtures; no app build, network or user-data access."""

import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "check-localizations.py"
SPEC = importlib.util.spec_from_file_location("localization_audit", SCRIPT)
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class LocalizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="openemu-localizations-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def strings(self, locale, values, table="Localizable"):
        path = self.root / "OpenEmu" / (locale + ".lproj") / (table + ".strings")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(values, sort_keys=True))
        return path

    def source(self, value, name="Fixture.swift"):
        path = self.root / "OpenEmu" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")
        return path

    def test_xml_and_utf16_preserve_non_ascii(self):
        path = self.strings("ru", {"Hello": "Привет 🌍"})
        self.assertEqual(AUDIT.read_strings(path), ({"Hello": "Привет 🌍"}, []))
        xml = path.read_text().replace('encoding="UTF-8"', 'encoding="UTF-16"')
        path.write_bytes(xml.encode("utf-16"))
        self.assertEqual(AUDIT.read_strings(path)[0]["Hello"], "Привет 🌍")

    def test_xml_duplicate_is_not_lost(self):
        path = self.strings("en", {"Duplicate": "old"})
        xml = path.read_text().replace("</dict>", "<key>Duplicate</key><string>new</string></dict>")
        path.write_text(xml)
        values, duplicates = AUDIT.read_strings(path)
        self.assertEqual(duplicates, ["Duplicate"])
        self.assertEqual(values["Duplicate"], "new")

    def test_openstep_comments_escapes_and_duplicate(self):
        path = self.strings("en", {})
        path.write_text(r'''/* Header */
"Line\nTwo" = "Привет\n\"quoted\"";
// This should not make another key: "Fake" = "No";
"\U00E9" = "first";
"é" = "second";
''')
        values, duplicates = AUDIT.read_strings(path)
        self.assertEqual(values["Line\nTwo"], 'Привет\n"quoted"')
        self.assertEqual(duplicates, ["é"])

    def test_invalid_openstep_and_non_string_xml_fail(self):
        path = self.strings("en", {})
        path.write_text('"A" = "B"')
        with self.assertRaises(ValueError):
            AUDIT.read_strings(path)
        path.write_bytes(plistlib.dumps({"A": 5}))
        with self.assertRaisesRegex(ValueError, "must be strings"):
            AUDIT.read_strings(path)

    def test_multiline_swift_call_and_literal(self):
        text = '''let first = NSLocalizedString(
            "Hello\\nWorld", tableName: "Custom", value: "Default", comment: "")
        let second = NSLocalizedString("""
            First line
            Second line
            """, comment: "")
        // NSLocalizedString("Comment", comment: "")
        /* Nested /* comment */ NSLocalizedString("No", comment: "") */
        '''
        references, reviews = AUDIT.source_references(text, "Fixture.swift")
        self.assertEqual([(r["key"], r["table"], r["default"]) for r in references],
                         [("Hello\nWorld", "Custom", "Default"), ("First line\nSecond line", "Localizable", "First line\nSecond line")])
        self.assertEqual(references[0]["line"], 1)
        self.assertEqual(reviews, [])

    def test_objective_c_table_unicode_and_adjacent_literals(self):
        references, reviews = AUDIT.source_references(r'''
NSLocalizedStringFromTable(@"Play \u2026" @" now", @"Controls", @"");
NSLocalizedStringWithDefaultValue(@"StableKey", @"Other", bundle, @"Default %@", @"");
NSLocalizedStringFromTableInBundle(@"Other key", @"Other", bundle, @"");
''', "Fixture.m")
        self.assertEqual([(r["key"], r["table"]) for r in references],
                         [("Play … now", "Controls"), ("StableKey", "Other"), ("Other key", "Other")])
        self.assertEqual(references[1]["default"], "Default %@")
        self.assertEqual(reviews, [])

    def test_core_picker_header_and_install_error_have_localized_producers(self):
        # A translated catalog entry alone cannot localize a literal stored in
        # the column tuple or an NSError description. Check the real producers.
        source = SCRIPT.parents[1] / "OpenEmu" / "PrefCoresController.swift"
        references, _ = AUDIT.source_references(source.read_text(), str(source))
        localized = {(item["table"], item["key"]) for item in references}
        for key in ("Select Core",
                    "No bridge bundle or installed OpenEmu core found to seed the plugin executable."):
            self.assertIn(("Localizable", key), localized)

    def test_swift_raw_strings_and_unicode(self):
        text = r'''NSLocalizedString(#"Literal \n, but \#n and \#u{1F30D}"#, comment: "")'''
        references, _ = AUDIT.source_references(text, "Fixture.swift")
        self.assertEqual(references[0]["key"], "Literal \\n, but \n and 🌍")

    def test_nil_table_and_nested_interpolation(self):
        references, _ = AUDIT.source_references('NSLocalizedStringFromTable(@"Default", nil, @"");', "Fixture.m")
        self.assertEqual(references[0]["table"], "Localizable")
        references, reviews = AUDIT.source_references(r'''NSLocalizedString("Hello \(name ?? "Unknown")", comment: "")''', "Fixture.swift")
        self.assertEqual(references, [])
        self.assertEqual(reviews[0]["kind"], "dynamic_key")

    def test_dynamic_keys_are_reported_not_partially_counted(self):
        references, reviews = AUDIT.source_references(r'''
NSLocalizedString(prefix + "tail", comment: "")
NSLocalizedString("Hello \(name)", comment: "")
NSLocalizedString("Static", tableName: table, comment: "")
''', "Fixture.swift")
        self.assertEqual(references, [])
        self.assertEqual([r["kind"] for r in reviews], ["dynamic_key"] * 3)

    def test_hardcoded_ui_is_review_only_not_all_literals(self):
        _, reviews = AUDIT.source_references('''let debug = "Private log"
alert.messageText = "Hello"
let button = NSButton(title: "Press", target: nil, action: nil)
button.title = NSLocalizedString("Localized", comment: "")
''', "Fixture.swift")
        self.assertEqual([r["key"] for r in reviews], ["Hello", "Press"])

    def test_empty_lookup_is_not_a_missing_translation(self):
        references, reviews = AUDIT.source_references('NSLocalizedString("", comment: "")', "Fixture.swift")
        self.assertEqual(references, [])
        self.assertEqual(reviews, [])

    def test_control_plist_reads_display_rows_not_metadata(self):
        path = self.source("", "SystemPlugins/Fixture/Fixture-Info.plist")
        path.write_bytes(plistlib.dumps({
            "CFBundleName": "Private Bundle Name",
            "OEControlListKeyLabelKey": "Outside Control List",
            "Other": {"OEControlListKeyLabelKey": "Nested Metadata"},
            "OEControlListKey": [["Wiimote", "Buttons", "-", "", {
                "OEControlListKeyLabelKey": "Home",
                "OEControlListKeyNameKey": "OEPrivateButtonHome",
                "OtherMetadata": "Not Displayed",
            }, {"OEControlListKeyLabelKey": "-", "OEControlListKeyNameKey": "Minus"},
                {"OEControlListKeyNameKey": "Unlabelled"}], ["Tilt", {
                    "OEControlListKeyLabelKey": "Forward",
                    "OEControlListKeyNameKey": "InternalForward",
                }]],
        }))
        references, reviews = AUDIT.control_plist_references(path, "Fixture-Info.plist")
        self.assertEqual([r["key"] for r in references], ["Wiimote", "Buttons", "Home", "-", "Tilt", "Forward"])
        self.assertTrue(all(r["table"] == "ControlLabels" for r in references))
        self.assertEqual(references[2]["plist_key"], "OEControlListKey[0][4]")
        self.assertEqual(reviews, [])

    def test_control_plist_ignores_comments_and_supports_binary(self):
        path = self.source("", "SystemPlugins/Fixture/Fixture-Info.plist")
        values = {"OEControlListKey": [[{"OEControlListKeyLabelKey": "Sleep"}]]}
        xml = plistlib.dumps(values).decode().replace("<dict>", """<dict>
<!-- <key>OEControlListKeyLabelKey</key><string>Commented Label</string> -->""", 1)
        path.write_text(xml)
        self.assertEqual([r["key"] for r in AUDIT.control_plist_references(path, "Fixture")[0]], ["Sleep"])
        path.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
        self.assertEqual([r["key"] for r in AUDIT.control_plist_references(path, "Fixture")[0]], ["Sleep"])
        path.write_bytes(plistlib.dumps({"OEControlListKeyLabelKey": "Outside"}))
        self.assertEqual(AUDIT.control_plist_references(path, "Fixture"), ([], []))

    def test_sdk_global_button_labels_ignore_comments_and_other_calls(self):
        references, reviews = AUDIT.source_references(r'''
// Button(@"Not a global label", PrivateIdentifier)
- (NSArray *)unrelated { return @[Button(@"Unrelated", PrivateIdentifier)]; }
- (NSArray *)OE_globalButtonsControlList
{
#define Button(_LABEL_, _NAME_) @{ OEControlListKeyLabelKey : _LABEL_, OEControlListKeyNameKey : _NAME_ }
    NSString *metadata = @"Not Displayed";
    return @[Button(@"Stop", OEGlobalButtonStop),
        //Button(@"Slow Motion", OEGlobalButtonSlowMotion),
        /* Button(@"Old Label", OEGlobalButtonUnused) */
        Button(@"New " @"Action", OEGlobalButtonFuture)];
#undef Button
}
''', "OpenEmu-SDK/OpenEmuSystem/OESystemController.m")
        self.assertEqual([(r["key"], r["table"]) for r in references],
                         [("Stop", "ControlLabels"), ("New Action", "ControlLabels")])
        self.assertEqual(reviews, [])

    def test_sdk_control_sections_only_inventory_title_slots(self):
        references, reviews = AUDIT.source_references(r'''
- (void)setup {
    _controlPageList = @[
        @"Gameplay Buttons", [_bundle.infoDictionary objectForKey: @"OEControlListKey"],
        @"Future Section", [self OE_globalButtonsControlList],
    ];
}
''', "Fixture.m")
        self.assertEqual([r["key"] for r in references], ["Gameplay Buttons", "Future Section"])
        self.assertEqual(reviews, [])

    def test_dynamic_sdk_control_producer_requires_review(self):
        references, reviews = AUDIT.source_references(r'''
- (NSArray *)OE_globalButtonsControlList { return @[Button(computedLabel, ButtonIdentifier)]; }
- (void)setup { _controlPageList = @[computedSection, [self OE_globalButtonsControlList]]; }
''', "Fixture.m")
        self.assertEqual(references, [])
        self.assertEqual([r["kind"] for r in reviews], ["dynamic_control_label"] * 2)

    def test_audit_includes_control_producers_missing_in_every_catalog(self):
        self.strings("en", {"Existing": "Existing"}, "ControlLabels")
        self.strings("ru", {"Existing": "Существующий"}, "ControlLabels")
        path = self.source("", "SystemPlugins/Fixture/Fixture-Info.plist")
        path.write_bytes(plistlib.dumps({"OEControlListKey": [["Controller", {
            "OEControlListKeyLabelKey": "Home", "OEControlListKeyNameKey": "InternalName",
        }]]}))
        self.source('- (NSArray *)OE_globalButtonsControlList { return @[Button(@"Stop", Identifier)]; }',
                    "Fixture.m")
        result = AUDIT.audit(self.root)
        missing = [r for r in result["findings"] if r["kind"] == "missing_key"]
        self.assertEqual([(r["locale"], r["table"], r["key"]) for r in missing],
                         [(locale, "ControlLabels", key) for locale in ["en", "ru"]
                          for key in ["Controller", "Home", "Stop"]])
        self.assertEqual(result["summary"]["errors"], 6)

    def test_malformed_control_plist_is_error_not_silently_skipped(self):
        self.strings("en", {"Existing": "Existing"})
        path = self.source("", "SystemPlugins/Fixture/Fixture-Info.plist")
        for value in ({"OEControlListKey": "Not an array"},
                      {"OEControlListKey": ["Not a group"]},
                      {"OEControlListKey": [[{"OEControlListKeyLabelKey": 3}]]}):
            with self.subTest(value=value):
                path.write_bytes(plistlib.dumps(value))
                findings = AUDIT.audit(self.root)["findings"]
                self.assertEqual([r["kind"] for r in findings], ["unscanned_source"])

    def test_explicit_system_plugin_source_root_preserves_control_inventory(self):
        self.strings("en", {"Home": "Home"}, "ControlLabels")
        path = self.source("", "SystemPlugins/Fixture/Fixture-Info.plist")
        path.write_bytes(plistlib.dumps({"OEControlListKey": [[{"OEControlListKeyLabelKey": "Home"}]]}))
        result = AUDIT.audit(self.root, source_roots=["OpenEmu/SystemPlugins"])
        self.assertEqual(result["summary"]["errors"], 0)
        self.assertEqual(result["canonical_terms"][0]["references"], [{
            "path": "OpenEmu/SystemPlugins/Fixture/Fixture-Info.plist",
            "plist_key": "OEControlListKey[0][0]",
        }])

    def test_xib_string_child_title(self):
        path = self.source('''<document><textField id="label"><textFieldCell>
<string key="title">First line\nSecond line</string></textFieldCell>
<userDefinedRuntimeAttributes><userDefinedRuntimeAttribute keyPath="localizeTitle" value="YES"/></userDefinedRuntimeAttributes>
</textField></document>''', "Child.xib")
        references, reviews = AUDIT.xib_references(path, "Child.xib", {})
        self.assertEqual(references[0]["key"], "First line\nSecond line")
        self.assertEqual(references[0]["table"], "OEControls")
        self.assertEqual(reviews, [])

    def test_xib_titles_and_menu_fallback(self):
        path = self.source('''<document><objects>
<button id="button"><buttonCell title="Choose"/><userDefinedRuntimeAttributes>
<userDefinedRuntimeAttribute type="boolean" keyPath="localizeTitle" value="YES"/>
</userDefinedRuntimeAttributes></button>
<menuItem title="Quit" id="quit"><userDefinedRuntimeAttributes>
<userDefinedRuntimeAttribute type="boolean" keyPath="localizeTitle" value="YES"/>
</userDefinedRuntimeAttributes></menuItem>
<menu title="Fallback" id="fallback"><userDefinedRuntimeAttributes>
<userDefinedRuntimeAttribute type="boolean" keyPath="localizeTitle" value="YES"/>
</userDefinedRuntimeAttributes></menu>
<button id="dynamic"><userDefinedRuntimeAttributes>
<userDefinedRuntimeAttribute type="boolean" keyPath="localizeTitle" value="YES"/>
</userDefinedRuntimeAttributes></button>
</objects></document>''', "Fixture.xib")
        references, reviews = AUDIT.xib_references(path, "Fixture.xib", {"Localizable": {"Fallback": "Fallback"}})
        self.assertEqual([(r["key"], r["table"]) for r in references],
                         [("Choose", "OEControls"), ("Quit", "MainMenu"), ("Fallback", "Localizable")])
        self.assertEqual(reviews[0]["kind"], "dynamic_xib_title")

    def test_format_reordering_and_escaped_percent(self):
        self.assertEqual(AUDIT.format_signature("%ld games in %@; 100%%"),
                         AUDIT.format_signature("%2$@ : %1$ld jeux; 100%%"))
        self.assertNotEqual(AUDIT.format_signature("%@ %d"), AUDIT.format_signature("%d %@"))
        self.assertNotEqual(AUDIT.format_signature("%ld"), AUDIT.format_signature("%d"))
        self.assertEqual(AUDIT.format_signature("%i"), AUDIT.format_signature("%d"))

    def test_format_dynamic_width_and_precision(self):
        self.assertEqual(AUDIT.format_signature("%*.*f"), AUDIT.format_signature("%3$*1$.*2$f"))
        self.assertEqual(AUDIT.format_signature("%*.*f"), [[1, "signed", 1], [2, "signed", 1], [3, "double", 1]])
        with self.assertRaisesRegex(ValueError, "mixed positional"):
            AUDIT.format_signature("%1$@ %@")

    def test_audit_reports_missing_source_and_language_keys(self):
        self.strings("en", {"Existing": "Existing", "Empty": "Value", "%@": "%@"})
        self.strings("ru", {"Existing": "Существующий", "Empty": "", "%@": "%d"})
        self.source('NSLocalizedString("New source key", comment: "")')
        result = AUDIT.audit(self.root)
        missing = [r for r in result["findings"] if r["kind"] == "missing_key"]
        self.assertEqual([(r["locale"], r["key"]) for r in missing], [("en", "New source key"), ("ru", "New source key")])
        self.assertEqual(result["summary"]["counts"]["placeholder_mismatch"], 1)
        self.assertEqual(result["summary"]["counts"]["empty_translation"], 1)
        canonical = next(t for t in result["canonical_terms"] if t["key"] == "New source key")
        self.assertEqual(canonical["missing_locales"], ["en", "ru"])
        self.assertEqual(canonical["references"], [{"path": "OpenEmu/Fixture.swift", "line": 1}])

    def test_french_canadian_explicitly_inherits_french(self):
        self.strings("en", {"Settings": "Settings"})
        self.strings("fr", {"Settings": "Réglages"})
        self.strings("fr-CA", {"CFBundleName": "OpenEmu"}, "InfoPlist")
        result = AUDIT.audit(self.root)
        self.assertIn("fr-CA", result["locales"])
        self.assertFalse(any(r["kind"] == "missing_key" and r["locale"] == "fr-CA" for r in result["findings"]))
        term = next(t for t in result["canonical_terms"] if t["key"] == "Settings")
        self.assertEqual(term["inherited_locales"], {"fr-CA": "fr"})
        self.assertEqual(result["summary"]["errors"], 0)

    def test_regional_fallback_cannot_hide_a_missing_base_translation(self):
        self.strings("en", {"Settings": "Settings"})
        self.strings("fr", {})
        self.strings("fr-CA", {"CFBundleName": "OpenEmu"}, "InfoPlist")
        self.strings("es-MX", {"CFBundleName": "OpenEmu"}, "InfoPlist")
        missing = [r["locale"] for r in AUDIT.audit(self.root)["findings"] if r["kind"] == "missing_key"]
        self.assertEqual(missing, ["es-MX", "fr", "fr-CA"])

    def test_identical_english_is_not_error_and_can_be_reviewed(self):
        self.strings("en", {"BIOS": "BIOS"})
        self.strings("ru", {"BIOS": "BIOS"})
        result = AUDIT.audit(self.root)
        self.assertEqual(result["summary"]["errors"], 0)
        self.assertEqual(result["summary"]["unreviewed"], 1)
        policy = {"accepted": [{"id": result["findings"][0]["id"], "reason": "Technical acronym remains BIOS in Russian."}]}
        result = AUDIT.audit(self.root, policy=policy)
        self.assertEqual(result["summary"]["unreviewed"], 0)

    def test_policy_cannot_hide_missing_translation_or_go_stale(self):
        self.strings("en", {"Hello": "Hello"})
        self.strings("ru", {})
        result = AUDIT.audit(self.root)
        policy = {"accepted": [{"id": result["findings"][0]["id"], "reason": "Not a valid exemption"}]}
        with self.assertRaisesRegex(ValueError, "cannot suppress"):
            AUDIT.audit(self.root, policy=policy)
        policy["accepted"][0]["id"] = "does-not-match"
        self.assertIn("stale_policy_entry", AUDIT.audit(self.root, policy=policy)["summary"]["counts"])

    def test_source_parse_failure_is_an_error_not_skipped(self):
        self.strings("en", {"Hello": "Hello"})
        self.source('NSLocalizedString("unfinished')
        self.assertIn("unscanned_source", AUDIT.audit(self.root)["summary"]["counts"])

    def test_json_cli_is_deterministic_and_read_only(self):
        self.strings("en", {"OK": "OK"})
        self.strings("ru", {"OK": "OK"})
        self.strings("en", {"Stop": "Stop"}, "ControlLabels")
        self.strings("ru", {"Stop": "Остановить"}, "ControlLabels")
        self.source('- (NSArray *)OE_globalButtonsControlList { return @[Button(@"Stop", Identifier)]; }',
                    "Fixture.m")
        path = self.source("", "SystemPlugins/Fixture/Fixture-Info.plist")
        path.write_bytes(plistlib.dumps({"OEControlListKey": [[{"OEControlListKeyLabelKey": "Stop"}]]}))
        command = [sys.executable, str(SCRIPT), "--repo", str(self.root), "--format", "json"]
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        first = subprocess.run(command, capture_output=True, check=False)
        second = subprocess.run(command, capture_output=True, check=False)
        strict = subprocess.run(command + ["--require-reviewed"], capture_output=True, check=False)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual(strict.returncode, 1)
        self.assertEqual(json.loads(first.stdout)["summary"]["errors"], 0)
        self.assertEqual(before, {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})


if __name__ == "__main__":
    unittest.main()
