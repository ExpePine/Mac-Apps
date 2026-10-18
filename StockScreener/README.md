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

## Screens

| Screen | Open with | What it does |
|---|---|---|
| **Data Import** | opens at launch | **Import data** button, import status (freshness and MV2 date), search across all columns, and the full sheet. Click a header to sort. |
| **Filter** | toolbar button or ⇧⌘1 | Hide or show the conditions pane with ⌥⌘S to give the colored table the full window. Only the columns you choose (**Columns…**: tick them and drag to reorder), sorted by `D_Trigger` or any column, with **advanced filters** and per-column cell colors |
| **Alerts & Email** | toolbar button or ⇧⌘2 | Email setup, the MV2 check, buy triggers (using the same advanced filters) and an alert history |

### Column ▼ menu (Filter screen)

Each column header on the Filter screen has a small **▼** at its right edge. Clicking it opens a panel for that column with:
- **Sort low → high / high → low**, applied straight away. Clicking the header name also still sorts.
- **Conditions on this column**, using the full advanced builder: compare to a value, compare to another column × a factor, or use a formula. These conditions are combined with the rest of your filter.
- **Cell colors** for that column.

The ▼ is highlighted on columns that have conditions or colors.

### "E" — Email & alert rules

The **E** button on the Filter screen opens your rules. Each rule has advanced conditions and two checkboxes:
- **Email**: matching stocks are emailed, each at most once a day.
- **Alert in app**: a **"Conditions met"** pop-up appears when the app opens and loads data, and a banner appears whenever new data meets a rule. Click a stock in the pop-up to animate its history.

**New rule from the Filter screen's conditions** turns what you've built on the Filter screen into a rule with one click.

### Frozen columns

Use the **Freeze** menu on the Data Import or Filter screen to keep the first 1, 2 or 3 columns visible while you scroll sideways. The header row always stays fixed.

### Replay the last 30 days (Filter screen)

Click **▶ Animate** to show a **time slider** under the Filter table. Press **Play** (or Space) and the whole Filter table replays day by day, from 30 stored days ago up to **Live**, with the same columns, filters, sort, colors and E statuses applied to each day's data. You can drag the slider to any day, step one day at a time, change the speed, or click **Live** to come back to today. While a past day is shown, an orange banner names the date.

**How history is stored:** after each import, the app saves one snapshot per trading day, dated from `D_MONTH`/`D_DAY`. Each snapshot is compressed with Apple's LZFSE format and kept in `~/Library/Application Support/StockScreener/History/`, for 45 days by default. The sheet only holds today's data, so the replay fills up over time; 30 trading days takes about 6 weeks.

### E column: Email / Alert per stock

The first column on the Filter screen is **E**:
- **Grey**: no rule for this stock.
- **Orange**: a rule is set for this stock but isn't met right now.
- **Green**: an Email / Alert rule is met for this stock.

Click a stock's **E** to add or edit its rules. Each rule uses advanced conditions and has **Email** and **Alert in app** checkboxes. Rules for *all* stocks are under **Rules** in the toolbar.

### TG — Top Gainers (Filter screen)
Click **TG** to show only stocks that rose more than 7% that day (the threshold is a setting), with the same filters and colors. It works on live data and on any day in the 30-day replay. The change% comes from Yahoo Finance prices when they've been fetched (in the N window). Otherwise it comes from the sheet's change% column. A small orange line on top shows the day, the count, and the **total Safety_limit** of those stocks.

### N — Neural Net
**N** (⇧⌘4) opens the pattern lab:
1. **Fetch Yahoo prices** downloads about a year of daily closes for every stock and keeps a compressed copy on your Mac.
2. **Learn patterns** marks each stock that gained at least 30% within 21 trading days as a *monthly top gainer*. You can change both numbers. It then lists every combination of 1–3 Filter-column values that gainers share more often than other stocks, with hit rate and lift. Any combination can become a filter (**Filter**) or an Email/Alert rule (**Alert**).
3. **Training columns** sets which columns the net learns from. Each column is tagged *Feature*, *Price level* (D_CLOSE, EMA_20…), *Raw size* (volume, market cap), *Date*, *Name/ID* or *Text*. By default it uses the Filter screen's columns that are features, and you can tick or untick any column.
4. A small neural net (inputs → 16 → 8 → 1) learns the same columns. It is tested on 20% of stocks it never saw (AUC, gainers in its top 20), and it adds an **NN_score** column (0–100) that you can sort, filter, color or alert on.

