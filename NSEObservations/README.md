# NSE Observations (macOS app)

A journal for the NSE charts you keep revisiting. One place per symbol for every observation
you write (dated, with chart timeframe and bullish / neutral / bearish read), your buys and
sells, a price chart with your notes plotted on it, and Groq-powered analysis of your notes.

## Features
- **Symbols** grouped as Holding · Watching · Exited · Archived; search across tickers, notes and tags
- **Observations**: date you looked, Daily/Weekly/Monthly/Intraday chart, sentiment, tags, price you saw
- **What happened next** under every note: % move to latest, after 5 and 20 sessions, best and worst move since
- **Chart**: line or candles, 1M–5Y or "Notes" range, notes as coloured dots, trades as triangles, hover for OHLC
- **Trades**: log buys/sells; position, average cost and unrealised % shown
- **Groq AI**
  - *Summarize My Notes* (per symbol)
  - *Compare Notes with Price* (per symbol, uses the after-note moves)
  - *Patterns* across all symbols, with draft algo rules
  - *Ask Your Notes* chat
- Backups: File ▸ Export Backup / Import Backup (JSON)

## Install
1. Download `NSEObservations.dmg` from the latest **NSE Observations (build N)** release
   (or the `NSEObservations-dmg` artifact of the latest *NSE Observations DMG* Actions run).
2. Open it and drag **NSE Observations** into Applications.
3. First launch: the app is ad-hoc signed (no Apple Developer ID), so macOS blocks it. Open
   **System Settings ▸ Privacy & Security** and click **Open Anyway**.
4. **⌘,** → paste your Groq API key (from console.groq.com). It is stored in your Keychain.
   After an app update macOS may ask once whether the app can use the saved key — choose *Always Allow*.

Universal build (Apple Silicon + Intel), macOS 13 Ventura or later.

## Keyboard
⇧⌘N add symbol · ⌘N new observation · ⌘↩ send chat · ⇧⌘E export backup · ⌘, settings

## Data and limits
- Your journal is one JSON file in the app's sandbox
  (`~/Library/Containers/com.raj.NSEObservations/Data/Library/Application Support/NSEObservations/observations.json`).
  *Settings ▸ Data ▸ Show in Finder* opens it.
- Prices are **daily** candles from Yahoo Finance's public chart endpoint (`SYMBOL.NS`). It is unofficial,
  can be delayed, and can change or rate-limit without notice — verify levels on NSE before acting.
  For indices enter the Yahoo symbol directly, e.g. `^NSEI`.
- Groq models change over time. Settings ▸ AI has a refresh button that lists the models your key can use.
- AI output is generated from your notes; it is not investment advice.

## Build locally
```bash
brew install xcodegen
cd NSEObservations
./scripts/build-dmg.sh      # → dist/NSEObservations.dmg
# or: xcodegen generate && open NSEObservations.xcodeproj
```
CI: `.github/workflows/nse-observations-dmg.yml` builds on every push that touches `NSEObservations/`.
