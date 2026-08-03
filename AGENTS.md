# StandUp — agent guide

A macOS menu-bar app (SwiftUI, macOS 14+) that nudges you to sit/stand and can drive a LINAK desk over Bluetooth. The LINAK driver is validated on real hardware (DPG handshake, jog, sit/stand presets).

## Build tooling

- This repo uses **xcodegen** (`brew install xcodegen`). `project.yml` is the source of truth — it declares both targets (`StandUp` app, `StandUpTests`) and the shared `StandUp` scheme. `StandUp.xcodeproj/` is generated and committed (including `xcshareddata/xcschemes/StandUp.xcscheme`). **Do not hand-edit the `.xcodeproj`.**
- After adding/removing/moving source files, run `xcodegen generate` from the repo root and commit both the changed `project.yml` (if any) and the regenerated `StandUp.xcodeproj/`.
- Full **Xcode is required** to build/run (Command Line Tools alone cannot build a SwiftUI `.app`). `swiftc -typecheck` may fail in CI if only CLT is installed and the CLT license hasn't been accepted — that's an environment problem, not a code problem.
- CLI works on a fresh checkout (the shared scheme is committed):
  - Build: `xcodebuild -project StandUp.xcodeproj -scheme StandUp build`
  - Test: `xcodebuild -project StandUp.xcodeproj -scheme StandUp test`

## Architecture

- `AppState` (`@MainActor`, `ObservableObject`) is the single source of truth. It owns `TimerSettings`, `DeskSettings`, a `PostureTimer`, `NotificationManager`, and an optional `DeskController`. It persists settings to `UserDefaults`.
- `PostureTimer` is a classic `Timer`-based 1s ticker. On interval completion it flips posture and posts `PostureTimer.Static.tickCompleteNotification`; `AppState` observes that (set up in `AppState.init`) and fires a user notification + optional desk move. A second notification (`warningNotification`) fires `warningLeadTime` seconds before completion to warn about an impending auto-move.
- The desk layer is behind the `DeskController` protocol. The sole implementation is `LinakDeskController` (CoreBluetooth). **Do not** put BLE code anywhere outside `StandUp/Desk/Linak/`.
- `MenuBarExtra` popover shows the timer + controls. The app is `LSUIElement` (menu-bar only, no Dock icon).
- Settings is NOT a SwiftUI `Settings` scene. SwiftUI scenes don't work reliably for `LSUIElement` apps (window never gets focus / doesn't reopen). Instead `SettingsWindowController` (`StandUp/Settings/`) owns a single `NSWindow` (kept alive via `isReleasedWhenClosed = false`) hosting `SettingsView`, toggling `NSApp.setActivationPolicy(.regular)` while open and back to `.accessory` on `windowWillClose`. Open via `SettingsWindowController.shared.open(appState:)`. Do not reintroduce a `Settings`/`WindowGroup` scene for this.
- The settings UI persists the desk address on every keystroke. `AppState.updateDeskSettings` therefore only reconnects when the address changes to an empty value (auto-scan) or a **complete valid UUID** — partial input is persisted but must not tear down the BLE connection. Keep that guard.

## Testing

- `StandUpTests/` holds XCTest unit tests for the pure logic (`LinakGATT` byte packing, settings models, `PostureTimer` state machine). No third-party test dependencies; the test bundle is app-hosted (`TEST_HOST` is set automatically by xcodegen).
- Timer tests use `expectation(forNotification:)` + `wait(for:)` so the main run loop keeps spinning the 1s `Timer`.
- Keep `xcodebuild -project StandUp.xcodeproj -scheme StandUp test` green.

## LINAK protocol notes

