# Activity Logger (macOS menu-bar app)

Every N minutes it asks **"What did you do in the last N min?"** — you answer by typing,
recording a voice note, or both. Voice notes are converted to text with Apple's Speech
framework. If you don't finish in the entry window (1–10 min), whatever you have is
auto-saved.

## Features
- Check-in interval: 15 / 20 / 30 / 40 / 60 min presets, or custom 5–180 min
- Entry window: 1–10 min, with a countdown ring, `+1 min`, and auto-save on timeout
- Answer from the **notification** (Quick reply text field, Open, Skip) or the **floating entry window**
- Voice note → speech-to-text (on-device when the language supports it); text is editable before saving
- History window: grouped by day, search, play voice notes, re-transcribe, delete, export CSV
- Pause / resume, "Log now", launch at login
- Sleep-aware: after a long sleep it resets instead of asking about a multi-hour gap

Entries status: Saved · Quick reply · Auto-saved · Skipped · Missed.

## Build & run (needs a Mac with Xcode 15 or newer, macOS 13+)

**Option A — XcodeGen (quickest)**
```bash
brew install xcodegen
cd ActivityLogger
xcodegen generate
open ActivityLogger.xcodeproj
```
Then press ⌘R. A clock icon appears in the menu bar.

**Option B — manual Xcode project**
1. Xcode → New Project → macOS → App. Name `ActivityLogger`, Interface SwiftUI.
2. Delete the generated `ContentView.swift` and `ActivityLoggerApp.swift`, drag in everything in `Sources/` except Info.plist/entitlements.
3. Target → Info: add
   - `Application is agent (UIElement)` = YES
   - `Privacy - Microphone Usage Description`
   - `Privacy - Speech Recognition Usage Description`
4. Target → Signing & Capabilities → App Sandbox: tick **Audio Input**, **Outgoing Connections (Client)**, and User Selected File **Read/Write**.
5. Deployment target macOS 13.0. ⌘R.

## First run
macOS will ask for: **Notifications**, then (first time you press Record) **Microphone** and **Speech Recognition**. Allow all three.

Tip: in System Settings → Notifications → Activity Logger, set the style to **Alerts**
(not Banners) so the notification stays on screen with Quick reply / Open / Skip buttons.

## Where data lives
`~/Library/Containers/com.raj.ActivityLogger/Data/Library/Application Support/ActivityLogger/`
- `entries.json` — all entries
- `Audio/*.m4a` — voice notes

Use **Data folder** in the menu to open it in Finder.

## Things worth verifying on your Mac
I wrote this without being able to compile it on a Mac, so expect possibly a small fix or two on first build.
- I'm not certain which languages support **on-device** recognition on your macOS version. If a language isn't supported on-device, the app falls back to Apple's server recognition (needs internet). If speech-to-text fails, try switching the language to English (US), and check that Dictation is enabled under System Settings → Keyboard.
- **Launch at login** (`SMAppService`) may require the app to be in /Applications and properly signed; it may fail when run straight from Xcode.
- Notifications from an ad-hoc signed ("Sign to Run Locally") build normally work, but if they don't appear, set your Apple ID team under Signing & Capabilities.
