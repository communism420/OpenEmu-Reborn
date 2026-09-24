# Interface languages

OpenEmu Reborn 1.0.1 adds **Preferences → Library → Interface Language**.
Choose a language by its native name, or choose **System Default** to follow
macOS. Quit and reopen the same app to apply the selection. No automatic restart
or change to the Mac's language settings is performed.

The selection is an ordinary `OEPreferences` setting named
`OEInterfaceLanguage` in the selected data folder's `Settings.plist`. Saving it
preserves unrelated preferences. Resetting application settings removes it along
with the other settings. An unsuccessful write restores the previous selection
and uses the existing settings-error reporting path.

The existing localizations are Arabic, Catalan, Dutch, English, French, Canadian
French, German, Italian, Japanese, Portuguese, Russian, Simplified Chinese,
Spanish, Traditional Chinese and Turkish. Canadian French keeps its regional
InfoPlist overrides and inherits the rest of the French interface.

## Startup and storage safety

`OpenEmuLaunch` reads only the selected language before AppKit loads localized
resources. The preview validates the existing data-folder marker and bookmarked
identity; it does not create a folder, migrate data, mount a disk or write a
settings/lock file. Missing or invalid data uses the system language and leaves
the normal folder-recovery flow in charge. An explicit `--data-folder` never
falls back to the user's real profile. Tests and the deletion worker skip the
preview.

The override is process-local, in the volatile argument domain. There is no
persistent `AppleLanguages` write. An explicit `-AppleLanguages` launch option
has priority, which keeps isolated language tests reproducible.

Emulation helpers receive that same effective language in their launch arguments,
not a newly saved choice awaiting restart. Their built-in error messages resolve
the host app's translation tables, including the French fallback for Canadian
French; they do not write preferences or read another app's resources.

## Verification

```sh
python3 Scripts/Tests/test-localizations.py
python3 Scripts/Tests/test-system-document-localizations.py
python3 Scripts/check-localizations.py
bash Scripts/Tests/test-interface-language.sh
bash Scripts/Tests/test-helper-localization.sh
./Scripts/verify.sh --arch "$(uname -m)" --release --ad-hoc-sign
```

The resource check validates keys, nonempty values, duplicates and format
arguments across all included translation tables. The isolated launch fixture
tests the production entry point with every included language and with explicit
launch overrides, without starting OpenEmu or reading the real profile. It also
tests settings persistence, unavailable profiles, identity mismatch, moved
folders and reset behavior.

Check the built application's Library preferences, menus, first-run assistant,
core preferences, errors and long translated labels. Language tests do not
establish that every screen fits. See [native file-panel verification](data-folder.md)
and [the localization audit's limits](../Scripts/Tests/LOCALIZATION-AUDIT.md).
Game names, downloaded achievement/cheat descriptions, shader-defined parameter
names and other external content are not translation tables owned by OpenEmu.
System Settings and other macOS-owned windows still follow macOS's settings.

The document-type generator preserves explicit source translations such as
the Chinese name for arcade games. Generated regional system names are still
refreshed on incremental builds instead of keeping stale generated output.
