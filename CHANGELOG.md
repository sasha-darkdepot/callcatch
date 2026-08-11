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

## [Unreleased]

### Fixed / hardened (multi-angle review pass)
- Stop now sets `AXManualAccessibility` on Plaud's app element before hit-testing,
  so it works on a fresh machine where Electron's accessibility tree isn't
  already built.
- A `.confirmed` recording lease is released when Plaud quits/crashes (not only
  when it logs a stop), so it can't get stuck blocking all future recordings.
- Log tail survives file rotation/truncation (offset past EOF re-reads from 0),
  decodes lossily (one bad byte no longer blanks the buffer), treats `recordingId`
  as optional on the success line, and prefers a fatal rejection over an earlier
  `not_available`.
- AX stop candidates are PID-filtered to Plaud, deterministically ordered, capped,
  and re-scanned per attempt (no clicking stale coordinates or foreign windows).

### Changed (UX / convenience)
- Auto-record now checks the mic is *currently* held at the 7 s mark, so a short
  voice message that already ended no longer triggers a recording.
- Dismissing (✕) a call bubble cancels the pending auto-start.
- Stop failure shows a "stop it in Plaud manually" bubble instead of hiding silently.
- Menu shows a "needs attention" state when Accessibility isn't granted, a
  "Find user_id again" item (no relaunch needed), and Accessibility is requested
  proactively at launch. Bubble appears on the screen under the cursor.

### Security / robustness
- `user_id` is re-validated as 32-hex before building the `plaud://` URL.
- The debug log file is created `0600`; log writes are serialized across threads.
- `build-app.sh` picks the first Apple Development identity in the keychain
  (portable across machines with the same Apple ID).
