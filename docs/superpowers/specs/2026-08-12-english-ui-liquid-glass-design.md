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
| Minimum macOS | **26.0** (`Package.swift` → `.macOS("26.0")`, `LSMinimumSystemVersion` → `26.0`) | User runs macOS 27 on all machines and wants only the modern style; unconditional glass, zero `#available` branches. (session-settled: user-directed — rejected the availability-gated 14.4 fallback) |
| CI runner | `macos-15` → **`macos-26`** | The glassEffect SwiftUI API needs the macOS 26 SDK; the macos-15 image's toolchain can't compile it. (session-settled: user-approved — workflow edits are ASK-FIRST per AGENTS.md; asked and approved) |
| Redesign depth | Full native glass restyle ("option B") | (session-settled: user-approved — rejected minimal material swap (A) and `glassEffectID` morphing deluxe (C)) |
| Disabled reason placement | Caption pill **above** the capsule, not inline | Inline reason overloads the row. (session-settled: user-directed — rejected inline reason text) |
| UI state simplification | 4 content templates over per-state bespoke layouts | "Чем проще тем вернее." (session-settled: user-directed) |
| Glass API | `GlassEffectContainer` + `.glassEffect(.regular.interactive(), in: .capsule)` | Verified to compile with the installed Xcode 26.6 SDK (probe, 2026-08-12). |
| Bubble icons | **Lucide** icons with tints (no emoji, no SF Symbols in the bubble) | User preference. Vendored as hand-ported SwiftUI `Path` code in `LucideIcons.swift` — no package dependency (zero-deps principle holds), no SwiftPM resource bundle (build-app.sh keeps copying a bare binary). Lucide is ISC-licensed; attribution line goes in README. (session-settled: user-directed — rejected SF Symbols) |

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
| (attention item) "⚠️ \<msg\>" title prefix | Title is the message alone; the item gets `exclamationmark.triangle.fill` as its `image` — removes the app's last emoji. |

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
| starting, `launching == true` | Starting Plaud… | — |
| starting, `launching == false` | Starting… | — |
| recordingStarted | Recording started | — |
| startFailed | Recording didn't start | Open Plaud, ✕ |
| callEndedOfferStop | Call in \<App\> ended | **Stop Recording**, ✕ |
| stopping | Stopping… | — |
| stopped | Recording stopped | — |
| stopFailed | Stop the recording in Plaud manually | Open Plaud, ✕ |

The `launching` flag of `.starting` stays in the enum (FSM untouched) and
keeps its own string: a Plaud cold start retries for up to 60 s, and
"Starting Plaud…" is the cue that explains the wait (review finding — merging
the strings saved nothing structurally; both render the same Progress
template).

`<App>` is `WatchedApp.displayName` — hardcoded Latin names (Discord, Signal,
Telegram, WhatsApp) — so the English-only goal holds for dynamic content too.

## Bubble UI: 4 content templates

`BubbleView.body` becomes a mapping from `BubbleState` to one of four
templates (this *simplifies* the current 9-branch switch):

1. **Action** — tinted icon + text + prominent button + glass ✕.
   Used by: `callDetected` (Record in Plaud), `callEndedOfferStop`
   (Stop Recording). When `disabledReason != nil`: the button renders
   disabled and the reason appears as a **caption above the capsule** (small
   glass pill, `.caption` font, secondary color) — not inside the row. The
   caption supersedes the old `.help(disabledReason)` hover tooltip, which is
   dropped in the rewrite.
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
  stacked 8 pt above the main one inside the same `VStack`/container. If
  `GlassEffectContainer` visually fuses the pill with the capsule, set the
  container spacing explicitly. The pill animates together with the capsule
  (the appear animation lives on the outer container).
- **Primary button:** `.buttonStyle(.glassProminent)` + `.tint(.red)`.
- **Secondary button** (Open Plaud): `.buttonStyle(.glass)`.
- **Dismiss:** Lucide `x` glyph in a circular glass button.
- **Icons (17 pt, Lucide, 2 pt stroke, round caps):** explicit state mapping —
  `phone` green (callDetected), `disc` red with a pulse (recordingStarted),
  `circle-check` green (callEndedOfferStop, stopped), `triangle-alert` yellow
  (startFailed, stopFailed). Hand-ported as SwiftUI `Path` code in a new
  `LucideIcons.swift`; the pulse is a plain repeating SwiftUI opacity/scale
  animation (`symbolEffect` is SF-Symbols-only and does not apply).
