# FocusFlow

A native macOS recording and editing app, with a local Chrome tab recording companion. Built with SwiftUI, ScreenCaptureKit, AVFoundation, Core Image, and browser media APIs. Recordings stay on your Mac.

Landing page: <https://aadityakumarsah.github.io/macflow/>

## Install

Requires macOS 14+ on Apple silicon.

```sh
curl -L -o ~/Downloads/focusflow.dmg https://github.com/aadityakumarsah/macflow/releases/download/v0.2.0/FocusFlow-0.2.0.dmg && xattr -c ~/Downloads/focusflow.dmg && open ~/Downloads/focusflow.dmg
```

The disk image opens; drag **FocusFlow** into Applications.

To install straight into `/Applications` without the drag step:

```sh
curl -fsSL https://raw.githubusercontent.com/aadityakumarsah/macflow/main/install.sh | bash
```

FocusFlow is signed ad-hoc rather than with a paid Developer ID, so Gatekeeper would otherwise refuse the first launch. Both commands above clear the download quarantine flag for you. If you download the `.dmg` from the browser instead, right-click the app and choose **Open** the first time.

## Run

Requires macOS 14+ and Apple Command Line Tools. Native microphone recording requires macOS 15+.

```sh
./build-app.sh
open dist/FocusFlow.app
```

The app uses an ad-hoc signature for local use. Developer ID signing and notarization are not configured.

## Recording

Click **Record**, then choose:

- **Window**: bring the desired window onto the current desktop, choose it and see a source preview before starting. Enable **Select area** and drag around a tab’s content or a single pane to save only that region, excluding the original toolbar. The pointer and click coordinates are aligned to the selected area. The recording view displays actual captured frames, with a separate live camera preview.
- **Display**: select a display. FocusFlow’s own windows and audio are excluded to avoid recording the recorder recursively.
- **Chrome tab**: click **Open Chrome tab studio**, then **Choose a Chrome tab**. Chrome’s picker opens on tabs; window or screen selections are rejected before recording. Only the selected tab’s page content is recorded, without the browser toolbar. Check the live preview, enable camera/microphone as needed, then press **Start recording**. Pause/resume, camera shape/mirroring/position, tab audio, and device selection are available. **Stop & edit** saves the video back into FocusFlow automatically.

Keep FocusFlow open during tab capture. The companion uses a random port bound to `127.0.0.1`, a per-session token, and same-origin write checks. Media chunks are written locally. Nothing is uploaded to an external service. A 512 MB combined session limit bounds the browser’s recovery buffer; the session stops and saves when reached. Backup download buttons remain available after capture, including if local handoff fails. A browser supporting MP4 MediaRecorder output is required; unsupported browsers show a useful error before recording starts.

Grant Screen Recording permission to FocusFlow for native capture. Camera and microphone permission is requested only when enabled. Input Monitoring enables shortcut badges; ordinary typed text is not collected. Browser capture uses Chrome’s separate sharing and device permission prompts.

## Editing

- Shared Core Image renderer for preview and MP4 export, including background, rounded corners, shadows, camera, blur, cursor, and zoom.
- Automatic click-based zooms with grouped click activity, smoother easing, adjustable transition duration, and optional cursor following. Camera tracking holds its position when the pointer leaves the recorded area.
- Pan segments with editable start/end focus points, slide-up/slide-in/scale entrances, and optional fade-out.
- Editable macOS light/dark window frame with red/yellow/green controls, optional title, title-bar height, and control size. The frame stays fixed while the content zooms.
- Non-destructive **Crop to tab or pane** in the editor, including imported and browser videos. Canvas fitting preserves the selected content instead of filling and clipping the edges.
- Timed spotlights and text callouts, with easing and preview positioning. Select an effect and drag its focus directly on the preview.
- Smooth bounded cursor interpolation, outlined Pearl/Obsidian/Accent styles, four accent colors, gentle movement tilt, size, visibility, shadow, ripple/pulse/press click effects, and optional keyboard shortcut badges. Cursor and title-bar artwork is cached for playback.
- Region blur with editable center, width, height, strength, and timing; one button blurs the entire frame. Multiple regions can overlap.
- Timeline scrubbing, segment move/edge resize, duplicate, split at playhead, delete, undo, and redo.
- Non-destructive trim in/out markers, playback/export speed, and audio mute.
- Separate camera layer with position, size, rounded/circular shape, mirroring, and show/hide. Drag the camera directly in the preview.
- Source, landscape, portrait, square, and 4:3 canvas formats; six original background presets.
- Recording library and recoverable deletion through macOS Trash. Deleting the open recording also clears the editor.
- Automatic local edit saving plus **Save Project** and **Open video or project**. Camera, cursor, trim, speed, appearance, effects, and recording metadata are preserved.

Native camera start time is aligned to the screen video. Chrome camera framing is carried into the editor. Browser recordings contain the browser-rendered cursor in their video; cross-tab pointer positions and keyboard events are not available as separate editing metadata. Cursor controls apply to native recordings with pointer metadata.

## Files

Recordings are stored in `~/Movies/FocusFlow`:

- `Recording … .mp4` / `Tab … .mp4`: screen video
- `Camera … .mov` / `.mp4`: separate camera video
- `*.focusflow.json`: original capture metadata
- `*.edits.json`: automatic project edits
- `*.project.json`: user-saved projects (source video and camera files must remain available)

Export uses a temporary output and preserves source files. Export resolution is source matched up to a 1920-pixel longest edge, or the selected fixed canvas size.

## Validation

```sh
./check.sh
```

The standalone Swift checks run with Command Line Tools without requiring XCTest. They cover legacy project decoding, appearance settings round trips, crop rounding and aspect preservation, bounded smooth zooms, cursor tracking through gaps, undo/redo and segment limits, local HTTP origin/token handling, and real encoded MP4 rendering. Browser checks exercise tab-only selection, cleanup of rejected streams, preserving a valid source after a rejected selection, and a second guard before recording. The export check measures trim/speed duration and image differences inside/outside a blur region, checks the camera layer, and verifies source overwrite protection. Rendered QA frames are saved at `.build/qa/export-render.png`, `.build/qa/presentation-render.png`, and `.build/qa/cursor-render.png`. Presentation checks cover toolbar removal, a fixed title bar during zoom, cursor rendering, spotlight/callout compositing, and entrance/exit frames. The script also checks browser JavaScript syntax.

Earlier live UI validation covered native window recording → stop → edit → region blur → recoverable deletion, and Chrome single-tab selection → live preview → record → pause/resume → automatic editor handoff. For the current capture/appearance update, the rebuilt UI and area selector were inspected; a live area recording could not be completed while desktop/window visibility was changing. Crop geometry, appearance rendering, motion, tab rejection, and export were checked automatically. Camera compositing uses generated footage; physical camera/microphone capture was not exercised.

## Reference and scope

The installed Cursorful recorder/editor was inspected through its interface to understand its capture-to-edit workflow, cursor controls, timeline operations, and layout. FocusFlow keeps its own implementation and visual assets. No REA tool or asset source called “Do” was identified in this workspace; those references need a concrete name/path to integrate.

The implementation is not full Cursorful feature parity. Speech-to-text captions, multi-clip assembly, motion blur, cloud collaboration, custom background images, and native capture pause/resume are not implemented. Chrome capture supports pause/resume. Changing the selected native capture source starts a new recording.

Implementation references: [Chrome sharing controls](https://developer.chrome.com/docs/web-platform/screen-sharing-controls), [Chrome MediaRecorder](https://developer.chrome.com/blog/mediarecorder), [Apple SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager).

## License

MIT — see [LICENSE](LICENSE).
