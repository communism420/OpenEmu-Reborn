# No Shader in OpenEmu Reborn

This uses the inherited renderer; app version `1.0.0` does not imply a core
update. See [Project identity](project-identity.md).

While a game is running, open its controls menu → **Select Shader → No Shader**
(**Без шейдера** in Russian). The same choice is available in the shader
configuration window and the default shader picker in Settings → Gameplay.
Selecting a normal shader again restores its effects through the usual path.

The in-game choice is remembered for that game system, just like other shader
choices. It is not tied to a particular emulator core. Existing defaults are not
changed until the user makes a selection.

`OpenEmu/Shaders/No Shader/No Shader.slangp` contains `shaders = 0`. The existing
common renderer therefore skips all preset effect passes and presents the source
texture using nearest-neighbor sampling. This is not a renamed smoothing shader.
The same presentation path receives software, OpenGL and Metal core output;
individual emulator plugins do not need changes or rebuilding.

Window scaling, aspect ratio, rotation, and the separate Gamma/Saturation controls
remain available. For unadjusted colors, leave Gamma and Saturation at 100%.
The normal GPU work required to draw a window or render a 3D console game is not
disabled by this option.

## Focused verification

The standalone renderer test uses the existing built framework and synthetic
textures; the app test uses an already-built app and a private settings folder:

```bash
no_shader_app="/absolute/path/OpenEmu.app"
bash Scripts/Tests/test-no-shader-rendering.sh "$no_shader_app"
bash Scripts/Tests/test-no-shader-selection.sh "$no_shader_app"
bash Scripts/Tests/test-no-shader-app.sh "$no_shader_app"
```

The app must contain the No Shader resource. Standalone Swift tests also need
the matching local build's Swift module metadata when it has been stripped from
the packaged frameworks. The rendering test needs normal Metal GPU access.
The app test refuses to close an already-running OpenEmu session.

None of these tests builds emulator cores or needs game ROMs. These focused checks do
not mean that every game on every emulator has been played and verified.
