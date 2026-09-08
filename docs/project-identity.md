# OpenEmu Reborn 1.0.0: identity and scope

OpenEmu Reborn is an independent, fan-maintained revival based on
[OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon), descended
from the original [OpenEmu](https://github.com/OpenEmu/OpenEmu) and the
[ARM64 port](https://github.com/bazley82/OpenEmuARM64). It is not an official
release or endorsement from those projects. The current repository is
[communism420/OpenEmu-Reborn](https://github.com/communism420/OpenEmu-Reborn).

`1.0.0` starts the Reborn **application** version line. It does not mean that
the emulator cores were rewritten, rebuilt, updated, or renumbered. Their own
versions and licenses remain independent. Existing cores are reused for local
host-only changes unless a core rebuild is explicitly requested.

The source targets Apple Silicon (`arm64`) and 64-bit Intel (`x86_64`) Macs
running macOS 11 or later. This is not support for literally every Mac or every
game. Recent local fixes have not been runtime-tested on Apple Silicon; do not
infer ARM gameplay verification from an Intel build or a source-level change.

No Reborn release has been published yet, and repository Issues are currently
disabled. Use a documentation or draft PR for non-confidential proposed changes
and test reports. Use Releases, Issues, Discussions, or private vulnerability
reporting only when the relevant repository feature is available. Do not send
Reborn reports to upstream trackers as a substitute.

## Compatibility names that deliberately stay unchanged

The local runnable package is still `OpenEmu-Intel-test/OpenEmu.app`. Xcode
scheme names, `org.openemu` identifiers, storage keys, and existing data-folder
markers remain technical compatibility details, not the displayed product name.
The local signing certificate label `OpenEmu-Intel Local Signing` and its
Keychain identity are retained; rebranding must not create a replacement key
or change trust or privacy permissions. See [local signing](local-signing.md).

Upstream core-feed URLs, credits, copyrights, and historical research records
retain their original identities. Old issue numbers and RetroAchievements
verification records describe the upstream project, not new Reborn approval or
test results. Clearly label upstream material when linking it as background.
