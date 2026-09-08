# Choosing an OpenEmu data folder

On its first ordinary launch, OpenEmu asks you to choose a dedicated folder for its data. Choose an empty folder, create one in the picker, or select an existing OpenEmu data folder. Do not select your whole Documents or Downloads folder. Canceling the picker quits OpenEmu.

OpenEmu does not move or delete an old library automatically. To keep an old installation's data, select the folder containing `Game Library/Library.storedata`, usually `~/Library/Application Support/OpenEmu`. Select its parent data folder, not `Game Library` itself. An unrelated nonempty folder is rejected.

## What goes in the folder

The selected folder supplies the normal locations for these files. Some subfolders appear only after the corresponding feature is used.

| Location inside the data folder | Contents |
| --- | --- |
| `Settings.plist` | OpenEmu settings, including appearance, volume, default cores and feature preferences |
| `Settings.plist.lock` | Prevents two app processes from writing the same settings file at once |
| `.openemu-data-folder.plist` | Identifies this particular data folder for recovery |
| `Game Library/` | Library database, artwork and games copied into the library |
| `BIOS/`, `Save States/`, `Screenshots/` | Imported BIOS files, save states and screenshots |
| `Cores/`, `Systems/`, `Bindings/`, `Shaders/` | Installed plugins, controller bindings and user shaders |
| Core-specific folders, such as `Mednafen/` | Battery saves, memory cards and other files owned by a core |
| `Caches/`, `Temporary/`, `Logs/` | App-managed caches, working files and logs; the core inventory is `Logs/core-inventory.txt` |
| `.oe_credentials` | The existing encrypted account-credential store |

Settings changes are saved in `Settings.plist`, not as ordinary OpenEmu preferences in macOS's defaults database. The app is the only settings writer; game helpers read the same file. A failed settings write reports an error and keeps the previous saved value. Do not edit settings or remove the lock file while OpenEmu is running. The lock file can remain after quitting; its presence alone does not mean the app is still running.

When an existing legacy data folder is explicitly selected and has no `Settings.plist`, OpenEmu makes a one-time copy of its old app settings. It reads the old Release settings even when opened in Debug; any explicit settings from the active app variant take precedence. macOS/AppKit settings, Sparkle update settings and data-folder locator keys are excluded. An empty new folder starts with fresh app settings. This is not a whole-system settings migration or cleanup.

The credential file is tied to the Mac's hardware identity. Moving the data folder to another Mac may require signing in again; copying this file is not a promise that account access will transfer.

## If the folder moves or its disk is disconnected

OpenEmu remembers a macOS bookmark, the folder's identifier and its last known path under the `org.openemu.OpenEmu` preferences domain. These small locator values are named `OEDataFolderBookmark`, `OEDataFolderIdentifier` and `OEDataFolderPath`. They do not contain a copy of the game library.

Debug and Release builds share this canonical folder locator, even though the Debug app's bundle identifier is `org.openemu.OpenEmu.debug`. An ordinary Debug launch therefore uses the same selected data folder, not an automatically isolated library. Use `--data-folder` for a separate test folder. The settings-writer lock prevents two builds from writing the same folder's settings concurrently.

The hidden `.openemu-data-folder.plist` marker must stay with the folder. If the bookmark follows a rename or move, OpenEmu refreshes the remembered location. Known library, save-state and screenshot settings that pointed inside the old root are adjusted to the new root. Explicitly external paths are left unchanged.

If the folder cannot be opened, OpenEmu offers **Try Again**, **Locate Folder…** or **Quit OpenEmu**. Reconnect the disk or locate the same folder. Recovery requires the same identifier: choosing an empty folder or another library cannot silently replace the original library. A missing or invalid marker is an error, not permission to create a replacement library. Keep the marker in backups and do not edit it by hand.

Quit OpenEmu and finish any game session before moving or backing up the folder. If a disk disappears during a session, settings and managed-directory checks can fail; do not assume unsaved progress was written. Reconnect the disk and restart OpenEmu before continuing. A second app process cannot open the same settings file for writing.

