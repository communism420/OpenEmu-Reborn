# Localization checks

This read-only tool inventories the existing OpenEmu translation tables and
literal source lookups. It does not build or launch the app, change translations,
contact a translation service, or read user preferences. Python 3 and macOS
`plutil` are the only requirements; no third-party Python packages are needed.

```sh
python3 Scripts/Tests/test-localizations.py
python3 Scripts/check-localizations.py
python3 Scripts/check-localizations.py --format json
```

The JSON is deterministic for the same files. `canonical_terms` gives the table,
key, English value, source references, missing languages and deliberate regional
inheritance. Translation work must preserve the key and format arguments while
translating the English value. It must not fill untranslated values with English
merely to satisfy coverage. The checker never writes resource files.

By default every existing `OpenEmu/*.lproj` language is included. The existing
`fr-CA` directory contains regional `InfoPlist` overrides and inherits the full
French interface from `fr`; the report lists this explicitly in
`regional_fallbacks` and each term's `inherited_locales`. A missing French base
translation still fails. No other language or region is silently exempted.
Use `--locale ru` (repeatable) to focus a review; English is always checked.

## What fails

- Missing keys, including literal Swift/Objective-C lookups absent from English.
- Empty translations, duplicate keys, malformed tables and non-string values.
- Format argument differences (`%@`, `%ld`, etc.). Positional translations such
  as `%2$@` can reorder arguments, but must preserve their types and occurrences.
  Dynamic width/precision and escaped `%%` are handled. Mixing positional and
  non-positional arguments fails.
- Source files that cannot be scanned. These are not silently skipped.

Both XML and quoted OpenStep `.strings` are supported, including UTF-16 source.
Duplicate keys are detected before the normal plist parser can discard them.
OpenStep values are parsed with Apple's `plutil`. Binary `.strings` source is
rejected: convert it to editable XML instead of hiding duplicate/source content.

## What needs a person

`review` findings do not fail the default command. Add `--require-reviewed` to
require a documented decision about every finding:

- Values identical to English can be legitimate names, acronyms, symbols or words
  shared by two languages. Equality alone does not mean a translation is bad.
- Dynamic localization keys and table names need an inventory of their producers
  (for example control labels and debug preference definitions).
- Raw UI property strings and XIB titles without `localizeTitle` are candidates,
  not conclusive bugs. Some are templates replaced in code or private identifiers.
- Locale-only keys may be regional overrides, stale entries or missing English.

For a reviewed exception create a JSON policy using the exact finding ID from
the report and a specific explanation:

```json
{
  "accepted": [
    {
      "id": "copy-the-exact-finding-id-from-the-report",
      "reason": "BIOS is the standard technical acronym in this language."
    }
  ]
}
```

Pass it with `--policy path/to/policy.json --require-reviewed`. This is an
explicit review baseline, not a blanket exemption: wildcards are not supported,
mechanical errors cannot be suppressed, and stale IDs fail so the reviewer must
revisit changed source. Do not automatically accept all findings.

## Limits

This is not a Swift/Objective-C compiler or a language-quality checker. It scans
`NSLocalizedString` and the Foundation `FromTable`, `FromTableInBundle`, and
`WithDefaultValue` variants, including multiline calls/literals, escaped Unicode,
Objective-C adjacent literals, Swift raw strings, and explicit literal `+` joins.
Interpolated/computed strings are review findings, not guessed translation keys.
It resolves XIB `localizeTitle` lookups according to `NSControl+i18n.swift`'s
OEControls/MainMenu/Localizable table selection. It also follows the display
labels in system-plugin `OEControlListKey` property lists and the SDK's global
button/section producers, excluding internal control identifiers and commented
code. Other dynamic producer data, custom
lookup APIs, `.stringsdict` plurals, resource embedding and native/AppKit strings
still need separate review and a built-app check.

The raw UI heuristic is deliberately incomplete: it finds common literal
property assignments and constructor arguments, not every possible visible
string. A clean mechanical report does not prove that every screen is translated,
that a translation is natural, or that translated controls fit. Test language
selection, restart persistence, right-to-left layouts, and long translations in
the app as well.
