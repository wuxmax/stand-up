# StandUp — agent guide

A macOS menu-bar app (SwiftUI, macOS 14+) that nudges you to sit/stand and can drive a LINAK desk over Bluetooth.

## Build tooling

- This repo uses **xcodegen** (`brew install xcodegen`). `project.yml` is the source of truth; `StandUp.xcodeproj/` is generated. **Do not hand-edit the `.xcodeproj`.**
- After adding/removing/moving source files, run `xcodegen generate` from the repo root and commit both the changed `project.yml` (if any) and the regenerated `StandUp.xcodeproj/`.
- Full **Xcode is required** to build/run (Command Line Tools alone cannot build a SwiftUI `.app`). `swiftc -typecheck` may fail in CI if only CLT is installed and the CLT license hasn't been accepted — that's an environment problem, not a code problem.

## Architecture

- `AppState` (`@MainActor`, `ObservableObject`) is the single source of truth. It owns `TimerSettings`, `DeskSettings`, a `PostureTimer`, `NotificationManager`, and an optional `DeskController`. It persists settings to `UserDefaults`.
- `PostureTimer` is a classic `Timer`-based 1s ticker. On interval completion it flips posture and posts `PostureTimer.Static.tickCompleteNotification`; `AppState` observes that (set up in `AppState.init`) and fires a user notification + optional desk move.
- The desk layer is behind the `DeskController` protocol. The sole implementation is `LinakDeskController` (CoreBluetooth). **Do not** put BLE code anywhere outside `StandUp/Desk/Linak/`.
- `MenuBarExtra` popover shows the timer + controls. The app is `LSUIElement` (menu-bar only, no Dock icon).
- Settings is NOT a SwiftUI `Settings` scene. SwiftUI scenes don't work reliably for `LSUIElement` apps (window never gets focus / doesn't reopen). Instead `SettingsWindowController` (`StandUp/Settings/`) owns a single `NSWindow` (kept alive via `isReleasedWhenClosed = false`) hosting `SettingsView`, toggling `NSApp.setActivationPolicy(.regular)` while open and back to `.accessory` on `windowWillClose`. Open via `SettingsWindowController.shared.open(appState:)`. Do not reintroduce a `Settings`/`WindowGroup` scene for this.

## LINAK protocol notes (iteration 2)

`StandUp/Desk/Linak/` is a native Swift port of `rhyst/linak-controller` (Python/bleak). Reference files (keep them in mind when changing byte layout):
- `linak_controller/gatt.py` — UUIDs + `encode_height`/`decode_height_speed` (struct `<H` height, `<Hh` height+speed, little-endian).
- `linak_controller/desk.py` — the move loop: `wakeup`, `stop`, then repeatedly write Reference Input until Reference Output speed == 0.

Height semantics: on-wire value is **tenths of a mm relative to base height**; UI values are **absolute mm above floor**. The base offset is read from the desk during the DPG handshake; the same absolute mm number is used for the displayed height, sit/stand presets, and `moveTo` conversion (`resolvedBaseMm`, `lastHumanHeightMm`). Control commands (`wakeup`/`stop`/`moveUp`/`moveDown`) are written as **two bytes** `[cmd, 0]` with `stop = 255`.

**DPG init handshake** (capabilities, set user-id byte to 1, read base offset) is implemented in `LinakDeskController.performDPGHandshake`, run after all characteristics are discovered and before surfacing `.connected`. Jog (`jogUp`/`jogDown`) repeats `moveUp`/`moveDown` every ~300ms while held (a single command is only a ~12mm nudge) and sends `stop` on release.

## Conventions

- Swift, no third-party dependencies. Do not add SPM dependencies without asking.
- No comments in code unless asked.
- Keep `@MainActor` on `AppState` and all UI bindings; hop to `Task { @MainActor in … }` from BLE callbacks.
- The menu-bar popover opens/closes frequently — **never** tear down the desk connection from a view's `onDisappear`. Desk teardown happens only on explicit disable (`setDeskControlEnabled(false)`) or app quit.
- Asset icons are generated: run `python3 scripts/generate_icon.py` (stdlib only, no Pillow). Do not hand-edit PNGs.

## Verify before finishing

1. `xcodegen generate` succeeds and `StandUp.xcodeproj/` is up to date with the file tree.
2. Open in Xcode and build the **StandUp** scheme (⌘B). Fix any compile errors.
3. Run (⌘R): confirm the menu-bar item appears, Start/Pause/Reset/Switch work, and a sit↔stand notification fires when an interval elapses.
4. In Settings → Desk, enable desk control and connect to a real LINAK desk: confirm the DPG handshake logs `user-id=1`, jog up/down moves the desk continuously while held and stops on release, and sit/stand presets move the desk with no lockout / bricking across repeated cycles (physical panel buttons stay responsive).
