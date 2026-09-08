# Local, persistent signing for OpenEmu Reborn

Rebranding retains the existing **OpenEmu-Intel Local Signing** certificate
name, private key, Keychain identifiers and `OpenEmu-Intel-test` package path.
Do not create a new identity merely because the display name changed.
See [Project identity](project-identity.md).

A self-signed code-signing certificate is a free way to give successive local
OpenEmu builds the same signer. It is **not** Developer ID, notarization, or a
promise that Gatekeeper accepts a download. It also does not grant Input
Monitoring: macOS and the user still decide that separately.

## Keep the private key private

Create an identity once, then reuse it. The maintainer's private key belongs in
the maintainer's login Keychain, never in this repository, a build artifact, or
the app. Other users receive only the public certificate inside the signature;
they do not need the private key or their own signing identity to use the app.
The public `.cer` file and the certificate embedded in a signed app are not
secrets: they identify the signer and let others verify signatures, but cannot
be used to sign another build without the private key.

`Scripts/Signing/CreateSigningIdentity.swift` is a maintainer tool, not an app
startup feature. It generates a signing-only RSA key through Apple's Security
framework and builds the public certificate around that key. It does not export
the private key, change certificate trust, or change macOS privacy permissions.
Its creation command is explicit; ordinary packaging never creates a new key.

With Xcode installed, prepare and check the tool before creating the identity:

```bash
signing_work=$(mktemp -d /private/tmp/openemu-local-signing.XXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc -swift-version 6 \
  -module-cache-path "$signing_work/ModuleCache" \
  Scripts/Signing/CreateSigningIdentity.swift \
  -o "$signing_work/CreateSigningIdentity"
"$signing_work/CreateSigningIdentity" --self-test
"$signing_work/CreateSigningIdentity" --check
# This next command explicitly creates a private key in the login Keychain,
# or reuses the existing identity. It writes only a PUBLIC certificate file.
"$signing_work/CreateSigningIdentity" --create \
  --certificate-output "$signing_work/OpenEmu-Intel.cer"
```

The self-test uses a temporary key in memory and does not save a key to the
Keychain. Creation requests a nonextractable, signing-only key and does not give
`codesign` (or every other app) silent access. If macOS asks to use the key,
approve the intended operation in its own dialog; do not send a login password
through chat or put it in command-line arguments.

A new self-signed certificate may still be untrusted for code signing. This
tool deliberately does not change that trust. If macOS rejects signing for that
reason, stop and arrange explicit user approval for this certificate's
**code-signing policy only, in the user domain**. Do not set unrestricted
"Always Trust", add SSL/TLS trust, change the system Keychain, or weaken
Gatekeeper. Trust in a certificate, permission to use its private key, and
Input Monitoring are three separate decisions.

Only after the signing Mac's user has explicitly approved that limited trust
change, verify that the public certificate is the intended local identity and
run the following as that user, without `sudo`. Replace the certificate path
with the public `.cer` file from the creation step:

```bash
/usr/bin/security add-trusted-cert \
  -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "/absolute/path/to/OpenEmu-Intel.cer"
```

For this self-signed certificate, `trustRoot` supplies the trust result while
`-p codeSign` limits it to code signing. Omitting `-d` selects the current user's
trust domain; `-k` selects that user's login Keychain for the public certificate.
Do not remove the policy restriction or add an admin-domain, SSL/TLS, or
allowed-error option. macOS may ask the user to authenticate in its own dialog.
This command changes certificate trust; it does not grant silent access to the
private key or change Input Monitoring permissions.

That trust setting remains on the signing Mac: distributing the signed app
does not distribute the setting or the private key. Importing or trusting the
certificate is not a routine installation step for recipients. A self-signed
app may still be blocked by Gatekeeper on another Mac, and each Mac's user must
handle its own privacy permission requests. Neither this command nor the
signature guarantees Gatekeeper acceptance or TCC permission persistence.