## Explicit external locations still mean external locations

The data folder changes defaults, not every file the user has ever selected. Existing custom library, save-state and screenshot locations are preserved. Games imported with copying disabled remain at their original paths. Exports, folder backups, cloud-sync destinations and external RetroArch core sources also retain their separately selected locations. They are not silently copied or redirected.

For a self-contained library, use the default locations and keep copying imported games into the library enabled. Check any older custom locations before moving to another disk. Existing user-authored M3U playlists remain read-only inputs. Mednafen's automatically generated multi-disc playlists are stored under `Mednafen/Playlists/<source-folder hash>/` with absolute CUE/CCD entries; their source discs must still be available. Required SBI files are looked up beside those discs.

## Which core is actually used?

OpenEmu searches the selected folder's `Cores/` before the app's bundled cores. An installed bundle with the same plugin name can take precedence over its bundled counterpart. Building a core does not install it, and selecting an existing data folder does not replace its older cores.

A new empty data folder does not import installed cores from the old `~/Library/Application Support/OpenEmu/Cores/` directory. Cores bundled with the particular app build remain available; additional cores must be installed into the selected folder. The usual architecture checks and update-channel rules still apply. This feature does not change a core's update feed or automatically make every core newer.

“Freshly built” means compiled from the source revision used for that build. It does not mean updated to the latest upstream emulator release. For a test result, use the install/preflight commands below. `Logs/core-inventory.txt` lists discovered plugin names, identifiers and systems, not executable paths or proof that a core ran a game. A successful startup check is not a game-compatibility test.

## Files and settings macOS still owns

This is a data-location feature, not a sandbox or a promise of zero traces outside the folder. macOS still manages the bookmark locator preferences, privacy permissions such as Input Monitoring, notifications, app registration, quarantine information, unified logs, crash reports and system temporary/download staging. AppKit and Sparkle also retain their own framework-managed preferences and files. Existing legacy Keychain items may be consulted by the credential store's existing migration code.

The app's managed HTTP sessions avoid a second persistent HTTP/cookie store, but that does not relocate every cache or temporary file created by macOS or a third-party framework. The feature does not change `HOME`, replace the system defaults implementation, or redirect user folders with symbolic links.

## Isolated verification

Run these commands from the repository root, with Xcode installed and the local credential-template files prepared as described in [AGENTS.md](../AGENTS.md). These standalone tests use private temporary fixtures; they do not launch OpenEmu, install real cores or change the selected library:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./Scripts/Tests/test-storage-sdk.sh
./Scripts/Tests/test-data-folder-setup.sh
python3 Scripts/Tests/test-core-data-folder.py
./Mednafen/Tests/test-generated-playlists.sh
```

They cover storage and settings error cases, folder identity/recovery helpers, Cocoa settings bindings, core install/preflight path selection and Mednafen playlist/SBI paths. They do not exercise the interactive first-launch picker or emulate a game. Run permission tests as a normal user, not root.

### Build and smoke-launch an isolated app

Quit any running OpenEmu first. The following creates separate existing directories for build products and test data. `--data-folder` requires an absolute path to an existing empty or identified data folder. It skips the data-folder picker for that launch and does not replace the folder remembered for ordinary launches. Unlike ordinary legacy-folder adoption, it does not import old macOS app settings. Invalid selection exits with an error instead of falling back to the real library. It does not bypass other first-run dialogs or macOS permission prompts.

```bash
data_folder_build="$(mktemp -d /private/tmp/openemu-data-folder-build.XXXXXX)"
data_folder_smoke="$(mktemp -d /private/tmp/openemu-data-folder-smoke.XXXXXX)"
./Scripts/verify.sh --arch "$(uname -m)" --release --ad-hoc-sign \
  --derived-data "$data_folder_build" \
  --data-folder "$data_folder_smoke" --launch
