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
| Window | **10 s, measured from the debounced call-end** — i.e. ~15 s wall-clock after the raw hang-up (the existing 5 s end-debounce runs first). All copy says "after CallCatch detects the call end" to keep the contract unambiguous (review finding, cross-model). | Research consensus for undo windows is 5–10 s; 10 s recommended when the action doesn't block other work. (session-settled: user-approved) |
| Pause on hover | Cursor over the bubble **pauses** countdown + drain; leaving resumes. Failsafes (review findings): pause only on a mouse-**entered** event that arrives after the bubble is shown (a cursor already parked inside the frame does not pause); while paused, the adapter re-checks the cursor position on a ~1 s tick and sends `hovering=false` if the cursor is gone — a missed `mouseExited` can never pause the countdown forever. | Repeated across UX guides up to "non-negotiable"; satisfies WCAG 2.2.1 (extend). One trigger must drive both the visual and the timer (prototype v4.2 caught the desync bug). (session-settled: research-directed, user-approved) |
| Controls | Click draining button = stop **now**; countdown expiry = stop; **✕ = keep recording** (cancel auto-stop, brief "Recording continues" notice, bubble hides; recording stays until stopped via menu/Plaud) | (session-settled: user-approved via prototype) |
| Scope | Only recordings started by **auto-record**; arming uses the **last-call-out invariant**: the countdown arms when a call ends leaving `activeCalls` empty (regardless of which app owns the lease), and never while any call is still active. If a superseding call cancels a countdown, it **re-arms when that call ends.** | Symmetry of modes (session-settled: user-approved). Owner-keyed arming breaks both ways on cross-app overlap — recording runs forever or gets cut mid-call (review finding, confirmed by two independent reviewers). |
| Toggle | Menu item **"Auto-stop"**, default **on**. Toggling **off during a live countdown** cancels the timer, keeps the lease, and swaps the bubble to plain `callEndedOfferStop`; the timer callback also re-checks `autoStopEnabled()` before stopping (review finding, cross-model corroborated). | Arms only after an automatic start; the visible 10 s bubble + hover + ✕ + toggle give four levels of control. Cross-model reviewer proposed default-off because of the mute false-positive — kept **on** as the user-settled hands-free preference for this single-user tool; the expanded mute risk below carries the full consequence. |

## FSM changes (`AppState.swift` — all timing via the injected scheduler)

- **Injected monotonic clock** — the scheduler alone can't measure "time
  already elapsed" (review finding: `Cancellable` has no elapsed query, and
  `MockScheduler` has no clock, so the pause-at-4s test would be
  inexpressible). Constructor gains a **defaulted** closure
  `now: () -> TimeInterval` (production: `ProcessInfo.systemUptime`); the
  countdown records its arm timestamp and computes exact remainders.
  Defaulting keeps existing tests source-compatible.
- Lease gains **`startedAutomatically: Bool`** — `true` when the start was
  initiated by the auto-record timer, `false` for `recordTapped`.
- **Countdown is one optional value** — `autoStopCountdown:
  (timer: Cancellable?, armedAt: TimeInterval, remaining: TimeInterval)?`
  or equivalent. Every cancellation path **nils the whole thing**, including
  a hover-paused remainder; `autoStopHoverChanged(false)` re-schedules only
  when a countdown is armed (review finding: otherwise unhover after a
  new-call cancellation revives a stale countdown and truncates the new
  call).
- New `BubbleState` cases:
  - `callEndedAutoStop(app: WatchedApp)` — the draining-button bubble;
  - `recordingContinues` — Notice shown briefly after "keep recording".
- **Arming (last-call-out invariant):** on any debounced call-end, if
  `activeCalls` is now empty AND the lease is `.confirmed` with
  `startedAutomatically` AND `autoStopEnabled()` (new injected closure,
  mirroring `autoRecord`) → show `callEndedAutoStop` (app = lease owner)
  and arm the 10 s countdown. Owner identity does NOT gate arming. If
  calls remain active → no countdown. Otherwise current behavior
  (`callEndedOfferStop` for manual starts / toggle off).
- **Timer fires** → re-check: countdown still armed, lease still confirmed
  + auto-started, `autoStopEnabled()` still true (toggle re-check), and
  **`pollRecordingStopped()` first** — if the user already stopped inside
  Plaud in the final second, release the lease instead of AX-clicking a
  dead widget (review finding). Then the exact `stopTapped()` path (same
  `stopInFlight` guard, same completion binding).
- **Unattended failure retry:** when a countdown-initiated stop's AX click
  reports failure, schedule **one automatic retry (~5 s)** via the
  scheduler before falling back to the attended `stopFailed` flow (raise
  Plaud + bubble) — the human this flow expects may not be at the desk
  (review finding).
- **`autoStopHoverChanged(hovering: Bool)`** — on `true` cancel the timer
  and store the exact remainder (via `now()`); on `false` re-schedule the
  remainder **iff armed**. Idempotent for repeated same-value calls.
- `stopTapped()` during countdown → cancel countdown, normal stop.
- `dismissTapped()` during countdown → cancel countdown, keep lease,
  show `recordingContinues`, auto-hide after ~1.7 s via scheduler — the
  hide callback is generation-guarded: it hides only if the bubble is
  still this `recordingContinues` instance (review finding: otherwise it
  can swallow a newer bubble that replaced the notice).
- **Cancellation on world changes** (each nils the whole countdown):
  - a **new call starts** → cancel, keep recording (stopping would
    truncate the new call), show today's disabled `callDetected` bubble;
    countdown **re-arms** when that call ends (last-call-out);
  - **external stop** (user stopped inside Plaud) or **Plaud quits** →
    lease-release paths cancel the countdown AND hide the
    `callEndedAutoStop` bubble (extend the existing `tickPollStart` hide,
    which today only knows `callEndedOfferStop` — review finding);
  - toggle off (see Decisions) → cancel, swap bubble to
    `callEndedOfferStop`.

