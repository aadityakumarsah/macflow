# FocusFlow

A native macOS recording and editing app, with a local Chrome tab recording companion. Built with SwiftUI, ScreenCaptureKit, AVFoundation, Core Image, and browser media APIs. Recordings stay on your Mac.

Landing page: <https://macflow-delta.vercel.app/> (also on <https://aadityakumarsah.github.io/macflow/>)

## Install

Requires macOS 14+ on Apple silicon.

```sh
curl -fsSL https://raw.githubusercontent.com/aadityakumarsah/macflow/main/install.sh | bash
```

The installer resolves the latest release, shows a live progress bar while it
downloads, copies **FocusFlow** into `/Applications`, and clears the download
quarantine flag. Set `FOCUSFLOW_PREFIX` to install somewhere else.

Prefer the disk image? Take it from the
[latest release](https://github.com/aadityakumarsah/macflow/releases/latest)
and drag FocusFlow into Applications — then right-click the app and choose
**Open** the first time.

FocusFlow is signed ad-hoc rather than with a paid Developer ID, so Gatekeeper
would otherwise refuse the first launch. The install script clears the
quarantine flag for you; a browser download does not.

## Updating

From 0.4.0 onward FocusFlow checks GitHub Releases on launch and offers any
newer build in a bar under the toolbar. **Install and relaunch** downloads the
disk image, verifies it, replaces the app in place and reopens it. There is
also **FocusFlow → Check for Updates…**. Nothing is installed without a press.

Earlier builds have no updater, so 0.3.0 and older must be updated once by
hand — rerun the install command, or take the `.dmg` from the latest release.

The app cannot overwrite itself while running, so installation hands off to a
short script that waits for the process to exit, swaps the bundle and relaunches.
The old copy is kept until the new one is in place: if the swap fails, the
previous version is put back rather than leaving no app at all. FocusFlow must
be somewhere writable — it refuses to update while running from a disk image.

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

The studio can be served two ways. By default FocusFlow serves it itself, so
the page never touches the network. Tick **Open the web studio instead** and it
opens the published copy at <https://macflow-delta.vercel.app/studio/>, which
posts the recording back to this Mac over the loopback bridge and hands off to
the editor exactly as the local copy does. The difference is where the page's
code comes from: the app bundle, or the network. The recording itself is local
either way.

Only the hosts the studio is published on may post to the bridge, and only with
the session token, which reaches the page through the URL fragment when the app
opens it — fragments are never sent to a server, so a casual visitor to the site
has no session and cannot record. Chrome additionally treats a public page
reaching loopback as Private Network Access, so the bridge answers that
preflight explicitly.

Click zooms work for tab recordings too. A page cannot see pointer events in
the tab it is capturing, so FocusFlow follows the pointer itself while Chrome
records and builds the zooms from that. The browser reports the captured size,
which together with Chrome's window bounds pins down where the page sits on
screen. Samples are taken only while Chrome is frontmost and the pointer is
over the captured page, so a click in another app cannot invent a zoom. This is
an approximation of a geometry the browser does not expose, and it needs Input
Monitoring permission.

API keys for AI providers live in **FocusFlow → Settings → AI**, stored in the
macOS Keychain rather than in preferences or project files. Nothing calls them
yet; the storage exists so a key is in place before the features that need it.

Keep FocusFlow open during tab capture. The companion uses a random port bound to `127.0.0.1`, a per-session token, and same-origin write checks. Media chunks are written locally. Nothing is uploaded to an external service. A 512 MB combined session limit bounds the browser’s recovery buffer; the session stops and saves when reached. Backup download buttons remain available after capture, including if local handoff fails. A browser supporting MP4 MediaRecorder output is required; unsupported browsers show a useful error before recording starts.

Grant Screen Recording permission to FocusFlow for native capture. Camera and microphone permission is requested only when enabled. Input Monitoring enables shortcut badges; ordinary typed text is not collected. Browser capture uses Chrome’s separate sharing and device permission prompts.

## Editing

The studio uses a quiet neutral canvas with a blue accent, a dedicated navigation sidebar, and one settings panel at a time: **Canvas**, **Cursor**, **Motion**, **Camera**, **Audio**, and **Export**. The timeline only shows effect tracks in use. Add any effect from **Motion** or the timeline’s **Add effect** menu.

After a native Window or Display recording, open **Cursor** to change its size from **0.5× to 10×**, with quick 1×/2×/4×/6×/8× buttons and an actual-renderer style preview. New recordings start at **2×**; saved projects keep their previous size. Choose ripple, pulse, or press click animations, adjust ripple/pulse size, pick a custom effect color, or add a soft pointer highlight. Advanced controls include I-beam scale, tilt, and cursor opacity. **Reset cursor settings** can be undone. These settings are saved with the project and applied to both preview and export.

Videos without a separate pointer track show an explanation instead of editable cursor controls. A cursor baked into an imported video cannot be independently resized. For connected Chrome tab capture, FocusFlow asks Chrome to omit its baked-in cursor and records a separate pointer track; support depends on Chrome. If Chrome includes the cursor, the editor leaves its overlay off by default and explains the limitation.

- Shared Core Image renderer for preview and MP4 export, including background, rounded corners, shadows, camera, blur, cursor, and zoom.
- Automatic click-based zooms with grouped click activity, smoother easing, adjustable transition duration, and optional cursor following. Camera tracking holds its position when the pointer leaves the recorded area.
- Pan segments with editable start/end focus points, slide-up/slide-in/scale entrances, and optional fade-out.
- Editable macOS light/dark window frame with red/yellow/green controls, optional title, title-bar height, and control size. The frame stays fixed while the content zooms.
- Non-destructive **Crop to tab or pane** in the editor, including imported and browser videos. Canvas fitting preserves the selected content instead of filling and clipping the edges.
- Timed spotlights, accent outlines, pixelation, and text callouts, with easing and preview positioning. Select an effect and drag its focus directly on the preview.
- **Full screen preview** (⌃⌘F, or the arrows in the toolbar) hides the rails, inspector and timeline, takes the window to macOS full screen, and gives the preview the display. Escape or the on-screen control returns.
- Cursor size now goes to 10×, and the I-beam has its own scale beside it — it is a thin glyph and reads far smaller than the arrow at the same size.
- Smooth bounded cursor interpolation, outlined Pearl/Obsidian/Accent styles, four accent colors, gentle movement tilt, size, visibility, shadow, ripple/pulse/press click effects, and optional keyboard shortcut badges. Cursor and title-bar artwork is cached for playback.
- Region blur with editable center, width, height, strength, and timing; one button blurs the entire frame. Multiple regions can overlap.
- Timeline scrubbing, segment move/edge resize, duplicate, split at playhead, delete, undo, and redo.
- Non-destructive trim in/out markers, playback/export speed, and audio mute.
- Separate camera layer with position, size, rounded/circular shape, mirroring, and show/hide. Drag the camera directly in the preview.
- Source, landscape, portrait, square, 4:3, and **Custom** canvas formats. The **Custom ratio** button above the preview opens width/height controls directly; all aspect ratios also appear first in the **Canvas** panel. Custom takes any width:height, including decimals such as 2.39:1, with one-tap presets for 21:9, 2.39:1, 3:2 and 4:5 and a swap button. The result is capped on its longer side and kept to even dimensions. Changing the ratio re-fits the composition: padding tightens as the content and canvas aspects diverge, and the camera moves into the area that opens up. Turn this off with **Re-fit when the ratio changes**.
- Backgrounds: six gradient presets, a solid colour, a custom two-colour gradient at any angle, an image file (fill or fit, with an adjustable dim), or the recording itself blurred behind the frame. A missing image file falls back to the gradient rather than rendering black.
- Export settings: MP4 or MOV, Source/720p/1080p/1440p/4K, and 30 or 60 fps. Resolution scales the composed canvas and keeps even dimensions.
- Recording library and recoverable deletion through macOS Trash. Deleting the open recording also clears the editor.
- Automatic local edit saving plus **Save Project** and **Open video or project**. Camera, cursor, trim, speed, appearance, effects, and recording metadata are preserved.

Native camera start time is aligned to the screen video. Chrome camera framing is carried into the editor. Open the hosted tab studio from FocusFlow, or click **Open FocusFlow** on the site with version 0.9 or later installed, to connect the capture. Stopping the recording saves it locally and brings it into the editor with click zooms generated from the pointer track when available. Chrome may still bake its cursor into the video; in that case, the original pixels cannot be removed or independently resized. Direct browser-only recording offers an MP4 download.

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

The cursor checks also measure rendered size changes, glow and click scaling, opacity, legacy cursor decoding, settings round trips, and reset/undo behavior. The standalone Swift checks run with Command Line Tools without requiring XCTest. They cover legacy project decoding, appearance settings round trips, crop rounding and aspect preservation, bounded smooth zooms, cursor tracking through gaps, undo/redo and segment limits, local HTTP origin/token handling, and real encoded MP4 rendering. Browser checks exercise tab-only selection, cleanup of rejected streams, preserving a valid source after a rejected selection, and a second guard before recording. The export check measures trim/speed duration and image differences inside/outside a blur region, checks the camera layer, and verifies source overwrite protection. Rendered QA frames are saved at `.build/qa/export-render.png`, `.build/qa/presentation-render.png`, and `.build/qa/cursor-render.png`. Presentation checks cover toolbar removal, a fixed title bar during zoom, cursor rendering, spotlight/callout compositing, and entrance/exit frames. The script also checks browser JavaScript syntax.

Earlier live UI validation covered native window recording → stop → edit → region blur → recoverable deletion, and Chrome single-tab selection → live preview → record → pause/resume → automatic editor handoff. The studio redesign was checked with rendered SwiftUI layout snapshots at 1280 × 820, plus the automated rendering and export checks. Live interaction with the redesigned app was not available through the UI tool in this session. For the earlier capture/appearance update, the rebuilt UI and area selector were inspected; a live area recording could not be completed while desktop/window visibility was changing. Crop geometry, appearance rendering, motion, tab rejection, and export were checked automatically. Camera compositing uses generated footage; physical camera/microphone capture was not exercised.

## Reference and scope

The installed Cursorful recorder/editor was inspected through its interface to understand its capture-to-edit workflow, cursor controls, timeline operations, and layout. FocusFlow keeps its own implementation and visual assets. No REA tool or asset source called “Do” was identified in this workspace; those references need a concrete name/path to integrate.

The implementation is not full Cursorful feature parity. Speech-to-text captions, multi-clip assembly, motion blur, cloud collaboration, AI titles or summaries, and native capture pause/resume are not implemented. Chrome capture supports pause/resume. Changing the selected native capture source starts a new recording.

Implementation references: [Chrome sharing controls](https://developer.chrome.com/docs/web-platform/screen-sharing-controls), [Chrome MediaRecorder](https://developer.chrome.com/blog/mediarecorder), [Apple SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager).

## License

MIT — see [LICENSE](LICENSE).
