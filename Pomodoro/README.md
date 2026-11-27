# Pomodoro for the Touch Bar

A small native macOS app (Swift + AppKit, one source file). GitHub Actions builds it (`.github/workflows/pomodoro-dmg.yml`) on an Intel macOS runner and publishes the DMG as the `pomodoro-latest` release. It has not been tried on a real Touch Bar yet.

## What it does

- **Touch Bar:** `[ ✎ ] [ ██████ 🍅 Write the report ........ 12:34 ] [ ↺ ] [ ⏭ ]`. The bar fills left to right as the session runs (red for focus, green for a break), with your task written on it and the time left on the right. Tap the bar to start or pause; it's dimmed with a ▶︎ while paused. ✎ opens the window to type your task, ↺ resets, ⏭ skips.
- **Task:** type it in the box at the top of the window (or menu bar → *Set Task…*). It's remembered between launches. During a break the bar shows `☕️ Short break · next: <task>`.
- **Menu bar:** `🍅 12:34 · Write the report`, always visible, with Start/Pause, Set Task, Reset, Skip and Quit.
- **Cycle:** 25 min focus, 5 min break, a 15 min break after every 4th focus. Plays the "Glass" sound and bounces the Dock icon when a phase ends.

## Seeing it on the Touch Bar

1. **Touch Bar setting:** System Settings → Keyboard → Touch Bar Settings (older macOS: System Preferences → Keyboard) → *Touch Bar shows* must be **App Controls** (with or without the Control Strip). If it's set to F-keys, Expanded Control Strip or Quick Actions, no app can show anything there.
2. **Pomodoro in front:** with Apple's public API, the bar shows only while the Pomodoro window is the active window. Click the window once.
3. **Not while typing:** while the cursor is in the task box, macOS shows typing suggestions instead. Press Return (this also starts the timer) and the bar comes back.
4. **From any other app:** a 🍅 button is added to the Control Strip (right end of the Touch Bar). Tap it, or choose *Show on Touch Bar* in the menu bar, and the timer bar appears over whatever app you're using. Starting the timer from the menu bar also shows it. This uses **private, undocumented Apple APIs** (`+[NSTouchBarItem addSystemTrayItem:]`, `+[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]`, `DFRElementSetControlStripPresenceForIdentifier`), the same ones tools like MTMR and Pock use. CI confirmed they exist on macOS 15.7, but not that they behave the same on every version. Turn the button off in the menu bar if it misbehaves.

`Pomodoro.app/Contents/MacOS/Pomodoro --selftest` (in Terminal) prints whether those private calls exist on your Mac.

## Get the .dmg

Download `Pomodoro.dmg` from the **pomodoro-latest** release, open it and drag **Pomodoro** into **Applications**.

To build it yourself on a Mac with the Xcode Command Line Tools: `Pomodoro/scripts/build-dmg.sh`, which writes `Pomodoro/dist/Pomodoro.dmg`.

## Gatekeeper ("can't be opened" / "unidentified developer")

The app is ad-hoc signed, not signed with an Apple Developer ID or notarized.

- **Downloaded from GitHub:** macOS will block the first launch. On recent macOS, open System Settings → Privacy & Security, scroll down and click **Open Anyway** next to the Pomodoro message. On older versions, right-click the app → **Open** → **Open**. Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Pomodoro.app`.

Where exactly those buttons sit varies between macOS versions, so worth checking against what your Mac shows.

## Settings (optional, via Terminal)

```bash
defaults write local.pomodoro workMinutes -int 50
defaults write local.pomodoro shortBreakMinutes -int 10
defaults write local.pomodoro longBreakMinutes -int 20
defaults write local.pomodoro longBreakEvery -int 4
defaults write local.pomodoro autoStartNext -bool true
```

Quit and reopen the app after changing them.

## Files

- `Sources/main.swift`: the whole app.
- `Info.plist`: the app bundle's metadata.
- `scripts/build-dmg.sh`: compile (universal), ad-hoc sign, package into `dist/Pomodoro.dmg`.