## UI (`BubbleWindow.swift` + `MenuBar.swift`)

- `callEndedAutoStop` renders the Action template with the draining
  primary button: red fill (a `Capsule` overlay) shrinks `scaleX` 1→0,
  linear, over the remaining time; label "Stop Recording" unchanged; ✕
  present. Same paddings/fonts as `callEndedOfferStop` — **no width or
  typography change** (session-settled). Note: SwiftUI can't suspend a
  running animation mid-flight — the view keeps its own progress
  bookkeeping (store the fraction on pause, restart a linear animation
  over the remainder on resume). Cosmetic only; the FSM timer is
  authoritative.
- Hover trigger: **AppKit `NSTrackingArea` with `.activeAlways`** on the
  panel's content view (committed — SwiftUI `onHover` tracking can be
  activation-dependent, and this panel is non-activating in an
  always-inactive accessory app; review finding). It drives **one**
  callback that pauses/resumes BOTH the local drain animation and the FSM
  timer (single-trigger rule from prototype v4.2), plus the paused-state
  ~1 s cursor recheck from Decisions.
- `recordingContinues` renders the Notice template: pulsing disc,
  "Recording continues". `BubbleView.trailingPadding` adds
  `.recordingContinues` to the 18 pt text-row case alongside
  `.recordingStarted`/`.stopped` (review finding — it's a text-only row).
- Menu: checkable **"Auto-stop"** item under "Auto-record", tooltip:
  "When a recording started automatically, stop it 10 s after CallCatch
  detects the call end. Hover the bubble to pause the countdown."
  `Settings.autoStop` backed by UserDefaults with a **registered default
  of `true`** (`defaults.register`), unlike plain `bool(forKey:)` whose
  default is false. `Settings` gains an injectable `UserDefaults`
  (default `.standard`) so the registered-default + toggle roundtrip is
  unit-testable against a throwaway suite (review finding, cross-model:
  the production wiring must be covered, not just the FSM branch).

## Touched files

`AppState.swift` (lease flag, two new states, timer + hover input),
`BubbleWindow.swift` (draining button, hover tracking, notice),
`MenuBar.swift` (toggle), `Settings.swift` (registered-default key),
`main.swift` (wire closure + hover callback; extend `--test-bubble` cycler
with the two new states), `Tests/` (new AppState tests), `README.md`,
`CHANGELOG.md`, `AGENTS.md` (test count).

## Testing / acceptance

- TDD in `AppStateTests` with `MockScheduler` **+ a mutable mock clock**
  (~16 new tests):
  auto-stop armed only for auto-started + enabled; fires stop at 10 s;
  hover pause preserves remaining time (mock clock at 4 s → resume →
  fires after 6 more); repeated hover events idempotent; **unhover after a
  cancellation is a no-op** (hover → new call cancels → unhover → fire
  all timers → no stop); **cross-app re-arm** (discord auto-recording,
  telegram call overlaps countdown and cancels it, telegram ends →
  countdown re-arms and stops); **A ends while B active → no countdown
  until B ends**; manual stop during countdown cancels; dismiss keeps
  lease + shows `recordingContinues`; notice hide is generation-guarded
  (newer bubble not swallowed); external stop / Plaud quit cancels AND
  hides the auto-stop bubble; **already-stopped-in-Plaud at fire time →
  release, no AX click**; **timer-initiated AX failure → one 5 s retry
  before `stopFailed`**; manual-start path still yields
  `callEndedOfferStop`; toggle off before arming yields
  `callEndedOfferStop`; **toggle off during countdown cancels and swaps
  the bubble**.
- `SettingsTests` (new): against a throwaway `UserDefaults` suite —
  registered default is `true`, toggle roundtrip persists.
- All existing 61 tests stay green (new constructor closures are
  defaulted).
- Live checks: the `--test-bubble` cycler is **visual-only** (it bypasses
  the FSM — review finding): it gets a longer dwell (~15 s) on
  `callEndedAutoStop` to watch a full drain, plus `recordingContinues`;
  verify hover freezes the fill, dark + light. FSM timing correctness is
  the unit tests' job; the **authoritative end-to-end check is a real
  hands-free call**: auto-record on, real call, no clicks — recording
  starts, call ends, drain runs, stop fires, Plaud log confirms.

## Risks

- **Timer vs animation drift:** FSM timer is authoritative; the view's
  drain is cosmetic and re-synced on pause/resume. Drift within a frame
  is invisible; the stop itself never depends on the animation.
- **Mute-releases-mic apps** (documented limitation) — full consequence
  (review finding, cross-model): a long mute reads as call end after the
  5 s debounce; auto-stop then stops the recording ~10 s later, and when
  the user unmutes, the mic re-acquisition looks like a new call — so
  auto-record starts a **second** recording. End state: one meeting split
  into two files with the muted stretch missing. Remedy: the visible 10 s
  bubble (hover/✕) in the moment, and the Auto-stop toggle for affected
  apps. The cross-model reviewer proposed default-off because of this;
  kept default-on as the user's settled hands-free preference — accepted
  risk. README's current line "harmless — no automatic action is taken on
  call end" is **retracted and rewritten**, not appended to.
- **Unattended AX-stop failure**: if the click fails twice (initial +
  retry), the recording keeps running and the attended `stopFailed` flow
  (raise Plaud + bubble) waits for a human; the existing AX watch
  eventually releases the lease without stopping anything. Accepted
  residual — same exposure as today's manual flow, now documented.
- **Ship as MINOR (0.4.0)** after user acceptance.