The certificate is valid for ten years. A lost key, a replacement certificate,
or switching from an old ad-hoc signature can require granting permissions
again. The tool does not export the private key for backup or CI: losing access
to the stored key requires a new identity. Do not delete the identity when
resetting OpenEmu's game data/settings.

## Packaging

Local user-facing builds always live in **`OpenEmu-Intel-test` at the repository
root**. Do not create another dated `Releases/Intel-*` folder or keep extra
launchable OpenEmu copies. macOS can choose an old copy when several apps share
the same bundle identifier, including when restarting after a privacy change.

First build and verify only the main `OpenEmu` scheme, keeping its intermediate
cache in the known location. Emulator cores are not rebuilt by these commands:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash Scripts/verify.sh --arch x86_64 --release --ad-hoc-sign \
  --derived-data "$PWD/tmp/agent/data-folder-derived"

# Quit OpenEmu before replacing its app bundle.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash Scripts/replace-local-intel-build.sh \
  --signing-identity "CERTIFICATE_SHA1_FINGERPRINT"
```

The local replacement script reuses the 28 cores from the current canonical
app. Only for initial setup, supply `--cores "/absolute/path/to/prebuilt/cores"`.
It first signs and verifies a private staging copy, then replaces the canonical
package. On success it deletes the previous package and the consumed
`tmp/agent/data-folder-derived/Build/Products/Release/OpenEmu.app`; intermediate
object caches and other build products remain available. No app or core build
is performed by the replacement script itself.

The package's `.openemu-local-build.json` records ownership. Do not remove it,
and do not store games, settings or personal files inside `OpenEmu-Intel-test`.
Schema 2 records the stable volume UUID and repository inode so a reboot does
not invalidate ownership; legacy schema 1 markers are refused without automatic migration.
Unknown files, data-folder markers, unsafe paths or a running OpenEmu cause the
replacement to stop. A failed publication can retain a clearly reported
recovery directory for inspection; do not delete it blindly. Registration is
updated for exact app paths, without resetting LaunchServices or macOS privacy
permissions globally.

Use the exact certificate fingerprint, not a potentially ambiguous certificate
name. This fingerprint is public, not a password. The packaging script must
fail if that identity cannot be used; it must not silently substitute an ad-hoc
signature. Keychain access dialogs are handled by the user, not by storing a
login password in a script or granting every application access to the key.

Only the outer app is signed after copying the existing cores. The old ad-hoc
designated requirement is not preserved: it identifies one particular binary,
not the new persistent signer. Nested cores are compared byte for byte with the
input bundles. The local publisher consumes only the specifically documented
host input after the canonical app passes its checks; it never deletes an
arbitrary `--app` path or the standalone core cache.

The lower-level `package-intel-test-build.sh` remains available for CI and
separate distribution archives. It writes a new output directory without
changing its inputs; it is not the normal local installation workflow. For
deliberately ad-hoc CI packages, explicitly pass `--ad-hoc-sign`. Those packages
do not use the maintainer's identity and must not be presented as preserving it.

## What to verify

1. The finished app passes `codesign --verify --deep --strict` and every bundled
   executable contains `x86_64` for the Intel package.
2. The leaf certificate fingerprint matches the selected identity. The
   designated requirement refers to the stable signer, not an ad-hoc `cdhash`.
3. Two different app versions signed by that identity satisfy each other's
   designated requirement. Changing the contents must change the signed code
   hash but not the identity requirement.
4. Check Input Monitoring from a normal Finder/LaunchServices launch. A direct
   shell/debugger launch can have different TCC attribution and is not proof
   that the Finder-launched app has access.
5. After the user grants access to the newly signed app, verify another normal
   launch and an updated version. A code-signature check alone is not a TCC
   permission-persistence test.

The “Check Again” button reads the current permission without dismissing and
recreating the alert while access remains denied. It cannot repair a macOS grant
that belongs to a different signature. Do not hide a real denial by treating a
saved OpenEmu preference as permission.

## Apple references

- [Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
- [Code signing and subsystem-specific trust](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- [Inside Code Signing: Certificates](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)
