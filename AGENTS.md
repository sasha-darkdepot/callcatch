# AGENTS.md

Guidance for AI coding agents working on **CallCatch**. Human-facing docs live
in [README.md](README.md); this file carries the operational context and the
non-obvious institutional knowledge an agent needs.

## Mission

CallCatch is a personal macOS **menu-bar utility** (Swift 6, SwiftPM, zero
third-party dependencies). It detects calls in Discord/Signal/Telegram/WhatsApp
by watching per-process microphone use, then starts and stops a recording in
the separate **Plaud** desktop app. It is glue around another app's private
behavior, so its correctness depends on empirically-verified assumptions about
Plaud (see Gotchas). Verified against **Plaud v1.3.7, macOS 26+**.

## Commands

```bash
swift test                                    # 80 unit tests — run before declaring work done
swift test --filter AppStateTests/testFoo     # a single test
swift build                                   # debug build
INSTALL=1 bash scripts/build-app.sh           # signed .app → /Applications/Call Catch.app
bash scripts/build-app.sh                     # build only → build/CallCatch.app
CALLCATCH_DEBUG=1 …                            # verbose logging to ~/Library/Logs/CallCatch.log
```

There is no linter/formatter in this repo; match the style of surrounding code.

## Architecture

The design deliberately isolates **pure, testable logic behind protocols** from
**thin OS adapters**. All logic is unit-tested; adapters are verified by live
testing only. Preserve this split — put testable decisions in the FSM, keep OS
calls in adapters.

- `AppState.swift` — the finite state machine (call sessions, single-recording
  **lease**, retries, bubble states). All timing is via an **injected scheduler
  closure**, so tests drive time with `MockScheduler` (no real sleeps). Any new
  time-based behavior must go through that closure.
- `PlaudControlling` / `AppStateDelegate` protocols are the seams — new logic is
  tested against `MockPlaud` / `MockScheduler` in `Tests/`.
- Adapters (not unit-tested): `MicMonitor` (CoreAudio), `PlaudAX` (Accessibility
  stop), `PlaudController`, `BubbleWindow`, `MenuBar`, `Settings`, `Log`, `main`.

## Gotchas (institutional knowledge — verify before changing)

These are hard-won and non-obvious. Do not "simplify" them away without
re-verifying against live Plaud.

- **Plaud has no programmatic stop.** No deep link, no local server, no hotkey.
  Stop is a synthetic click on Plaud's recording widget (see below).
- **Stopping the recording** (`PlaudAX.swift`): the widget is a floating panel
  (window layer > 25) that **`AXWindows` does not enumerate**. Find it via
  `CGWindowList` + `AXUIElementCopyElementAtPosition` hit-test. Electron only
  builds its a11y tree once an AT asks, so **set `AXManualAccessibility=true` on
  Plaud's app element first** or the hit-test finds nothing on a fresh machine.
  **`AXPress` and background `CGEventPostToPid` are no-ops on Electron web
  content** (they return success and do nothing) — click with a **global HID
  `CGEvent`** at the button's live screen center. Candidates are PID-filtered to
  Plaud and re-scanned per attempt; success is confirmed by tailing Plaud's log
  for `stopRecording by scene`.
- **Starting** relies on the `plaud://record?auto=1&user_id=…` deep link; cold
  start is silently rejected (`reason=not_available`) until Plaud's profile
  loads, so start is **retried** and confirmed via Plaud's log, never assumed.
- **Detection** uses CoreAudio process objects **plus a 3 s polling fallback** —
  the `IsRunningInput` listener does not fire for every app. Don't drop the poll.
- Permissions survive rebuilds only because the app is **code-signed with a
  stable identity**; ad-hoc signing resets Accessibility on every build.
- **UI strings are English** and the bubble is Liquid Glass (macOS 26
  `glassEffect`, Lucide icons vendored in `LucideIcons.swift`) — the platform
  floor is 26.0; don't reintroduce `#available` shims for older macOS.

## Boundaries

**ALWAYS**
- Run `swift test` before declaring work complete; add/adjust tests for logic you change.
- Route new time-based behavior through the injected scheduler closure so it stays testable.
- Keep OS calls in adapters and testable decisions in `AppState`.

**ASK FIRST**
- Changing the Plaud stop/start mechanism, or claiming a Plaud behavior changed
  (re-verify against live Plaud v1.3.7 first — these assumptions are load-bearing).
- Adding any third-party dependency (currently zero — a deliberate choice).
- Editing `scripts/build-app.sh` signing logic or `.github/workflows/`.

**NEVER**
- Commit a real Plaud `user_id`, Plaud logs, or any secret. Tests use dummy
  32-char hex ids (`0123…`, `aabb…`); keep it that way.
- Weaken a Gotcha above to make code "cleaner" without re-verifying live.

## Orientation

| Topic | Where |
|---|---|
| Human setup, usage, how-it-works | [README.md](README.md) |
| Design rationale & decisions | [`docs/superpowers/specs/`](docs/superpowers/specs/) |
| Implementation plan (TDD tasks) | [`docs/superpowers/plans/`](docs/superpowers/plans/) |
| Release notes | [CHANGELOG.md](CHANGELOG.md) |
| CI (build + test on macOS) | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |

## Releasing

Version is git-derived (SemVer): `build-app.sh` reads the marketing version from
the latest `vX.Y.Z` tag and the build number from the commit count — nothing is
hardcoded. **The one sanctioned way to release is `scripts/release.sh X.Y.Z`**:
it runs tests, rolls CHANGELOG `[Unreleased] → [X.Y.Z]`, commits, tags, pushes,
and installs the stamped build (refusing on a dirty/out-of-sync tree or a
non-increasing version). Don't hand-tag or hand-edit the version — use the
script so the version story can't drift. Accumulate changes under
`## [Unreleased]` in CHANGELOG as you work.
