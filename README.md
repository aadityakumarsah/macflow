# FocusFlow — open-source screen recorder and motion editor for macOS

[![Release](https://img.shields.io/github/v/release/aadityakumarsah/macflow?label=release)](https://github.com/aadityakumarsah/macflow/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Built with SwiftUI](https://img.shields.io/badge/built%20with-SwiftUI-orange.svg)](#how-it-is-built)

**FocusFlow records your Mac screen and turns every click into an animated zoom.** It is a free, MIT-licensed, native macOS app that puts a screen recorder and a motion editor in one window — record a window, a display, or a single Chrome tab, and the recording opens in a timeline with the zooms already written for you.

Nothing is uploaded. There is no account, no telemetry and no cloud step: recordings are written straight to `~/Movies/FocusFlow` and stay there.

**Website:** <https://macflow-delta.vercel.app/> · **Download:** [latest release](https://github.com/aadityakumarsah/macflow/releases/latest)

---

## Install

One line in Terminal, on macOS 14 or later (Apple silicon):

```sh
curl -fsSL https://raw.githubusercontent.com/aadityakumarsah/macflow/main/install.sh | bash
```

That resolves the latest release, downloads the disk image with a progress bar, copies **FocusFlow** into `/Applications`, and clears the download quarantine flag. Set `FOCUSFLOW_PREFIX` to install elsewhere.

Prefer the disk image? Take it from the [latest release](https://github.com/aadityakumarsah/macflow/releases/latest) and drag FocusFlow into Applications — then **right-click the app and choose Open** the first time.

> FocusFlow is signed ad-hoc rather than with a paid Apple Developer ID, and is not notarized. Gatekeeper therefore blocks a plain double-click on a browser download. The install command clears the quarantine flag for you; a browser download does not.

After the first install, FocusFlow updates itself — see [Updating](#updating).

---

## What it does

### Recording

| Source | What you get |
| :- | :- |
| **Window** | Pick a window with a live source preview. **Select area** crops to one pane before recording, excluding the toolbar. |
| **Display** | A whole display. FocusFlow's own windows and audio are excluded, so it cannot record itself. |
| **Chrome tab** | Only the chosen tab's page content, without browser chrome. Pause/resume, tab audio, camera and microphone. **Stop & edit** sends it straight back to the editor. |

Up to 60 fps. Camera and screen are recorded separately and composited, so the camera stays a movable, resizable layer in the editor rather than being burned in.

### Automatic editing

Clicks are grouped into smooth, eased **zooms** before you touch anything — including for Chrome tab recordings, where FocusFlow follows the pointer itself, because a web page cannot see events in the tab it is capturing.

Only zooms are generated automatically. Spotlights, outlines, pixelation and callouts are all available, but adding one is your decision.

### The editor

- **3D camera, on the canvas** — choose Orbit, Rise, Showcase, Drift, Push in, or Tilt reveal from a visual preset gallery. The frame, chrome, shadow, and recorded content turn together; the content gets a small extra offset for depth. Adjust strength and duration, reverse direction, and preview just that move. Fine-tune the pose with sliders or drag the frame on the canvas. Glide across, Unfold and Pull back are there too.
- **Colour grades** — Cinematic, Noir, Vintage, Frost, Golden, Midnight, Vivid, Dreamy, over exposure, contrast and vignette.
- **Smooth scrolling** — a true shutter, blending neighbouring frames so scrolling stops strobing, spent only where the recording says the wheel turned. Separate from camera motion blur, and separately adjustable.
- **Cursor** — 0.5× to 10× with quick presets, ripple/pulse/press click effects, any accent colour, a pointer highlight, independent I-beam scale, tilt, opacity and shadow.
- **A real macOS window frame** — light or dark, working traffic lights, optional title, adjustable bar height. It stays fixed while the content zooms underneath.
- **Backgrounds** — 11 bundled images, gradient presets, any solid colour, a custom two-colour gradient at any angle, your own image, or the recording itself blurred behind the frame.
- **Privacy masks** — blur or pixelate any region, with editable position, size, strength and timing. Regions can overlap.
- **Canvas** — Source, 16:9, 9:16, 1:1, 4:3, or **any custom ratio** including decimals like 2.39:1. Change it and padding and the camera re-fit themselves.
- **Timeline** — scrub, move, resize, duplicate, split at the playhead, delete, undo, redo. Non-destructive trim, playback speed, audio mute, and a looping music track.
- **Full screen preview** — ⌃⌘F gives the preview the whole display.
- **Export** — MP4 or MOV, Source to 4K, 30 or 60 fps. **Source** is the resolution you recorded at, encoded at no less than the rate the recording itself was carrying, so a 4K capture leaves as a 4K file.

Every camera move — a click zoom, a typing follow, a pan — is smoothed over a window centred on the moment, so the frame can never change speed abruptly however abruptly the thing it is following does.

Preview and export run through one shared Core Image renderer, so the frame you scrub is the frame you ship.

To add a 3D move, press **3D** above the preview, then **Choose a 3D look**. Choosing a look updates the selected 3D segment, or adds one at the playhead when no 3D segment is selected. Use **Strength**, **Duration**, and **Reverse direction** in the segment inspector; **Fine tune** opens the individual axes and blur options. **Preview move** plays only that effect. The frame and content share one move, with restrained parallax inside the frame. Changes to 3D presentation reuse the existing media tracks for a lighter preview update.

---

## How it compares

An honest comparison, including where FocusFlow is behind:

| | FocusFlow | Screen Studio | Loom | OBS Studio |
| :- | :- | :- | :- | :- |
| Price | **Free** | Paid | Free tier + paid | Free |
| Licence | **MIT, open source** | Proprietary | Proprietary | GPL |
| Automatic click zooms | **Yes** | Yes | No | No |
| 3D camera moves | **Yes** | Yes | No | No |
| Records a single browser tab | **Yes** | No | Yes | No |
| Works fully offline | **Yes** | Yes | No | Yes |
| Platform | macOS 14+ | macOS | macOS, Windows, web | macOS, Windows, Linux |
| Signed with a paid Developer ID | **No** | Yes | Yes | Yes |
| Cloud sharing links | No | No | Yes | No |
| Transcription, captions, AI summaries | No | Some | Yes | No |
| Live streaming | No | No | No | Yes |
| Maturity | Early | Mature | Mature | Mature |

**Choose FocusFlow** if you want automatic click zooms and a motion editor, free and open source, with nothing leaving your Mac.

**Choose something else** if you need captions or transcription, cloud share links, Windows or Linux, live streaming, or a notarized build your IT policy will accept.

---

## Updating

FocusFlow checks GitHub Releases at launch and every six hours, and offers a newer build in a bar under the toolbar. **Install and relaunch** downloads it, verifies it, replaces the app and reopens it. There is also **FocusFlow → Check for Updates…**. Nothing installs without a press.

Before replacing anything it checks that the asset is a `.dmg` served over HTTPS from GitHub, that the bundle carries FocusFlow's identifier and a genuinely newer version, and that its code signature verifies. Your existing copy is moved aside rather than deleted, and put back if the swap fails, so a failed update cannot leave you with no app.

Versions before 0.4.0 have no updater and must be updated once by hand.

---

## Requirements

- **macOS 14 (Sonoma) or later**, Apple silicon
- **macOS 15+** for native microphone recording
- **Google Chrome** for single-tab capture
- **Screen Recording** permission for native capture; **Input Monitoring** for click zooms and shortcut badges; camera and microphone only when you switch them on

---

## FAQ

**Is FocusFlow free?**
Yes — free and MIT licensed. No account, no subscription, no paid tier.

**Does my recording get uploaded anywhere?**
No. Recordings are written to `~/Movies/FocusFlow` on your own Mac. There is no account system and no upload step. The Chrome companion runs on `127.0.0.1` with a per-session token.

**Why does macOS say the app can't be opened?**
It is signed ad-hoc rather than with a paid Apple Developer ID, so Gatekeeper blocks a browser download. Use the install command above, which clears the quarantine flag, or right-click the app and choose **Open** once.

**Is it a Screen Studio alternative?**
For automatic click zooms, 3D camera moves, backgrounds and cursor styling, yes — and it is free and open source. Screen Studio is a mature, notarized commercial product and FocusFlow is early. FocusFlow also records a single Chrome tab, which Screen Studio does not.

**Is it a Loom alternative?**
Only for recording and editing. FocusFlow has no cloud sharing, no share links, no viewer analytics and no transcription. If you need to send someone a link, Loom does that and this does not.

**Can it record a single browser tab?**
Yes. Chrome's picker is restricted to tabs, and only the page content is recorded — no browser toolbar. Click zooms work there too.

**Does it do captions or transcription?**
No.

**Does it work on Intel Macs or Windows?**
Builds target Apple silicon on macOS 14+. There is no Windows or Linux version.

**How big is the download?**
About 6.5 MB.

**Can I build it myself?**
Yes — see below. It is a single Swift package with no third-party dependencies.

---

## Building from source

Requires macOS 14+ and the Apple Command Line Tools. No package manager, no dependencies.

```sh
git clone https://github.com/aadityakumarsah/macflow.git
cd macflow
./build-app.sh
open dist/FocusFlow.app
```

- `./check.sh` runs the test suite — rendering checks that read real pixels, a real MP4 export, the local HTTP bridge, and the updater.
- `./scripts/make-dmg.sh` packages a styled disk image.
- `./scripts/make-hero-art.sh` and `./scripts/build-studio-preview.sh` build the website assets.

## How it is built

SwiftUI, ScreenCaptureKit, AVFoundation and Core Image, plus browser media APIs for tab capture. One shared Core Image renderer serves both the preview and the export, so there is no second code path to drift. The image context is Metal-backed where the hardware allows.

Tab capture runs a small local HTTP bridge on a random `127.0.0.1` port with a per-session token and strict origin checks. Media chunks are written to disk as they arrive, so memory does not grow with the recording.

## Privacy

- Recordings and projects are written to `~/Movies/FocusFlow` and nowhere else.
- No account, no telemetry, no analytics, no upload.
- Input Monitoring is used for pointer positions, clicks and modifier shortcuts. Ordinary typed text is never collected.
- API keys for AI providers, if you add any, are stored in the macOS Keychain — not in preferences or project files. Nothing in the app calls them yet.
- The only network requests FocusFlow makes are to GitHub, to check for updates.

## Project layout

| Path | What it holds |
| :- | :- |
| `Sources/FocusFlow` | The app: recorder, editor, renderer, updater |
| `Sources/FocusFlow/BrowserRecorder` | The Chrome tab studio page served locally |
| `Tests/FocusFlowTests` | Checks, runnable with the Command Line Tools |
| `docs/` | The website, served by both Vercel and GitHub Pages |
| `scripts/` | Build, packaging and asset generation |

## Contributing

Issues and pull requests are welcome. Run `./check.sh` before opening one.

## Licence

[MIT](LICENSE) © Aaditya sah

---

<sub>Keywords: macOS screen recorder, open source screen recorder, screen recording with automatic zoom, cursor animation, motion editor, Screen Studio alternative, Loom alternative, Cursorful alternative, Chrome tab recorder, ScreenCaptureKit, SwiftUI, product demo video, software tutorial recording, free screen recorder for Mac.</sub>
