# CallCatch

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
- **Bubble UI**: a floating panel at the bottom of the screen — "Record in
  Plaud" when a call starts, "Stop recording" when it ends.
- **Starts recording** in Plaud via its `plaud://` deep link and confirms the
  start by reading Plaud's own log (with retries for a cold start).
- **Stops recording** by clicking Plaud's floating recording widget through
  the Accessibility API — reliably, in any window position and whether the
  widget is collapsed or expanded.
- **Menu bar controls**: manual record/stop, an auto-record toggle, launch at
  login, and a "needs attention" state when setup is incomplete.

## Requirements

- macOS 14.4 or newer (uses the CoreAudio process-objects API).
- The Plaud desktop app, installed and signed in.
- To build: Xcode / Swift 6 toolchain. An Apple Development signing identity
  is recommended (see [Signing](#signing-recommended)).

## Install

```bash
INSTALL=1 bash scripts/build-app.sh   # build, sign, install to /Applications
open "/Applications/Call Catch.app"
```

Without `INSTALL=1` the app is built to `build/Call Catch.app` and not copied.

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
- If Plaud releases the microphone on mute, a long mute can look like the end
  of a call (harmless — no automatic action is taken on call end).
- Verified against Plaud v1.3.7; a Plaud update may require re-checking the
  deep-link and stop behavior.

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
  MicMonitor.swift      CoreAudio detection adapter
  PIDTracker.swift      per-app process ref-count + end-of-call debounce
  PlaudController.swift  Plaud adapter (deep link, log confirm, stop)
  PlaudAX.swift         Accessibility stop (widget hit-test + global click)
  PlaudLogTail.swift    checkpointed reader for Plaud's log
  UserIdExtractor.swift  user_id from Plaud logs
  WatchedApps.swift     the four apps + bundle-id matching
  BubbleWindow / MenuBar / Settings / Log / main
Tests/CallCatchTests/   48 unit tests (all logic behind protocols)
scripts/build-app.sh    build + sign + optional install
```

The logic (state machine, parsing, matching, debounce) is fully unit-tested
behind protocols; the thin OS adapters (CoreAudio, AppKit, Accessibility) are
verified by live testing.
