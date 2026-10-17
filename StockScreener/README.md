# Stock Screener for Mac

A native macOS app (SwiftUI) that pulls a Google Sheet automatically, filters the stocks by your rules, highlights the rows that meet your conditions, and tells you whether the sheet's data is actually being updated.

## Download

Go to the repo's **Releases → Stock Screener (latest)** and download `StockScreener-x.y.z.dmg`.

Every push to `main` that changes the `StockScreener/` folder rebuilds the app on GitHub's macOS servers and refreshes that release.

## Installing (first launch)

The app is ad-hoc signed, not notarized, because that needs a paid Apple Developer account. macOS will block it the first time:

1. Open the DMG and drag **Stock Screener** into **Applications**.
2. Double-click the app. macOS says it can't verify the developer. Click **Done** or **Cancel**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Stock Screener message.

Alternatively, run this once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Stock Screener.app"
```

> These Gatekeeper steps differ slightly between macOS versions, so verify them on yours.

## Using it

The app turns on **Open at login** the first time it runs, so as long as your Mac is on it fetches the data every day without you doing anything. If macOS asks, approve it under **System Settings → General → Login Items**. You can switch this off in ⚙️ Settings.

Setup, done once:

1. In Google Sheets, set **Share → General access → Anyone with the link → Viewer**.
2. Open the tab that holds the data (e.g. Sheet2) and copy the link from the address bar. The `gid=` part selects the tab.
3. In the app, click **Add sheet link…**, paste the link, and choose the refresh interval. The link is stored only on your Mac and is never in this repo.
4. Add **filters** (only show rows that match) and **highlights** (color rows that match) in the sidebar.

## Windows

| Window | Open with | What it does |
|---|---|---|
| **Data** | opens at launch | The whole sheet: search, sort, filter and highlight rows, plus the freshness / MV2 status bar |
| **Active Filter** | toolbar button or ⇧⌘1 | `D_Trigger` and every column after it, sorted by `D_Trigger`, with its own filter conditions and per-column cell colors |
| **Alerts & Email** | toolbar button or ⇧⌘2 | Email setup, the MV2 check, buy triggers and an alert history |

### Cell colors (Active Filter)

Each rule colors one column's cells, for example `Change % > 2 → Green` and `Change % < -2 → Red`, and anything else stays neutral. The **Add green-above / red-below pair** button creates both rules at once. There are 12 shades to choose from: light green, green, dark green, teal, light red, red, dark red, orange, yellow, blue, purple and grey. If several rules for a column match, the first one wins.

### Email alerts

Set up a sending account in **Alerts & Email → Email**. For Gmail, use `smtp.gmail.com`, port 465, and an **App Password**, which requires 2-Step Verification; your normal password won't work. Then click **Send test email**. The password is stored in the macOS Keychain.

- **MV2 not updated:** every time new data arrives, the app checks `D_month` / `D_day`. If no row matches today's date, it emails **"MV2 not updated"**, at most once a day, skipping weekends by default.
- **Buy triggers:** you choose conditions across any columns, combined with AND or OR. When new data arrives, each stock that meets them is emailed once per day per trigger. You can create several triggers, each with its own recipients.

Emails go out only while the app is running, which is why Open at login is on.

### "Is the data updated?"

A bar above the table shows the state of the data:

| State | Meaning |
|---|---|
| 🟢 Data is up to date | The sheet's content changed within your "warn after" window (default 24 h) |
| 🟠 No new data for over N h | Each download is identical to the last one |
| 🟠 Not updated for the latest trading day | The newest row in your chosen date column is older than the last weekday (optional) |
| 🔴 Can't reach the sheet | The download failed; the last good data stays on screen |

The app detects changes by comparing a fingerprint (SHA-256) of each download, and it remembers this across launches.

## Building locally (optional)

This needs a Mac with Xcode installed:

```bash
scripts/build-dmg.sh 0.1.0      # outputs dist/StockScreener-0.1.0.dmg
swift run                       # or just run it for development
```

## Project layout

| Path | Purpose |
|---|---|
| `Sources/StockScreener/` | App code (SwiftUI) |
| `Resources/Info.plist` | App bundle metadata |
| `Resources/AppIcon.iconset/` | App icon images |
| `scripts/build-dmg.sh` | Builds the universal `.app` and packs the `.dmg` |
| `../.github/workflows/stock-screener-dmg.yml` | GitHub Actions: build on macOS, publish the release |

## Current limits

- Reads one sheet tab.
- The sheet must be link-shared or published. A private sheet needs Google sign-in, which isn't built yet.
- The CSV export URL is undocumented Google behaviour. If it ever breaks, use **File → Share → Publish to web → CSV** and paste that link instead.
- The trading-day check knows weekends but not NSE holidays.
