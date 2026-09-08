# Publishing signed Reborn app updates

Reborn does not need a paid Apple Developer account to authenticate its update
archives. It does need its own **Sparkle Ed25519 key**. This is separate from
the local self-signed certificate used to keep the app's macOS identity stable.

- The certificate signs `OpenEmu.app`. Its private key stays in the maintainer's
  Keychain; users do not need that private key or the certificate installed as
  a trusted root.
- The Sparkle private key signs downloadable archives. The matching **public**
  key is embedded in `SUPublicEDKey`. The release scripts use the Keychain
  account `org.openemu.Reborn.updates` by default; set
  `OPENEMU_SPARKLE_ACCOUNT` only to deliberately select another account.
- A self-signed release is **not Apple-notarized**. Initial installation on
  another Mac may require the normal macOS “Open Anyway” confirmation. Do not
  disable Gatekeeper or ask users to trust a new root certificate.

See [Sparkle's signing documentation](https://sparkle-project.org/documentation/).
Scripts never create keys, export private keys or change Keychain trust.

## One-time transition from earlier test builds

Earlier test builds through build **22** contain OpenEmu-Silicon's public
Sparkle key, not Reborn's. They cannot authenticate archives signed with the
new Reborn key. Install the corrected Reborn build **23** (version `1.0.0`)
manually once. Later Reborn updates use the same Reborn key. Do not weaken
signature checking to make the old key accept an unrelated signature.

## Prepare an archive without rebuilding anything

Use a previously verified, certificate-signed app containing all 28 cores.
For the shared `appcast.xml`, prefer a **universal app**: every executable,
framework and bundled core must contain both `arm64` and `x86_64`.
The usual local `OpenEmu-Intel-test/OpenEmu.app` is Intel-only; do not relabel
that app as universal. Producing compatible binaries is a separate build step.

```bash
OPENEMU_SIGN_UPDATE="/absolute/path/to/Sparkle/bin/sign_update" \
bash Scripts/release.sh --self-signed 1.0.0 /absolute/path/to/notes.md \
  --app /absolute/path/to/verified-universal/OpenEmu.app \
  --arch universal \
  --signing-identity YOUR_EXACT_40_HEX_CERTIFICATE_SHA1 \
  --output Releases/update-1.0.0
```

Choose a new output directory. The command leaves the original app and cores
unchanged, creates an app-only ZIP, signs the ZIP with Sparkle, verifies that
signature against the app's public key, and saves `prepared-update-*.json`.
It does not build, install, re-sign cores, modify the appcast or write to GitHub.
There is no ad-hoc/unsigned fallback and no Developer ID/notarization preflight
in this mode. The archive is not ready until the command succeeds and the
prepared JSON exists.

Before saving metadata, the preparer independently opens the signed archive
in a private temporary location and checks the **app inside that archive**:
its key, version, build counter, feed URL, code signature and every binary's
processor slices. The advertisement step repeats these checks. A separate
newer `--app` or an edited JSON cannot disguise an old/incompatible ZIP as a
new update. Nothing from the archive is executed or registered as an installed
app. DMGs are mounted read-only and detached afterward.

The build counter must increase, but need not increase by exactly one. For
example, build `23` can follow public build `21` when `22` was a private test.
The appcast uses the app's actual `CFBundleVersion`; `1.0.0` is the separate
displayed version.

## Publish first, advertise second

1. Test the exact ZIP and confirm its source revision and behavior on both
   processor types. Use a release tag pointing to those reviewed sources.
2. Create a GitHub draft release and upload **that exact ZIP**. Include source
   and license information and clearly state whether the build is notarized.
   Review the draft, then explicitly publish it as a stable release. The
   preparer never publishes automatically.
3. On a new `codex/` release branch based on `main`, run:

   ```bash
   bash Scripts/release.sh --advertise \
     Releases/update-1.0.0/prepared-update-v1.0.0-universal.json
   ```

   This checks the archive signature again and queries GitHub **without
   authentication**, as an ordinary user. A draft/private/missing release,
   prerelease, wrong filename, unfinished upload, different size or different
   SHA-256 stops the operation before `appcast.xml` is changed. GitHub must
   provide the uploaded asset's `sha256:` digest; absence fails safely.
4. Commit the appcast change, push the branch and immediately open a PR against
   `main`. Include the archive test results and the exact publication commands
   in the PR. Review/merge the PR to make the update visible. Never replace an
   asset already advertised in a feed; publish a new build instead.

Keep the signed ZIP and prepared JSON together until the appcast PR is done.
The JSON contains public metadata and local paths, **not private keys**, but
neither it nor the binary should be committed to the source repository.

## Architecture safety

Sparkle's `hardwareRequirements` recognizes `arm64`; an `x86_64` value does
**not** exclude Apple Silicon. For that reason the preparer refuses an
Intel-only archive in the shared feed. A thin Intel release requires a
separate `appcast-x86_64.xml` and a prebuilt app whose `SUFeedURL` already points
to that exact feed. Do not switch one architecture to such a feed without a
complete, reviewed migration. An ARM-only entry is explicitly marked `arm64`.

## Optional paid/notarized mode

`bash Scripts/release.sh VERSION notes.md` retains the Developer ID archive
and notarization pipeline, with explicit `OPENEMU_DEVELOPMENT_TEAM`,
`OPENEMU_SIGNING_IDENTITY` and `OPENEMU_NOTARY_PROFILE`. It now also prepares
metadata first and uses the same publish-before-advertise check. It does not
build core schemes. It is not the self-signed maintainer workflow.

## Combining matching CI processor builds

`Scripts/merge-ci-bundle.py` can combine a verified ARM/Intel pair preserved by
`package-ci-artifact.py`. Both `BUILD-INFO.json` files must identify the same
source revision, repository, toolchain, bundle and version; each input ZIP's
hash and size must match. For example:

```bash
python3 Scripts/merge-ci-bundle.py \
  --arm64-artifact /absolute/path/to/reborn-core-Nestopia-arm64 \
  --x86_64-artifact /absolute/path/to/reborn-core-Nestopia-x86_64 \
  --source-sha EXACT_40_HEX_CI_SOURCE_COMMIT \
  --output /absolute/path/to/new-universal-Nestopia
```

The helper copies neither input over the other. It extracts the intended CPU
slice from each binary and combines them with `lipo`. Ordinary resources must
match. Only named architecture-specific Swift module files can be combined by
union; differing `Info.plist` values are accepted only for a small list of
non-runtime build-machine fields. Any other difference fails and calls for a
proper universal build. This especially matters for host-generated assets,
storyboards and Metal libraries: do not choose one arbitrarily. A host-only
universal build using the `OpenEmu` scheme does not rebuild core schemes.

The helper produces a new **unsigned staging bundle**, not a published archive
or an installation. It never invokes a compiler or signs anything. An app's
assembled core bundles belong at `OpenEmu.app/Contents/PlugIns/Cores/`; sign
the completed app inside-out and verify all binaries for both architectures
before passing it to the self-signed preparer. Existing input artifacts and the
normal local app are never replaced by the merge helper.

## Sign a private universal staging app

Use the CI artifact `reborn-host-universal` for the host. Its
`OpenEmu-universal.app.zip` and `BUILD-INFO.json` come from a real universal
host build, not from choosing one processor's generated resources. Verify its
source revision, archive hash and CI result before extraction. Merge each of
the 28 core pairs from **that same revision** with the helper above. Keep the
merge reports, and collect only the 28 resulting `.oecoreplugin` directories
in one new, private input folder.

The next helper copies these verified inputs to a **new absolute directory**,
signs only those copies with the explicitly selected existing certificate,
and checks every binary for both processors and the completed code signatures:

```bash
python3 Scripts/stage-universal-app.py \
  --host /absolute/private/verified-host/OpenEmu.app \
  --cores /absolute/private/verified-universal-cores \
  --source-sha EXACT_40_HEX_CI_SOURCE_COMMIT \
  --signing-identity EXACT_40_HEX_CERTIFICATE_SHA1 \
  --output /absolute/private/new-universal-stage
```

The output's parent must already exist, be owned by you and not be writable
by other users. Inputs must be absolute paths without symlinked parent
directories. The host must not contain old core bundles. The helper refuses
an existing output or any output inside `OpenEmu-Intel-test`. It neither
builds nor installs anything, registers an app, accesses the network, creates
keys or changes trust/input-monitoring permission. Signing may trigger the
normal Keychain confirmation for the existing private key.

`STAGING-INFO.json` records fingerprints and the caller-provided source SHA;
it does **not** independently prove CI provenance or declare a release ready.
Review/test the result before passing its `OpenEmu.app` to
`release.sh --self-signed`. Never reuse a staging folder for the next attempt.

For the final local replacement, explicitly pass the newly signed core folder
to `replace-local-intel-build.sh --cores`; omitting it intentionally reuses the
previous local cores. That publisher still requires an **unbundled** verified
host at its documented fixed Release path, not this completed app. It replaces
the entire canonical package, so old bundled core files are not merged back.
It preserves universal binaries but checks Intel only: repeat the architecture
check with both `--arch arm64` and `--arch x86_64` on the finished canonical app.
See [local-signing.md](local-signing.md) before changing the local installation.

## Offline regression checks

```bash
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/Tests/test-release-branding.py
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/Tests/test-app-update-publication.py
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/Tests/test-self-signed-update-packaging.py
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/Tests/test-update-signature.py
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/Tests/test-merge-ci-bundle.py
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/Tests/test-stage-universal-app.py
bash -n Scripts/release.sh Scripts/prepare-self-signed-update.sh
```

The packaging tests use synthetic app folders and mocked signing commands.
The signature tests use the real public-key verifier and public RFC 8032 test
vectors; they do not sign anything or read/create private keys. These tests
cannot substitute for a real packaged-app update test on both architectures.
