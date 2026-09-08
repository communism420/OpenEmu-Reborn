# Privacy Policy

**App:** OpenEmu Reborn
**Last updated:** September 6, 2026
**Contact:** [Project repository](https://github.com/communism420/OpenEmu-Reborn); use a draft PR for non-confidential questions while Issues are disabled.

---

## What this app does

OpenEmu Reborn is a macOS game emulator. Most gameplay and library features run locally on your computer.

This independent fan-maintained revival inherits integrations from OpenEmu-Silicon. The app version `1.0.0` does not rename external service clients, transfer service accounts or establish third-party approval. See [Project identity and compatibility](project-identity.md).

The app can also access the network for app/core update checks and downloads, game metadata and cover art, and the following optional integrations. Requests expose normal connection information, such as your IP address, to the relevant service. The sections below describe these integrations, not an exhaustive network endpoint inventory:

- **RetroAchievements** — optional achievements, leaderboards, and Rich Presence.
- **Google Drive Save Sync** — optional save-state and battery-save backup/sync.
- **Sentry crash reporting** — optional crash and hang diagnostics.

OpenEmu Reborn does not operate its own account server, telemetry backend, or analytics service.

---

## RetroAchievements (optional)

RetroAchievements support lets you earn achievements, submit leaderboard scores, and show Rich Presence for supported games. It is off unless you sign in from **Preferences → Achievements**.

### What is sent to RetroAchievements

When RetroAchievements is enabled, OpenEmu Reborn uses the rcheevos client library to communicate with RetroAchievements. Depending on the game and session, this may send:

- Your RetroAchievements login/token request.
- Game hashes and game-identification requests.
- Achievement unlock submissions.
- Leaderboard start/update/submit data.
- Rich Presence updates.
- Client and system information such as the client User-Agent, macOS version, and rcheevos version. Existing integrations retain their technical client names; the Reborn display name is not evidence of RetroAchievements approval.

### What is stored locally

After sign-in, the RetroAchievements token is stored locally in `.oe_credentials` in the selected data folder. The app may also store local preferences such as whether hardcore mode is enabled. See [Data folder locations](data-folder.md); the legacy Application Support path is not a fixed destination for new installations.

Your RetroAchievements password is not stored by OpenEmu Reborn.

### Data controlled by RetroAchievements

RetroAchievements is an external service. OpenEmu Reborn does not operate RetroAchievements servers and does not control RetroAchievements-side retention, account deletion, or profile data. For RetroAchievements account/privacy questions, refer to RetroAchievements directly.

---

## Google Drive Save Sync (optional)

This feature lets you back up and sync your save states and battery saves to your own Google Drive. It is off by default and only activates after you sign in.

Sign-in also requires configured OAuth credentials in that build; copying the public secrets template alone does not configure a working Google client.

### What access is requested

OpenEmu Reborn requests the `drive.appdata` scope. This gives the app access to a private, hidden App Data folder inside your Google Drive. This folder:

- Is not visible in the Google Drive web interface
- Cannot be read by other apps
- Is accessed through the build's configured OAuth app identity. Renaming OpenEmu to Reborn does not create a separate Google app-data space.

The app does **not** request access to your files, documents, photos, or any other part of your Google Drive.

### What is stored in your Drive

Only your game save data:

- Save state files (snapshots of game progress)
- Battery save files (in-game save data)

No personal information, no device identifiers, no usage metrics.

### How authentication works

Sign-in uses Google's standard OAuth 2.0 flow. Your Google account password is never seen or stored by the app. After you authorize access, Google issues an OAuth token. That token is stored locally in the encrypted `.oe_credentials` file in the selected data folder and is used only to read and write your save data to the App Data folder.

### Revoking access

You can disconnect Google Drive at any time from **Preferences → Cloud Sync → Sign Out**. This clears the stored Google Drive token from OpenEmu Reborn's local credential store. You can also revoke access from your Google Account at [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

---

## Sentry crash reporting (optional)

OpenEmu Reborn can send crash, hang, and performance diagnostic reports to Sentry. This is optional and consent-gated. On first launch, the app asks whether you want to send crash reports.

If you opt in, reports may include:

- App version and build number.
- macOS/device diagnostic information.
- Stack traces, crash details, hangs, and performance traces.
- Breadcrumbs and structured logs related to app behavior.
- Active game title, system identifier, and core identifier at the time of a crash.

Crash reports do **not** intentionally include:

- Game ROM files.
- Save state files.
- Battery save files.
- Passwords.

Sentry events are sent to Sentry's hosted service. The current project configuration uses Sentry's US ingest endpoint (`ingest.us.sentry.io`). OpenEmu Reborn does not operate Sentry's servers.

You can decline crash reporting when prompted. If you previously opted in and want help resetting that preference, contact the project without posting personal diagnostics publicly. Rebranding does not move the inherited Sentry project or transfer access to its reports.

---

## What this app does not do

- Does not sell your data.
- Does not include ads.
- Does not include in-app purchases or subscriptions.
- Does not operate its own analytics backend.
- Does not transmit game ROMs to this project.
- Does not transmit save data to this project.
- Does not access your Google Drive files outside the hidden App Data folder.

---

## Open source

The full source code is available at [github.com/communism420/OpenEmu-Reborn](https://github.com/communism420/OpenEmu-Reborn). You can inspect exactly what data is read, written, and transmitted.

---

## Changes to this policy

If the app adds new network features that affect privacy, this document will be updated and the "Last updated" date above will change. Significant changes will be noted in the release notes.

---

## Contact

For non-confidential questions, use a draft PR in the [project repository](https://github.com/communism420/OpenEmu-Reborn), or Issues/Discussions if those features are enabled later. For vulnerabilities, follow the [security policy](../.github/SECURITY.md); do not post secrets or private diagnostics publicly.
