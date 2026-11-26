# Pomodoro for the Touch Bar

A small native macOS app (Swift + AppKit, one source file). GitHub Actions builds it (`.github/workflows/pomodoro-dmg.yml`) on an Intel macOS runner and publishes the DMG as the `pomodoro-latest` release. It has not been tried on a real Touch Bar yet.

## What it does

- **Touch Bar:** a big `▶︎ 🍅 25:00` button (tap to start/pause; red while focusing, green on a break), plus **Reset** and **Skip**.
- **Menu bar:** the countdown is always visible there, with Start/Pause, Reset, Skip and Quit in its menu.
- **Cycle:** 25 min focus, 5 min break, a 15 min break after every 4th focus. Plays the "Glass" sound and bounces the Dock icon when a phase ends.

## The catch: Touch Bar visibility

With Apple's public API (`NSTouchBar`), an app's Touch Bar controls only appear **while that app is frontmost**. Switch to Safari and the Touch Bar shows Safari's controls. The menu bar countdown covers you the rest of the time.

**Experimental option:** menu bar icon → *Button in Control Strip (experimental)*. This puts a 🍅 button in the Control Strip (right side of the Touch Bar) that works from any app; tapping it opens the timer controls. It relies on **private, undocumented Apple APIs** (`+[NSTouchBarItem addSystemTrayItem:]`, `+[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]`, `DFRElementSetControlStripPresenceForIdentifier` in DFRFoundation). I know of them from how open-source tools such as MTMR and Pock work, but I could not confirm the exact signatures still hold on your macOS version. The app checks they exist before calling them, and shows a message if they don't. If they exist but behave differently, the worst case I'd expect is the button not appearing, or the app crashing when you turn it on. Turn it off again or run `defaults write local.pomodoro controlStrip -bool false`.

## Get the .dmg

Download `Pomodoro.dmg` from the **pomodoro-latest** release, open it and drag **Pomodoro** into **Applications**.

To build it yourself on a Mac with the Xcode Command Line Tools: `Pomodoro/scripts/build-dmg.sh`, which writes `Pomodoro/dist/Pomodoro.dmg`.

`Pomodoro --selftest` prints whether the private Touch Bar calls used by the Control Strip option exist on that Mac.

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
