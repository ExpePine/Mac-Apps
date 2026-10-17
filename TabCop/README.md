# TabCop (macOS menu-bar app)

Counts open tabs in **Google Chrome** and **Safari** and sends a "time to focus" notification when the total goes over your limit.

**Download:** [TabCop.dmg (latest)](https://github.com/ExpePine/Mac-Apps/releases/download/tabcop-latest/TabCop.dmg) — universal (Apple Silicon + Intel), macOS 13+.

## Install
1. Open the DMG and drag **TabCop** to Applications.
2. First launch: macOS blocks unnotarized apps — System Settings → Privacy & Security → **Open Anyway**
   (or `xattr -dr com.apple.quarantine /Applications/TabCop.app`).
3. Allow **Notifications**, then click **OK** when asked whether TabCop may control Chrome / Safari.
   Clicked Don't Allow? System Settings → Privacy & Security → Automation → TabCop.
4. Optional: menu bar icon → **Launch at login**.

## Behaviour
- Checks every 30 s. Menu bar shows `🗂 12` normally, `⚠️ 23` when over the limit (combined Chrome + Safari).
- Only counts browsers that are already running — it never launches them.
- Nudges at most once every 10 min while over the limit; drop below and cross again → immediate nudge.
- Menu: per-browser counts, tab limit (10–50, default 15), pause 1 hour, check now, launch at login, quit.
- Tweak `checkInterval`, `nagCooldown`, `focusMessages`, or add browsers (Brave `com.brave.Browser`, Edge `com.microsoft.edgemac`) at the top of `TabCop.swift`.

## Build locally
```bash
cd TabCop
./scripts/build-dmg.sh      # → dist/TabCop.dmg
```

## Troubleshooting
- No notifications: System Settings → Notifications → TabCop → Allow; check Focus mode.
- Logs: `log stream --predicate 'eventMessage CONTAINS "TabCop"'`
- After installing a new build, macOS may re-ask for Automation permission (ad-hoc signature changes).