```

`--ad-hoc-sign` permits local verification without an Apple developer account; it does not notarize the app. `--derived-data` pins artifact selection to the supplied build directory. `--launch` checks startup for five seconds and leaves the app open for manual testing; it skips launch if OpenEmu is already running. Verify that the library window opens, not merely that a process survived while displaying an error. The directories above are retained for inspection; quit OpenEmu before moving those exact test directories to Trash.

The equivalent direct launch, after building, is:

```bash
open "$data_folder_build/Build/Products/Release/OpenEmu.app" \
  --args --data-folder "$data_folder_smoke"
```

Use `--arch x86_64` for an Intel build or `--arch arm64` for Apple Silicon. App unit tests can be run separately with `./Scripts/verify.sh --arch "$(uname -m)" --test`; app-hosted XCTest creates its own temporary data folder in both Debug and Release. Neither unit tests nor an app build prove that all core plugins were rebuilt.

For an already built app, the dedicated smoke harness checks first launch, relaunch, moving its private data folder and rejection of a concurrent settings writer:

```bash
./Scripts/Tests/test-data-folder-app.sh "$data_folder_build/Build/Products/Release/OpenEmu.app"
```

It accepts the Release and Debug bundle identifiers above, refuses to start if OpenEmu is already running, uses its own temporary data folder, checks the selected database is open, and terminates only app processes it started. Each startup phase has a 30-second deadline. Logs and fixtures are retained at the printed path even on failure. It compares locator keys in the canonical domain and, when different, the active Debug domain, plus the legacy folder's top-level metadata, without rewriting or printing their contents. This is not a full audit of every legacy file or macOS-managed setting. First-run permission dialogs can prevent readiness and need manual diagnosis. This does not test gameplay or UI rendering.

### Build, install and verify a core in the same test folder

First finish the isolated launch above and quit OpenEmu. The folder must now have a valid `.openemu-data-folder.plist`; core install/preflight scripts will not initialize an arbitrary empty folder. For example, Mednafen requires a Release build:

```bash
./Scripts/verify.sh --arch "$(uname -m)" --core Mednafen --release --ad-hoc-sign \
  --derived-data "$data_folder_build" --data-folder "$data_folder_smoke"
./Scripts/verify-core-installed.sh Mednafen --release \
  --derived-data "$data_folder_build" --data-folder "$data_folder_smoke"
```

`verify.sh --core` builds the core scheme, installs a successful native-architecture result and runs the installed-core preflight. The main app scheme alone does not rebuild all cores. For an already built core, the explicit install command is:

```bash
./Scripts/install-core.sh Mednafen --release \
  --derived-data "$data_folder_build" --data-folder "$data_folder_smoke"
```

Run the preflight again after any rebuild and require `OK` before reporting a game test. Never merge bundle directories using `cp -Rf`. Relaunch the app with the same `--data-folder`, use your own legally obtained test game and any required BIOS/SBI files, and check that the intended core appears in the inventory. Its installed path and match with the build are checked by the preflight, not the inventory. `verify.sh --core --launch` does not run an app smoke launch; launch the app separately as shown above.

Without `--data-folder`, the install and preflight scripts use OpenEmu's remembered path and check its marker. They use the old Application Support location only when no data-folder locator keys exist at all, for compatibility with older app builds. A remembered but unavailable or mismatched folder is an error. The scripts do not resolve a moved bookmark themselves: open OpenEmu to recover its location, or pass the identified folder explicitly. Without `--derived-data`, the scripts search their usual build locations, so explicit paths are preferable for isolated tests.

### Manual first-launch and recovery checks

Use a disposable macOS test account for the ordinary first-launch picker and bookmark tests, rather than deleting the real account's locator preferences. Check that cancel quits, an unrelated nonempty folder is rejected, settings survive relaunch, a renamed folder is recovered, a missing disk does not produce an empty replacement library, and a different folder's marker is rejected during recovery. Inspect the selected folder for library, BIOS, saves, settings, caches and the loaded-core inventory. Test at least one actual game separately; none of the standalone fixtures establish emulator compatibility.
