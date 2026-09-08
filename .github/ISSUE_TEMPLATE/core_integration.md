---
name: Core integration
about: An emulator core fails to build, is missing from the workspace, or needs architecture porting work
title: ''
labels: "core: other"
assignees: ''

---

## Core and system

- **Core name:** (e.g. PokeMini, Mupen64Plus)
- **System:** (e.g. Pokémon Mini, Nintendo 64)
- **System identifier:** (e.g. `openemu.system.pokemonmini`)

## Problem

<!-- What fails? Paste the build error or describe what's missing. -->

```
<build error or description here>
```

## Root cause

<!-- What is causing the failure? Missing headers? Missing source? No arm64 or x86_64 dynarec? -->

## Proposed fix

<!-- What needs to happen to resolve this? Command-line steps if known. -->

## Notes

- [ ] System plugin already exists in `OpenEmu/SystemPlugins/`
- [ ] No `VALID_ARCHS` restriction unintentionally blocks `arm64` or `x86_64`
- [ ] Source is fully inlined (no submodules to initialize)
- [ ] Core is added to `OpenEmu-metal.xcworkspace`

## Related

<!-- Link upstream issues or PRs if relevant -->