- **Menu-bar status item keeps SF Symbols** (`waveform`, `phone.fill`,
  `record.circle.fill`, `exclamationmark.triangle.fill`) — template glyphs in
  the system status bar follow the platform convention; Lucide applies to the
  bubble only.
- **Appear animation:** spring (scale 0.86→1, slight rise, fade) — runs only
  on the **hidden→visible** transition: `BubbleWindow.show` passes an
  `isNewAppearance` flag (panel was not previously visible) into `BubbleView`,
  and the spring fires only when it's true. Without the gate the
  rebuild-per-state show cycle replays the entrance on every content swap
  (review finding).
- **Animation headroom:** the panel is sized exactly to `fittingSize`, so the
  root view gets a transparent ~12 pt outer margin (panel origin shifted down
  by the same amount to keep the on-screen position) — otherwise the rise/scale
  clips at the panel edge (review finding).
- **Panel:** keep `.nonactivatingPanel`, `.fullScreenAuxiliary`,
  `sharingType = .none`, `.statusBar` level, screen-under-cursor placement.
  Try `hasShadow = false` (glass draws its own depth); revert after a live
  check if the capsule looks flat.

## Touched files

`BubbleWindow.swift` (rewrite `BubbleView`), `LucideIcons.swift` (new — vendored
Lucide `Path` glyphs), `MenuBar.swift`, `main.swift`, `AppState.swift` (two
string literals only), `Package.swift`, `scripts/build-app.sh`
(`LSMinimumSystemVersion`), `.github/workflows/ci.yml` (runner image),
`README.md` / `AGENTS.md` (requirements, EN UI mention, Lucide ISC
attribution), `CHANGELOG.md` (`[Unreleased]`).

## Testing / acceptance

- `swift test` — all 57 tests pass **unmodified** (no logic change; nothing
  asserts UI strings — verified by grep).
- **Debug state cycler** (prerequisite for everything below): extend the
  `CALLCATCH_DEBUG=1` + `--test-bubble` hook to drive `BubbleWindow.show(state:)`
  directly through **all eight visible `BubbleState`s** on a timer — including
  a `callDetected` with a non-nil `disabledReason` — bypassing the FSM
  (adapter-only change). Today the hook only simulates one call and cannot
  reach the Error/Notice templates or the caption pill at all (review finding,
  confirmed cross-model).
- **Visual checks**, dark and light wallpaper: all four templates render as
  glass (not an opaque fallback); enabled Action shows **no** caption;
  disabled Action shows the caption **above** the capsule and not inside the
  row, with the button disabled; entrance animation plays once on appear and
  does not replay on state swaps; nothing clips during the spring.
- **Interaction checks** (the rewrite must not silently drop closures): click
  Record in Plaud / Stop Recording / Open Plaud / ✕ — each fires its existing
  callback; a disabled button does nothing; clicking glass buttons does not
  activate/focus-steal from the call app; hide timings and lease behavior
  unchanged.
- **English acceptance:** `grep -n '[А-Яа-яЁё]' Sources/CallCatch/*.swift`
  returns code comments only — zero user-visible Cyrillic.
- **Packaging smoke:** `bash scripts/build-app.sh` succeeds and the built
  `Info.plist` carries `LSMinimumSystemVersion` `26.0`; the first CI run on
  the `macos-26` image must pass before release.

## Risks

- **Glass in a borderless `NSPanel`:** `glassEffect` is designed for regular
  window backing, and nested glass (`.glassProminent` buttons inside the
  capsule's own `glassEffect`) is compile-verified only. Pass criteria for
  keeping `.interactive()`: hover/press effects render AND clicks don't
  activate the app. If either fails, fall back to non-interactive `.regular`
  glass (visual-only downgrade). Shadow: compare `hasShadow` on/off — pass is
  "capsule reads as elevated, no double shadow"; record the chosen setting
  here after the live check.
- **CI image:** if the `macos-26` runner label is unavailable or its default
  Xcode lacks the SDK, pin Xcode explicitly (`xcode-select` step) — verify on
  first CI run.
- **Version bump semantics:** dropping macOS 14.4 support is a breaking
  requirement change → this ships as a **MINOR** bump (0.x rules per README).
