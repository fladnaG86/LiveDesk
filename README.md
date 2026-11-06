# LiveDesk

Live wallpaper app for macOS (26+), written from scratch in Swift / SwiftUI / Metal.

## Features

- **Video, image and scene wallpapers** on every screen, behind desktop icons, on all Spaces.
  Per-screen assignment with an "all screens" default; config survives disconnects.
- **Interactive scenes**: a folder with `manifest.json` and up to 8 Metal fragment passes.
  Scenes get time, resolution, cursor position and live audio bands (bass / mid / treble).
- **Audio reactive** via a Core Audio process tap on system output (only levels are computed, nothing is recorded).
- **Power aware**: pauses on battery, in Low Power Mode, when a window covers the screen, when displays sleep.
- **Lock Screen**: videos marked with the lock are transcoded to HEVC and added to the macOS Aerial catalog
  (`~/Library/Application Support/com.apple.wallpaper/aerials`) in a "LiveDesk" category.
  Pick them in System Settings > Wallpaper. The original `entries.json` is backed up in
  `~/Library/Application Support/LiveDesk/AerialBackups/`. Turning the option off removes everything LiveDesk added.
- Menu bar control, library window with drag & drop, rotation timer, launch at login.

## Build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project LiveDesk.xcodeproj -scheme LiveDesk -derivedDataPath build test   # tests
open build/Build/Products/Debug/LiveDesk.app
```

Signed ad-hoc (no Apple Developer team needed). No sandbox: the app writes to the user Aerial store
and restarts `WallpaperAgent` so the system rereads it.

## Scene format

```json
{
  "id": "A11C0E5E-7A1B-4C2D-8E3F-0A1B2C3D4E01",
  "name": "Aurora",
  "passes": [{ "source": "aurora.metal", "function": "aurora" }],
  "usesAudio": false,
  "usesMouse": true
}
```

Each pass function:

```metal
fragment float4 myPass(LDVertexOut in [[stage_in]],
                       constant LDUniforms& u [[buffer(0)]],
                       array<texture2d<float>, 8> passes [[texture(0)]],
                       sampler smp [[sampler(0)]])
```

- `in.uv`: 0...1, origin bottom-left. Sample a pass with `passes[k].sample(smp, ld_tc(uv))`.
- `passes[k]`: latest output of pass k — this frame for earlier passes, previous frame for itself and later ones (feedback).
- `u.timeInfo` (seconds, frame, dt), `u.resolution` (px, 1/px), `u.mouse` (xy 0...1, z = on this screen), `u.audio` (bass, mid, treble, level).

Built-in scenes live in `Resources/Scenes` (Aurora, Pulse, Ink).

## Layout

- `Sources/LiveDeskKit` — library store, reconciler, players/windows, scene renderer, audio tap, Aerial installer.
- `Sources/LiveDesk` — SwiftUI app (menu bar, library, settings).
- `Tests/LiveDeskKitTests` — Swift Testing suite (includes real Metal compilation of the built-in scenes).