*Descriptive* mode uses today's values for stocks that already ran up, so it describes gainers but can't predict them. Once the app holds a snapshot from about 21 trading days ago, it switches to *Predictive* mode and learns from values **before** the move. Yahoo's chart endpoint is unofficial and can rate-limit or change without notice. None of this is financial advice.

### What changed since yesterday
When the Filter opens, or new data arrives, cells that changed since the previous stored day flash for about 2 seconds: green for up, red for down, blue for stocks that are new to the list. A short summary appears on top.

### Alerts browser

**Alerts** (⇧⌘3, the bell button) lists every alert that has fired: when it fired, the stock, the rule, whether it was an alert or an email, and the values at that moment. You can search, filter by period (today / 7 days / 30 days / all), type and rule, and click an alert to see its details. The toolbar shows how many alerts are new.

### Column names

Columns with placeholder names such as `var 1` … `var 10` can be given real names under **Column names**, in the Data Import toolbar or via **Rename…** on the Filter screen. The new names are used everywhere: both tables, pickers, filters, formulas, cell colors, the MV2 check, buy triggers and emails. Existing filters and formulas switch to the new names automatically, and the sheet's original names still work in formulas. Hover over a column header to see its name in the sheet.

### Advanced filters

- **Groups:** *All of (AND)*, *Any of (OR)*, *None of (NOT)*. You can nest groups inside groups, for example `CLOSE > EMA_20 AND (RSI_14 > 70 OR Vol Ratio > 3)`.
- **Column vs value:** `>  ≥  <  ≤  =  ≠  between  contains  starts with  has a value  is empty`.
- **Column vs column**, with an optional multiplier: `CLOSE > EMA_20 × 1.02` means CLOSE is more than 2% above EMA_20.
- **Formulas**, for anything else:
  ```
  RSI_14 >= 60 AND VOLUME > 2 * AVG_VOL
  (D_TRIGGER > 0 OR [Breakout %] > 3) AND NOT SECTOR = 'Bank'
  pct(CLOSE, PREV_CLOSE) > 2
  ```
  Column names can be used directly, or put in `[brackets]` if they contain spaces or symbols; capitals don't matter. The available functions are `abs`, `round`, `min`, `max`, `pct(a, b)` (percent change from b to a), `empty`, `contains` and `startswith`. The editor checks each formula as you type.

### Cell colors (Filter screen)

Each rule colors one column's cells, for example `Change % > 2 → Green` and `Change % < -2 → Red`, and anything else stays neutral. There are 12 shades to choose from. If several rules for a column match, the first one wins.

### Speed

- Each cell is parsed once when data arrives.
- Filters are compiled once, then run in the background.
- The tables are native macOS tables that only draw the rows on screen.
- Identical downloads are skipped, so nothing is re-filtered when the sheet hasn't changed.

### Email alerts

Set up a sending account in **Alerts & Email → Email**. For Gmail, use `smtp.gmail.com`, port 465, and an **App Password**, which requires 2-Step Verification; your normal password won't work. Then click **Send test email**. The password is stored in the macOS Keychain.

- **MV2 not updated:** every time new data arrives, the app checks `D_month` / `D_day`. If no row matches today's date, it emails **"MV2 not updated"**, at most once a day, skipping weekends by default.
- **Buy triggers:** use the full advanced filter: groups, column-vs-column comparisons and formulas. When new data arrives, each stock that meets them is emailed once per day per trigger. You can create several triggers, each with its own recipients.

Emails go out only while the app is running, which is why Open at login is on.

### MV2 not updated email
The app checks each time new data arrives. It counts how many rows have D_MONTH / D_DAY that don't match today, and if any don't, it emails "MV2 not updated (x of y rows)" with examples. It sends at most one email a day, and **only Monday–Friday**.

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
