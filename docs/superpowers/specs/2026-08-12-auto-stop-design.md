# Auto-Stop — Design

**Date:** 2026-08-12
**Status:** Draft (pending review)
**Prototype:** [`docs/prototypes/liquid-glass-bubble.html`](../../prototypes/liquid-glass-bubble.html) v4.2 — `autoStop` state, approved by user after two design iterations and a UX-pattern research pass.

## Goal

Close the last manual step of the original mission ("забываешь остановить —
и два мита сливаются"): when a recording that **started automatically** ends
its call, CallCatch stops it automatically after a visible 10-second
countdown — with the human always able to stop sooner, keep recording, or
pause the countdown just by hovering.

## Non-goals

- No auto-stop for **manually started** recordings — the human pressed
  Record, the human decides when to stop (today's `callEndedOfferStop`
  bubble stays exactly as is for that path).
- No change to the stop *mechanism* (AX click, log verification) — only to
  *when* stop is initiated.
- No countdown text anywhere (session-settled: user-directed — rejected
  "Stopping in N s" label; the draining button IS the countdown).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Countdown affordance | The red **Stop Recording button drains** (fill shrinks left-to-right over the window); same row composition as `callEndedOfferStop` — zero extra width, zero extra text | (session-settled: user-directed after v4→v4.1 iteration). Research: established convention — Discord's reverse loading bar on undo toasts, Android Wear `CircularProgressLayout` ("circular countdown … to automatically confirm an operation"). |
| Window | **10 s** | Research consensus for undo windows is 5–10 s; 10 s recommended when the action doesn't block other work. (session-settled: user-approved) |
| Pause on hover | Cursor over the bubble **pauses** countdown + drain; leaving resumes | Repeated across UX guides up to "non-negotiable"; satisfies WCAG 2.2.1 (extend). One trigger must drive both the visual and the timer (prototype v4.2 caught the desync bug). (session-settled: research-directed, user-approved) |
| Controls | Click draining button = stop **now**; countdown expiry = stop; **✕ = keep recording** (cancel auto-stop, brief "Recording continues" notice, bubble hides; recording stays until stopped via menu/Plaud) | (session-settled: user-approved via prototype) |
| Scope | Only recordings started by **auto-record** | Symmetry of manual and automatic modes: automatic start → automatic stop; manual start → manual stop offer. (session-settled: user-approved) |
| Toggle | Menu item **"Auto-stop"**, default **on** | It only ever arms after an automatic start, so the default is safe; WCAG "turn off" level. |

## FSM changes (`AppState.swift` — all timing via the injected scheduler)

- Lease gains **`startedAutomatically: Bool`** — `true` when the start was
  initiated by the auto-record timer, `false` for `recordTapped`.
- New `BubbleState` cases:
  - `callEndedAutoStop(app: WatchedApp)` — the draining-button bubble;
  - `recordingContinues` — Notice shown briefly after "keep recording".
- On the existing debounced call-end path: if the lease is `.confirmed`,
  owned by this call, `startedAutomatically`, and `autoStopEnabled()` (new
  injected closure, mirroring `autoRecord`) → show `callEndedAutoStop` and
  schedule the **10 s auto-stop timer**; otherwise current behavior
  (`callEndedOfferStop`).
- Timer fires → exact `stopTapped()` path (same `stopInFlight` guard,
  same completion binding).
- **`autoStopHoverChanged(hovering: Bool)`** — new input from the bubble
  adapter: on `true` cancel the timer and remember remaining time; on
  `false` re-schedule the remainder. Idempotent (repeated same-value calls
  are no-ops).
- `stopTapped()` during countdown → cancel timer, normal stop.
- `dismissTapped()` during countdown → cancel timer, keep lease
  (recording continues), show `recordingContinues`, auto-hide it after
  ~1.7 s via scheduler.
- **Cancellation on world changes** (timer must never fire stale):
  - a **new call starts** while counting down → cancel auto-stop, keep
    recording (stopping would truncate the new call), show today's
    disabled `callDetected` bubble;
  - **external stop** detected (user stopped inside Plaud) or **Plaud
    quits** → existing lease-release paths also cancel the timer;
  - generation/lease guards: the timer callback re-checks it still owns a
    confirmed, auto-started lease before stopping.

## UI (`BubbleWindow.swift` + `MenuBar.swift`)

- `callEndedAutoStop` renders the Action template with the draining
  primary button: red fill (a `Capsule` overlay) shrinks `scaleX` 1→0,
  linear, over the remaining time; label "Stop Recording" unchanged; ✕
  present. Same paddings/fonts as `callEndedOfferStop` — **no width or
  typography change** (session-settled).
- `NSTrackingArea`/`onHover` on the bubble drives **one** callback that
  pauses/resumes BOTH the local drain animation and the FSM timer
  (single-trigger rule from prototype v4.2).
- `recordingContinues` renders the Notice template: pulsing disc,
  "Recording continues".
- Menu: checkable **"Auto-stop"** item under "Auto-record", tooltip:
  "When a recording started automatically, stop it 10 s after the call
  ends. Hover the bubble to pause the countdown." `Settings.autoStop`
  backed by UserDefaults with a **registered default of `true`**
  (`defaults.register`), unlike plain `bool(forKey:)` whose default is
  false.

## Touched files

`AppState.swift` (lease flag, two new states, timer + hover input),
`BubbleWindow.swift` (draining button, hover tracking, notice),
`MenuBar.swift` (toggle), `Settings.swift` (registered-default key),
`main.swift` (wire closure + hover callback; extend `--test-bubble` cycler
with the two new states), `Tests/` (new AppState tests), `README.md`,
`CHANGELOG.md`, `AGENTS.md` (test count).

## Testing / acceptance

- TDD in `AppStateTests` with `MockScheduler` (~10 new tests):
  auto-stop armed only for auto-started + enabled; fires stop at 10 s;
  hover pause preserves remaining time (pause at 4 s → resume → fires
  after 6 more); repeated hover events idempotent; manual stop during
  countdown cancels timer; dismiss keeps lease and shows
  `recordingContinues`; new call cancels; external stop / Plaud quit
  cancels; manual-start path still yields `callEndedOfferStop`; toggle
  off yields `callEndedOfferStop` even for auto-started.
- All existing 61 tests stay green (constructor gains one closure —
  existing tests pass `{ false }`).
- Live checks via extended `--test-bubble` cycler: drain animation runs
  10 s and fires; hover freezes fill + timer together; ✕ shows
  "Recording continues"; dark + light.
- Real hands-free check: auto-record on, real call, no clicks end-to-end.

## Risks

- **Timer vs animation drift:** FSM timer is authoritative; the view's
  drain is cosmetic and re-synced on pause/resume. Drift within a frame
  is invisible; the stop itself never depends on the animation.
- **Mute-releases-mic apps** (documented limitation): a long mute already
  looks like call end after the 5 s debounce — with auto-stop enabled
  this now stops the recording after 10 more seconds. Mitigations: the
  bubble is visible for those 10 s (hover/✕), and the feature only arms
  for auto-started recordings. Accepted; documented in README limitations.
- **Ship as MINOR (0.4.0)** after user acceptance.
