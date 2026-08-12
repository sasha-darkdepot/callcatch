# Changelog

All notable changes to CallCatch are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); the project
follows [Semantic Versioning](https://semver.org). Newest first.

New changes accumulate under **[Unreleased]**; `scripts/release.sh X.Y.Z` rolls
them into a dated, tagged version (see "Versioning & releases" in the README).

## [Unreleased]

_Nothing yet._

## [0.4.0] — 2026-08-12

### Added
- **Auto-stop**: a recording that started automatically now stops itself
  10 s after CallCatch detects the call end. The bubble's red button drains
  as the countdown — click stops now, hovering pauses (a cursor parked
  motionless for 30 s counts as absent and the countdown resumes), ✕ keeps
  recording for good ("Recording continues"; later calls don't override the
  choice). Arms only when the last active call ends (cross-app overlaps
  re-arm correctly); external stops, new calls, an in-flight stop, and
  toggling the feature off all cancel it; an unattended stop failure gets
  one silent retry before the manual fallback. Menu toggle "Auto-stop", on
  by default.

### Fixed / hardened (six-expert review pass: 5× Opus 5 + GPT-5.6-sol)
- Race fixes around in-flight AX stops: the countdown never arms over a stop
  in progress; a failed unattended stop never retries into a new call; a
  stop finishing externally mid-retry no longer strands the "Stopping…"
  bubble.
- A start confirmed after its call already ended is reconciled (auto-stop or
  stop offer) instead of becoming an orphan recording nobody tracks.
- The AX fallback watch is bound to its own recording and can no longer
  release a newer recording's lease.
- Single-instance guard (a second copy exits instead of double-clicking
  Plaud); synthetic HID clicks strip physically held modifier keys.
- The `plaud://` deep link (carrying user_id) is sent to Plaud directly, not
  to whatever app owns the URL scheme; stop-detection log polling is now
  incremental instead of re-reading the growing log tail every second.
- Unit tests no longer pollute `~/Library/Logs/CallCatch.log`; the log
  fallback path can't truncate the file or drop its 0600 permissions;
  `--test-bubble` screen-capture visibility now also requires
  `CALLCATCH_DEBUG=1`.
- `release.sh` refuses untracked files and builds before tagging;
  `build-app.sh` installs atomically and stamps the toolchain.

### Changed
- The mute limitation is now consequential: a long mute in a
  mic-releasing app can split one meeting into two recordings (README
  Limitations rewritten accordingly).

## [0.3.0] — 2026-08-12

### Changed
- Entire UI is now English (menu, bubble, attention messages).
- Bubble redesigned as native Liquid Glass per the macOS 27 standard:
  AppKit `NSGlassEffectView` capsule (`.regular`, respects the system
  transparency slider, interactive bounce on macOS 27) — SwiftUI's
  `glassEffect` degrades in unfocused apps and an accessory app is unfocused
  always. 4 content templates, Lucide icons (vendored as path code), solid
  buttons (no glass-on-glass), panel-level entrance animation; disabled-reason
  moved to a caption pill above the capsule; "Starting Plaud…" kept as the
  cold-start cue.
- Menu attention item uses an SF Symbol image instead of the "⚠️" prefix.
- `--test-bubble` (debug) now cycles every visible bubble state, bypassing the
  FSM, and makes the bubble visible to screen capture for visual checks.

### Breaking
- Minimum macOS raised from 14.4 to 26.0; CI moved to the macos-26 image.

## [0.2.0] — 2026-08-12

Multi-angle review pass: reliability, portability, UX, and security hardening.

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
