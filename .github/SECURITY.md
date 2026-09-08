# Security Policy

## Supported Versions

OpenEmu Reborn `1.0.0` is the new application's development version line. No
Reborn release has been published yet. This independent fan-maintained project
does not promise a security-support period or response deadline. Upstream
OpenEmu-Silicon version numbers and security claims do not automatically apply
to Reborn; emulator cores retain their own versions and upstream policies.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

If enabled for this repository, use [GitHub's private vulnerability reporting](https://github.com/communism420/OpenEmu-Reborn/security/advisories/new). If it is unavailable, ask the maintainer for a private reporting channel without disclosing the vulnerability in a public issue or PR. Do not report Reborn-specific vulnerabilities to another fork merely because its reporting form is available.

Include as much of the following as you can:

- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept
- Affected version(s)
- Any suggested fix, if you have one

## Response Process

- Reports are handled on a best-effort basis; there is no acknowledgement deadline
- Confirmed reports are assessed by severity and the maintainer's available capacity
- You will be credited in the release notes unless you prefer to remain anonymous

## Scope

This project is a macOS desktop emulator. The primary attack surface relevant to security reports:

- **Google Drive OAuth integration** — token storage, scope handling, redirect URI
- **ROM/save file parsing** — malformed files that could cause unexpected behaviour
- **Core plugins** — bundled emulation cores that process untrusted input (ROM data)

Out of scope: vulnerabilities in upstream emulation cores (report those to the respective upstream projects), or issues requiring physical access to the machine.

## Privacy Policy

For information on how the app handles user data, see the [Privacy Policy](../docs/privacy-policy.md).
