# CallCatch

[![CI](https://github.com/sasha-darkdepot/callcatch/actions/workflows/ci.yml/badge.svg)](https://github.com/sasha-darkdepot/callcatch/actions/workflows/ci.yml)

Menu-bar utility for macOS that catches the start of a call in **Discord,
Signal, Telegram, or WhatsApp** and offers to record it with
[Plaud](https://web.plaud.ai) — one click to start, one click to stop.

It exists because Plaud's own auto-detection ignores these apps (its built-in
list is limited to Zoom / Teams / Slack / Webex / Lark / browsers), so calls
in messengers go unrecorded unless you remember to start Plaud by hand.

> Personal, internal-use project. Not affiliated with PLAUD LLC. See
> [LICENSE](LICENSE).

## Features

- **Detects calls** in Discord, Signal, Telegram (App Store + Desktop builds)
  and WhatsApp by watching per-process microphone usage — event-driven, no
  polling of the apps themselves, no special permissions for detection.
- **Bubble UI**: a floating Liquid Glass capsule at the bottom of the screen —
  "Record in Plaud" when a call starts, "Stop Recording" when it ends. Native
  macOS 26 `glassEffect`, Lucide icons, English UI.
- **Starts recording** in Plaud via its `plaud://` deep link and confirms the
  start by reading Plaud's own log (with retries for a cold start).
- **Stops recording** by clicking Plaud's floating recording widget through
  the Accessibility API — reliably, in any window position and whether the
  widget is collapsed or expanded.
- **Menu bar controls**: manual record/stop, an auto-record toggle, launch at
  login, and a "needs attention" state when setup is incomplete.

## Requirements

- macOS 26 or newer (Liquid Glass UI; CoreAudio process-objects API).
- The Plaud desktop app, installed and signed in.
- To build: Xcode / Swift 6 toolchain. An Apple Development signing identity
  is recommended (see [Signing](#signing-recommended)).

## Install

```bash
INSTALL=1 bash scripts/build-app.sh   # build, sign, install to /Applications
open "/Applications/Call Catch.app"
```

Without `INSTALL=1` the app is built to `build/CallCatch.app` and not copied.

## First run

1. **`user_id`** is picked up automatically from Plaud's logs. If the menu-bar
   icon shows ⚠️ "user_id not found", open [web.plaud.ai](https://web.plaud.ai)
   with the desktop app running, press Record once, and relaunch CallCatch —
   the id will be in the fresh log.
2. **Accessibility**: the first time you use Record/Stop, macOS asks to grant
   CallCatch Accessibility access (System Settings → Privacy & Security →
   Accessibility). This is required to stop recording. Detection and starting
   work without it.

## Usage

A call starts → the bubble appears → **Record in Plaud**. The call ends → the
bubble offers **Stop recording**. Everything is also in the menu-bar menu:

- **Record now** — start manually during a call (e.g. if you dismissed the bubble).
- **Stop recording** — always available while a CallCatch-started recording runs.
- **Auto-record** — start recording automatically 7 s after a call begins.
- **Auto-stop** — when a recording started automatically, stop it 10 s after
  CallCatch detects the call end. The red button in the bubble drains as a
  countdown: click it to stop now, hover to pause the countdown, ✕ to keep
  recording. On by default; only ever arms for auto-started recordings.
- **Launch at login** — register as a login item.

## How it works

| Piece | Mechanism |
|---|---|
| Detection | CoreAudio process objects (`kAudioProcessPropertyIsRunningInput`), matched by bundle-id prefix; 3 s polling fallback. |
| Start | `plaud://record?auto=1&user_id=…` deep link; success confirmed via Plaud's log (`startRecording by scene success`), retried for cold start. |
| Stop | Plaud's recording widget is a floating panel that `AXWindows` doesn't expose; it's located via `CGWindowList` + `AXUIElementCopyElementAtPosition` hit-test, and its stop button is clicked with a global HID `CGEvent` (Electron web content ignores `AXPress` / background clicks). Confirmed via Plaud's log. |
| State | A single-recording "lease" bound to the owning call session; external stops (done inside Plaud) reconcile automatically. |

Design and rationale: [`docs/superpowers/specs`](docs/superpowers/specs);
implementation plan: [`docs/superpowers/plans`](docs/superpowers/plans).

## Signing (recommended)

`scripts/build-app.sh` signs with an Apple Development identity when one is in
your keychain (override with `CODESIGN_IDENTITY`). A stable signature keeps the
Accessibility and microphone grants across rebuilds, because macOS keys those
on the code signature rather than the binary hash. Without an identity the
build falls back to ad-hoc signing and permissions must be re-granted after
every rebuild.

## Limitations

- Auto-record's 7 s threshold does not distinguish a long voice message from a
  call — a voice message over 7 s will be recorded.
- The stop click briefly moves the cursor to the widget (the only input
  Electron web content reliably accepts).
- If an app releases the microphone on mute, a long mute can look like the
  end of a call. With Auto-stop enabled (the default) this stops an
  auto-started recording ~10 s later, and unmuting then starts a new one —
  one meeting can end up split into two files with the muted stretch
  missing. The countdown bubble is your window to intervene (hover pauses,
  ✕ keeps recording); turn Auto-stop off if your apps mute this way.
- Verified against Plaud v1.3.7; a Plaud update may require re-checking the
  deep-link and stop behavior.

Icons: [Lucide](https://lucide.dev) (ISC license), vendored as path data.

## Versioning & releases

CallCatch uses [Semantic Versioning](https://semver.org) — `MAJOR.MINOR.PATCH`.
As a personal 0.x tool the bumps mean:

- **PATCH** (`0.2.`**`1`**) — bug fix, nothing you'd notice differently.
- **MINOR** (`0.`**`3`**`.0`) — a new capability or a notable behavior change.
- **MAJOR** (**`1`**`.0.0`) — reserved for "solid, I rely on it daily" / a
  breaking rework.

**The git tag `vX.Y.Z` is the single source of truth.** The build reads the
marketing version from the latest tag and the build number from the commit
count — nothing is hardcoded, so the version can't drift. `CHANGELOG.md` holds
the human story: every change lands under `## [Unreleased]` until a release
rolls it into a dated version.

**Cut a release with one command** (it runs the tests, rolls the changelog,
commits, tags, pushes, and installs the stamped build — and refuses if the tree
is dirty, out of sync, or the version isn't a clean bump):

```bash
scripts/release.sh 0.3.0
```

That is the only sanctioned path from "changes on `main`" to "a tagged release",
so there is exactly one way to version and it's always followed.

## Development

```bash
swift test                  # unit tests (state machine, parsing, matching)
swift build                 # debug build
INSTALL=1 bash scripts/build-app.sh   # signed .app in /Applications
CALLCATCH_DEBUG=1 ...       # verbose logging to ~/Library/Logs/CallCatch.log
```

### Project layout

```
Sources/CallCatch/
  AppState.swift        finite state machine (lease, retries, bubbles)
  LucideIcons.swift     vendored Lucide glyphs + tiny SVG-path parser
  MicMonitor.swift      CoreAudio detection adapter
  PIDTracker.swift      per-app process ref-count + end-of-call debounce
  PlaudController.swift  Plaud adapter (deep link, log confirm, stop)
  PlaudAX.swift         Accessibility stop (widget hit-test + global click)
  PlaudLogTail.swift    checkpointed reader for Plaud's log
  UserIdExtractor.swift  user_id from Plaud logs
  WatchedApps.swift     the four apps + bundle-id matching
  BubbleWindow / MenuBar / Settings / Log / main
Tests/CallCatchTests/   80 unit tests (all logic behind protocols)
scripts/build-app.sh    build + sign + optional install
```

The logic (state machine, parsing, matching, debounce) is fully unit-tested
behind protocols; the thin OS adapters (CoreAudio, AppKit, Accessibility) are
verified by live testing.
