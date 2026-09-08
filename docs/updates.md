# Application and core updates

## Release gate

This change prepares a Reborn-owned update channel. Do not ship the configured
URLs until the corresponding archives are public, their hashes/signatures have
been verified, and both complete catalogs are published. A successful CI run or
a reachable XML file alone is not a working update service.

The application remains version **1.0.0**, now internal build **23**. Internal
build numbers increase independently of the public application version.

## Trust and processor selection

The signed host application contains the trusted public Ed25519 key and two
`OECoreUpdateCatalogs` entries. A running `x86_64` process requests the Intel
catalog; an `arm64` process requests the Apple Silicon catalog. Rosetta processes
therefore use Intel cores. Each catalog contains all 28 native core identifiers.

Core update feeds live under `Updates/cores/<architecture>/`. The host does not
take signing keys or update-feed overrides from downloaded catalogs or mutable
installed plugin plists. Old plugin `SUFeedURL` values are preserved for legacy
compatibility, but cannot redirect this host's updater. The older `Appcasts/`
directory remains a historical Silicon mirror.

Before extracting an update, the host verifies its Ed25519 signature and exact
byte length using the key embedded in the application. Missing or invalid
authentication fails closed. HTTPS, declared CPU and minimum macOS version,
bundle identifier/version, nested binary architectures, safe archive paths and
installation rollback are separate checks. Compatibility ad-hoc codesigning
happens only after successful archive authentication; it is not proof of origin.

Feeds are sorted by version before selecting an update. An older signed core
cannot be installed as a newer version: the extracted bundle version must match
the advertised version, which must be newer than the installed version.

## Installing and restarting

An update is staged in the selected OpenEmu data folder. After validation the
new bundle is placed under `Cores`, with a backup when replacing an existing
external core. Updating a core bundled inside the app does not modify the app.

Existing core controllers stay unchanged while the app is running. Preferences
shows **Restart Required** after installation; the new core is selected on next
launch. Rechecking cannot reinstall the same pending update. Installation
failure retains/restores the previous usable version. A user-requested rollback
also takes effect after restart.

## Signing without a paid Apple account

The maintainer's macOS code-signing certificate and Sparkle archive-signing key
are different keys. The former preserves the local app's identity; the latter
authenticates published updates without requiring a paid Developer ID account.
Neither private key belongs in git, build artifacts, GitHub Actions or Releases.

The Sparkle key is held in the maintainer's login Keychain under account
`org.openemu.Reborn.updates`. The public key in `SUPublicEDKey` is intentionally
public. Losing the private key can require another manual installation; keep the
Keychain safe. This workflow does not export keys or change system trust/TCC.

Earlier Reborn test builds embedded the Silicon publisher's public key. They
cannot verify archives signed by Reborn. Install the first corrected Reborn app
manually once; do not bypass signature checks or pretend the old key migrated.
Subsequent releases signed with the Reborn key use normal Sparkle updates.

Self-signed packages are not notarized. Other Macs may require the user's normal
macOS approval to open them. No recipient needs the private key, and system-wide
security settings must not be disabled. See [publication commands](update-publication.md).

## Reproducible core publication

The full Build Check workflow preserves one core archive per CPU, one tested
Release host per CPU, and a separately built universal host without emulator
cores. Each binary archive has `BUILD-INFO.json`: source revision, bundle ID,
version, architecture, SHA-256, size and workflow run. MAME additionally records
its pinned external source and patch digest. CI holds no release signing key.

The `reborn-mame-source` artifact separately preserves all tracked files from
MAME's pinned upstream commit and the exact Reborn patch. Publish its source
archive and provenance alongside the core binaries, plus the Reborn source
snapshot for the same CI commit (wrapper, SDK, projects and build scripts).
The core preparer does not automatically copy this separate source artifact.
Do not substitute source from a later branch head for the commit actually built.

Prepare a release only from a complete matching 28-by-2 artifact set. Validate
all input archives before signing any of them, generate the catalogs, publish
the exact verified archives, then advertise them. Do not replace a published
archive with different bytes under the same version/URL.

Core versions describe the source snapshot actually built, not the date of
packaging. Reborn's release process does not automatically import new upstream
source changes or promise that every upstream version is already ported to Intel.

## Isolated regression tests

After building the host, pass its framework directory explicitly:

```bash
frameworks="$PWD/tmp/agent/data-folder-derived/Build/Products/Release"
bash Scripts/Tests/test-core-update-security.sh "$frameworks"
bash Scripts/Tests/test-core-update-installation.sh "$frameworks"
bash Scripts/Tests/test-core-update-checks.sh "$frameworks"
python3 Scripts/Tests/test-package-ci-artifact.py
python3 Scripts/Tests/test-prepare-core-update-release.py
python3 Scripts/Tests/test-app-update-publication.py
python3 Scripts/Tests/test-self-signed-update-packaging.py
python3 Scripts/Tests/test-update-signature.py
```

These fixtures do not touch the user's game folder or signing keys. They do not
replace the final checks of real published artifacts and update installation.
