# Changelog

All notable changes to CallCatch are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] — 2026-08-11

First working version.

### Added
- Call detection for Discord, Signal, Telegram (both builds) and WhatsApp
  via the CoreAudio process-objects API (per-process microphone usage),
  with a 3-second polling fallback for apps whose input-state listener
  does not fire.
- Floating bubble at the bottom of the screen offering to start a Plaud
  recording, plus an end-of-call bubble offering to stop it.
- Recording start via the `plaud://record?auto=1&user_id=…` deep link,
  confirmed by tailing Plaud's log, with retries for cold start.
- Reliable recording stop: locate Plaud's floating recording widget via
  `CGWindowList` + Accessibility hit-test and click the stop button with a
  global HID event, verified against Plaud's log. Works whether the widget
  is collapsed or expanded, at any screen position.
- Menu-bar UI: status icon, "Record now", "Stop recording", auto-record
  toggle, launch-at-login, and a "needs attention" state.
- Single-recording lease bound to the owning call session; external stops
  (done inside Plaud) reconcile automatically.
- `user_id` auto-extraction from Plaud logs.
- Signed builds with an Apple Development identity so Accessibility and
  microphone permissions survive rebuilds.

### Known limitations
- Auto-record starts 7 s after a call begins; voice messages longer than
  7 s will also be recorded.
- The stop click briefly moves the cursor to the recording widget (the only
  method Electron web content reliably accepts).
- Verified against Plaud v1.3.7.