`StandUp/Desk/Linak/` is a native Swift port of [`rhyst/linak-controller`](https://github.com/rhyst/linak-controller) (Python/bleak). The reference files live in that upstream repo (they are not vendored here) — keep them in mind when changing the byte layout:
- `linak_controller/gatt.py` — UUIDs + `encode_height`/`decode_height_speed` (struct `<H` height, `<Hh` height+speed, little-endian).
- `linak_controller/desk.py` — the move loop: `wakeup`, `stop`, then repeatedly write Reference Input until Reference Output speed == 0.

The native `moveTo` extends the reference move loop with key correctness fixes (keep them): an in-flight move is **retargeted, never cancelled** — a second preset click while the desk is moving just updates the shared `moveTargetInternal` that the running loop reads each iteration, so the desk decelerates and reverses on its own. **Never send `stop` while the desk is moving**: stop-during-motion latches the desk into ignoring Reference Input until a Control command (`moveUp`/`moveDown`) arrives — the observed symptom was a halted desk, a stuck movement indicator, and apparently dead buttons until a jog press. `wakeup` + `stop` are only written when starting a move from idle. The loop terminates only when **speed == 0 AND height is within ~0.5 mm of the current target** (confirmed twice to ride out notification jitter), resets its stall/reach counters on every retarget, and keeps a stalled guard (~4 s of zero speed while far from target) plus the ~60 s `maxIters` cap. Jog (`jogUp`/`jogDown`) and `stop()` still cancel any in-flight `moveTask`.

Height semantics: on-wire value is **tenths of a mm relative to base height**; UI values are **absolute mm above floor**. The base offset is read from the desk during the DPG handshake; the same absolute mm number is used for the displayed height, sit/stand presets, and `moveTo` conversion (`resolvedBaseMm`, `lastHumanHeightMm`). Control commands (`wakeup`/`stop`/`moveUp`/`moveDown`) are written as **two bytes** `[cmd, 0]` with `stop = 255`.

**DPG init handshake** (capabilities, set user-id byte to 1, read base offset) is implemented in `LinakDeskController.performDPGHandshake`, run after all characteristics are discovered and before surfacing `.connected`. Jog (`jogUp`/`jogDown`) repeats `moveUp`/`moveDown` every ~300ms while held (a single command is only a ~12mm nudge) and sends `stop` on release.

The pending DPG response continuation is held in `DPGContinuationBox` (a small `@unchecked Sendable` box) so the response-timeout closure captures the box instead of the non-Sendable controller — keep it that way to stay warning-free under strict concurrency.

**Reconnect & wake recovery.** The controller auto-recovers the link instead of leaving the UI stuck at "Bluetooth is powered off" (the classic symptom after the Mac sleeps). Keep these invariants when touching `LinakDeskController`:
- `centralManagerDidUpdateState(.poweredOn)` calls `reconnectIfNeeded()` (no `peripheral == nil` guard) — it must reconnect whenever not already connected/connecting/scanning. `.poweredOff`/`.unauthorized`/`.unsupported` must call `resetLinkState()` before surfacing the error so a later `.poweredOn` re-runs the full DPG handshake from scratch.
- `didDisconnectPeripheral`/`didFailToConnect` call `resetLinkState()` + `scheduleReconnect()` (exponential backoff, 2 s → 30 s cap, unbounded retries) — they are the source of automatic link-drop recovery. `reconnectAttempts` resets to 0 only on a successful `.connected` (in `didDiscoverCharacteristicsFor`).
- `disconnect()` (teardown on disable) sets `isTearingDown = true` and the disconnect/fail callbacks `guard !isTearingDown` so they don't schedule a reconnect for a controller the user just disabled. Don't remove that guard.
- `handleSystemWake()` (registered via `NSWorkspace.didWakeNotification` in `init`, removed in `disconnect()`/`deinit`) forces a reconnect on wake when no BLE event fires. It nils `self.peripheral` first; the disconnect/fail callbacks use **object identity** (`peripheral === self.peripheral`) so a late `didDisconnect` queued from the pre-sleep link can't clobber the fresh reconnect attempt. Keep that identity check.
- `scheduleReconnect`'s `Task` hops back to `MainActor.run` before calling `reconnectIfNeeded()` — the controller is not `@MainActor`, so `Task.sleep` resumes off the main queue and all BLE-state mutation must stay on `.main` (the central's delegate queue). Don't drop that hop.
- `resetLinkState()` is a *light* teardown: it clears characteristics + `didStartHandshake` and cancels move/jog tasks, but does **not** nil `peripheral` or cancel the central connection (the system already reports the link gone). Only `disconnect()` / `handleSystemWake` nil `peripheral`.

## Conventions

- Swift, no third-party dependencies. Do not add SPM dependencies without asking.
- No comments in code unless asked.
- Keep `@MainActor` on `AppState` and all UI bindings; hop to `Task { @MainActor in … }` from BLE callbacks.
- The menu-bar popover opens/closes frequently — **never** tear down the desk connection from a view's `onDisappear`. Desk teardown happens only on explicit disable (`setDeskControlEnabled(false)`) or app quit.
- Asset icons are generated: run `python3 scripts/generate_icon.py` (stdlib only, no Pillow). Do not hand-edit PNGs.

## Verify before finishing

1. `xcodegen generate` succeeds and `StandUp.xcodeproj/` is up to date with the file tree.
2. `xcodebuild -project StandUp.xcodeproj -scheme StandUp build` succeeds with no compiler warnings (or build the **StandUp** scheme in Xcode, ⌘B).
3. `xcodebuild -project StandUp.xcodeproj -scheme StandUp test` is green.
4. Run (⌘R): confirm the menu-bar item appears, Start/Pause/Reset/Switch work, and a sit↔stand notification fires when an interval elapses.
5. In Settings → Desk, enable desk control and connect to a real LINAK desk: confirm the DPG handshake logs `user-id=1`, jog up/down moves the desk continuously while held and stops on release, and sit/stand presets move the desk with no lockout / bricking across repeated cycles (physical panel buttons stay responsive).
6. Put the Mac to sleep, wake it, and confirm the desk section recovers automatically (`Bluetooth is powered off` → `Connecting...` → `Connected`) and live height/jog/presets work again without toggling desk control off/on. Power-cycling the desk should likewise trigger an automatic reconnect.


