# English UI + Liquid Glass Redesign — Design

**Date:** 2026-08-12
**Status:** Draft (pending review)
**Prototype:** [`docs/prototypes/liquid-glass-bubble.html`](../../prototypes/liquid-glass-bubble.html) (approved by user, v2)

## Goals

1. Every user-visible string is English.
2. The bubble looks native to macOS 26/27 — real Liquid Glass (`glassEffect`),
   SF Symbols instead of emoji, glass buttons.
3. Simpler perceived UI: the bubble's content reduces to **4 templates**; the
   "why the button is disabled" reason moves out of the capsule into a small
   caption above it.

## Non-goals

- **No FSM or logic changes.** `BubbleState`, `AppState`, timings, the lease —
  untouched. All 57 unit tests must pass unmodified.
- No localization infrastructure (no `.strings`, no runtime language switch).
  One hardcoded English, personal app.
- No menu-bar visual work — `NSMenu` and `NSStatusItem` get system Liquid
  Glass automatically on macOS 26+.
- No `glassEffectID` morphing between states (deluxe variant rejected:
  requires rebuilding `BubbleWindow`'s show-cycle for a bubble that lives
  seconds on screen).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Minimum macOS | **26.0** (`Package.swift` → `.macOS("26.0")`, `LSMinimumSystemVersion` → `26.0`) | User runs macOS 27 on all machines and wants only the modern style; unconditional glass, zero `#available` branches. |
| CI runner | `macos-15` → **`macos-26`** | The glassEffect SwiftUI API needs the macOS 26 SDK; the macos-15 image's toolchain can't compile it. |
| Glass API | `GlassEffectContainer` + `.glassEffect(.regular.interactive(), in: .capsule)` | Verified to compile with the installed Xcode 26.6 SDK (probe, 2026-08-12). |
| Icons | SF Symbols with tints (no emoji) | Native look; emoji reads as legacy in a glass capsule. |

## String table (RU → EN)

### Menu bar (`MenuBar.swift`)

| Current | New |
|---|---|
| Найти user_id заново | Find user_id Again |
| Записать сейчас | Record Now |
| Остановить запись | Stop Recording |
| Авто-запись | Auto-record |
| Запускать при входе | Launch at Login |
| Выход | Quit |
| (tooltip) Запись стартует сама через 7 сек… | Recording starts automatically 7 s after a call begins. A voice message longer than 7 s will be recorded too. |

### Attention messages (`main.swift`)

| Current | New |
|---|---|
| user_id не найден: открой web.plaud.ai… | user_id not found: open web.plaud.ai, press Record, then "Find user_id Again" |
| Выдай доступ Accessibility в System Settings… | Grant Accessibility access in System Settings — needed to stop recordings |

### Disabled reasons (`AppState.swift`, string-only change)

| Current | New |
|---|---|
| Plaud уже пишет | Plaud is already recording |
| user_id не найден | user_id not found |

### Bubble (`BubbleWindow.swift`)

| State | Text | Buttons |
|---|---|---|
| callDetected | Call in \<App\> | **Record in Plaud**, ✕ |
| starting (both `launching` values) | Starting… | — |
| recordingStarted | Recording started | — |
| startFailed | Recording didn't start | Open Plaud, ✕ |
| callEndedOfferStop | Call in \<App\> ended | **Stop Recording**, ✕ |
| stopping | Stopping… | — |
| stopped | Recording stopped | — |
| stopFailed | Stop the recording in Plaud manually | Open Plaud, ✕ |

The `launching` flag of `.starting` stays in the enum (FSM untouched) but no
longer changes the UI string — one "Starting…" covers both.

## Bubble UI: 4 content templates

`BubbleView.body` becomes a mapping from `BubbleState` to one of four
templates (this *simplifies* the current 9-branch switch):

1. **Action** — tinted icon + text + prominent button + glass ✕.
   Used by: `callDetected` (Record in Plaud), `callEndedOfferStop`
   (Stop Recording). When `disabledReason != nil`: the button renders
   disabled and the reason appears as a **caption above the capsule** (small
   glass pill, `.caption` font, secondary color) — not inside the row.
2. **Progress** — spinner + text. Used by: `starting`, `stopping`.
3. **Notice** — tinted icon + text, no buttons; hides on the FSM's existing
   schedule. Used by: `recordingStarted`, `stopped`.
4. **Error** — warning icon + message + "Open Plaud" glass button + ✕.
   Used by: `startFailed`, `stopFailed`.

## Visual spec

- **Capsule:** `GlassEffectContainer` wrapping an `HStack`, background via
  `.glassEffect(.regular.interactive(), in: .capsule)`. Content padding
  ~11 pt vertical / 18 pt leading / 12 pt trailing, spacing 11 pt. Text
  13 pt medium, `.primary` color (glass supplies vibrancy).
- **Caption pill** (only with a disabled reason): separate small glass capsule
  stacked 8 pt above the main one inside the same `VStack`/container.
- **Primary button:** `.buttonStyle(.glassProminent)` + `.tint(.red)`.
- **Secondary button** (Open Plaud): `.buttonStyle(.glass)`.
- **Dismiss:** `xmark` SF Symbol in a circular glass button.
- **Icons (17 pt):** `phone.fill` green (call), `record.circle.fill` red with
  `.symbolEffect(.pulse)` (recording), `checkmark.circle.fill` green
  (ended/stopped), `exclamationmark.triangle.fill` yellow (errors).
- **Appear animation:** spring (scale 0.86→1, slight rise, fade) triggered
  `onAppear` — works with the existing rebuild-per-state show cycle.
- **Panel:** keep `.nonactivatingPanel`, `.fullScreenAuxiliary`,
  `sharingType = .none`, `.statusBar` level, screen-under-cursor placement.
  Try `hasShadow = false` (glass draws its own depth); revert after a live
  check if the capsule looks flat.

## Touched files

`BubbleWindow.swift` (rewrite `BubbleView`), `MenuBar.swift`, `main.swift`,
`AppState.swift` (two string literals only), `Package.swift`,
`scripts/build-app.sh` (`LSMinimumSystemVersion`), `.github/workflows/ci.yml`
(runner image), `README.md` / `AGENTS.md` (requirements, EN UI mention),
`CHANGELOG.md` (`[Unreleased]`).

## Testing

- `swift test` — all 57 tests pass **unmodified** (no logic change; nothing
  asserts UI strings — verified by grep).
- Live checks (adapter territory, not unit-testable): every template on dark
  and light wallpaper via the debug bubble mode (`CALLCATCH_DEBUG=1` +
  `--test-bubble`), glass rendering inside the borderless non-activating
  `NSPanel`, panel shadow on/off comparison.

## Risks

- **Glass in a borderless `NSPanel`:** `glassEffect` is designed for regular
  window backing; if `.interactive()` misbehaves in a non-activating panel,
  fall back to non-interactive `.regular` glass (visual-only downgrade).
- **CI image:** if the `macos-26` runner label is unavailable or its default
  Xcode lacks the SDK, pin Xcode explicitly (`xcode-select` step) — verify on
  first CI run.
- **Version bump semantics:** dropping macOS 14.4 support is a breaking
  requirement change → this ships as a **MINOR** bump (0.x rules per README).
