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

### Ranking model (N window, turns on as snapshots build up)
Once at least 3 stored snapshots are 5 or more trading days old, **Learn patterns** also trains a ranking model on **every stored day × stock**:
- **Inputs:** your training columns, each ranked among all stocks that day (this removes market mood), plus how each one changed over 1 and 5 snapshots (Δ1d, Δ5d).
- **Targets:** the real gain over 5, 10 and 21 trading days, from Yahoo. A ranking loss pushes gainers above the rest.
- **Network:** 6 small nets (16→8, plus a pairwise layer). **NN_score** is their average rank; **NN_conf** is how much they agree. The **Pairs** tab shows which column pairs the nets read together.
- **Testing:** walk-forward on later days it never saw once there are about 30 labelled days; before that, it is tested on held-out stocks. A **chance check** retrains on shuffled gains to show what luck alone scores. Combinations are found on earlier days and re-checked on the test data; ✓ **Held up** means a combination beat luck.
- **Snapshots** are now kept forever by default (N window → Keep forever), because the model needs months of days.

### What changed since yesterday
When the Filter opens, or new data arrives, cells that changed since the previous stored day flash for about 2 seconds: green for up, red for down, blue for stocks that are new to the list. A short summary appears on top.

### My Picks (⌥⌘P)
- **Marking picks:** in Daily Gainers, the **P** column marks your picks. Click to cycle **grey** (not my pick) → **green** (my pick) → **orange** (OK selection). You can also select rows and press **My pick** or **OK**.
- **The My Picks window:** every pick in one place, with its day, that day's move, entry price, return since, best rise since, comparison with the Nifty, sector, the news reason at the time, and your note.
- **Summary:** average return and % up for green picks vs orange OKs.
- **Filtering and export:** filter by grade, period and symbol or sector; export a CSV, copy symbols for TradingView, or add picks to a watchlist.

### Charts (⇧⌘K)
- **Chart links:** in the Chart window, open ⋯ → *Chart settings* and import a Google Sheet with a **Symbol** column and link columns (e.g. TradingView chart links). For stocks not in the sheet, the app reuses the sheet's link pattern.
- **Opening a chart:** **double-click** a stock in the Data, Filter or Gainers tables, or **right-click** any stock (also in Watchlists, Changes, Performance and Sectors) → *Open chart*. It opens in the in-app **Chart viewer**. Log in to TradingView there once and it stays logged in. ◀ ▶ (⌥⌘← / ⌥⌘→) steps through the list you opened it from.
- **Save snapshot (⇧⌘S):** stores the chart as a dated screenshot of that stock, so the S column turns green. **Annotate** opens it for drawing.

### Daily Gainers (⇧⌘G)
- **Index charts:** small **NIFTY 50** and **SENSEX** charts at the top, showing today in 5-minute steps (refreshed every 5 minutes while the window is open) or the last 3 months.
- **Gainers:** every sheet stock up at least X% on the chosen day, using Yahoo close vs previous close.
- **Analysis:** number of gainers, average gain, advancers vs decliners, how many are in your Filter list, and which sectors they come from.
- **Why (news):** click **Why? (news + Groq)** to fetch recent headlines for each gainer (Google News RSS or Yahoo Finance, both free) and have **Groq** sum up the likely reason in 5–10 words. Groq is told to use only the headlines and to say "No clear news" otherwise. Reasons are cached per day.
- **Groq setup:** add your API key in *News & AI settings* (kept in the Keychain) and pick a model from Groq's live list.
- **Filter columns & colours:** this toggle adds the Filter screen's columns, painted with your cell colours.

### Sectors & regime alerts (⇧⌘0)
This screen uses the sheet's **Sector** column. You can pick a different column in *Alerts & settings*. It also uses Yahoo daily closes, which are fetched once and then topped up once a day after new sheet data arrives.
- **Momentum:** each sector has an equal-weight index. The table shows its rank (with the change over 5 days), a 0–100 score, its 1W / 1M / 3M change, its 1M change vs the Nifty, rotation state, trend, breadth (% of stocks above their 50-day average) and a one-year sparkline. Click a sector to see its chart and its best stocks.
- **Rotation map:** relative strength vs the Nifty against how fast that strength is changing (an approximation of an RRG chart), with 10-day tails. The quadrants are Leading, Weakening, Lagging and Improving.
- **Change heatmap:** each sector's rotation state for each of the last 30 trading days, with the market regime on top. A dot marks a day the trend flipped.
- **Regime changes:** confirmed changes in rotation, trend or market regime (Risk-on / Mixed / Risk-off), where the new state must hold for N days. New changes produce a **macOS notification**, a banner on this screen, a count on the Filter toolbar button and, if you turn it on, an **email**.

### Performance (⇧⌘9)
A **study** looks at one column whose value says when an event happened. For example, D_Trigger = 100 means the trigger was 100 trading days before the sheet's data day; you can switch a study to calendar days or to dates. For each stock, the app finds that day in Yahoo's price history and measures what the stock did after it:
- return from the event close to the latest close, and the same compared with the Nifty 50
- best rise and how many trading days after the event it came, and the worst fall
- whether it reached your "rose significantly" %, and how fast
- returns at fixed horizons (+5, +10, +21, +50, +100 trading days)

The results show summary figures, a chart of the average and median move after the event, a histogram of returns, and a sortable table of stocks. The table can be copied, exported to CSV, or added to a watchlist.

**Compare groups by** splits the results by any column, from the main sheet or the experiments sheet. Numbers are split into Low / Mid / High thirds; text is split by value.

**Compare indicators & hidden patterns:** every study run is saved, up to the last 40. Tick the runs to compare, for example D_Trigger and two experiment columns. Every stock is then judged exactly **H trading days** after its own event (default 21), so old and new signals are compared over the same holding period.
- **Winners:** most profitable, fastest to +target%, least risky, and best risk-adjusted.
- **Side-by-side table:** median and mean return, a bootstrap 95% range of the mean, win rate, expectancy, profit factor, best rise and worst dip, worst-5% (CVaR), volatility, Sortino, hit rate, median days to target, target-before-stop and stop-before-target, and the return compared with the Nifty 50.
- **Charts:**
  - risk vs return
  - speed curves (a survival estimate, which also counts newer events)
  - the average path for each indicator
  - the spread of returns
- **Head to head:** the difference between each pair, with its 95% range and the chance that A is better, plus how stocks did when both indicators flagged them.
- **Hidden patterns:**
  - confluence: stocks flagged by 1, 2, 3 or more indicators
  - market regime: whether the Nifty was rising, flat or falling before the event
  - the stock's own move before the event
  - written findings, each marked *solid* or *tentative*

**Best strategies:** six entry filters (market rising, stock weak or strong before, signals flagged by 2+ indicators…) are combined with 160 exit rules (take-profit, stop, trailing stop, max hold). Each combination is replayed on every stock's real price path after its signal, for each indicator and for all indicators pooled. Strategies are chosen on the older half of signals and checked on the newer half; **held up** means the strategy was still profitable there. Buy-and-hold for 21 days is shown as a baseline.

**Good vs bad incidents:** compares the top 25% of signals with the bottom 25%.
- Factors ranked by how well they separate the two groups (AUC), with the best single cut for each.
- The factors used: the stock's and the Nifty's move before the signal, sector, indicator, weekday, number of indicators that flagged the stock, and the move 3 and 5 days after the signal (marked *after entry*, an early-warning sign rather than an entry filter).
- A small decision tree turns these into "IF … AND …" rules, learned on older signals and checked on newer ones.

**How patterns are tested:**
- **Good vs bad incidents:** a gradient-boosted tree model is trained on entry-time factors and scored walk-forward (trained on earlier signals, tested on the next block, three times). Each factor's influence is explained with exact Shapley values.
- **Strategies:** each strategy gets a **Deflated Sharpe Ratio** (Bailey & López de Prado), the probability that its edge is real after allowing for the 960 combinations tried. **Robust** means it held up on newer signals and its Deflated Sharpe is at least 95%.
- **Neural Net combinations:** each combination gets a binomial p-value and a Benjamini–Hochberg **q-value** (false-discovery rate across every combination tried), and you can show only the significant ones.

**Experiments sheet:** paste a second sheet's link under *Sheet & columns…*, choose its stock-name column and the columns you want, then use them as a study's event column or as the group-by column.

### Changes — cards (⇧⌘8)
One screen of cards comparing the live data with the previous stored day. You can also pick any earlier day.
- **Cards:** each one shows how many stocks match and the biggest changes, as old → new with the change.
- **Setting up cards (Edit cards):** name, condition, column, amount (points or %), scope (all stocks / only the Filter list / only watchlists) and colour. Drag cards to reorder them.
- **Conditions:** went up, went down, changed, crossed above or below a level, got a value, became blank, entered or left the Filter list, new stock in the sheet, stock gone from the sheet.
- **Default cards:** Entered Filter, Left Filter, D_Trigger appeared, D_Trigger went up, New in sheet.
- **Actions:** right-click a stock to add it to a watchlist or open its screenshots. Each card's ⋯ menu adds all its stocks to a watchlist or copies their symbols.

### Find (⌘F or ⌃F)
In the Data Import and Filter tables, ⌘F or ⌃F opens a find bar. Every matching cell is outlined in yellow and the current match in orange. Press ↩ for the next match, ⇧↩ for the previous one, and Esc to close the bar.

### S — Screenshots (Filter screen)
The **S** column sits next to E. Grey means the stock has no screenshot, orange means it has screenshots, and green means the newest one is under 7 days old. Click **S** (or ⇧⌘6) to open the Screenshot viewer for that stock. Screenshots are listed newest first.
- **Adding screenshots:** capture an area of the screen, paste an image with ⇧⌘V, import a file, or drag images onto the viewer.
- **Annotating:** pen, highlighter, line, arrow, rectangle, ellipse and text, with 8 colours, line width, eraser and undo/redo. Each screenshot can also have a note.
- **Sharing:** copy or export the image with your drawings.
- Files are kept in ~/Library/Application Support/StockScreener/Screenshots/<SYMBOL>/. The first capture may ask for Screen Recording permission.

### Watchlists (⇧⌘5)
- **Adding stocks:** select rows in the Filter or Data table (⌘-click or ⇧-click several), then right-click → *Add to "Watchlist"*. You can also use the **Watchlist** toolbar menu (add the selected or all shown stocks), or paste symbols.
- **Returns:** from the price when added to the latest close, plus 1-day, 5-day and 1-month change, best close since added, distance from that best, and the return compared with the Nifty 50 over the same days.
- **Summary:** average, median, winners, best and worst stock.
- **Sharing:** copy symbols (including TradingView format) or export a CSV.
- Prices come from Yahoo daily closes, which is an unofficial source.

### MV2 Requirements & Pine Scripts (⇧⌘7)
A plain-text editor with two sections: **MV2 Build Requirements** documents and **Pine Scripts**. It supports copy and paste, undo, ⌘F find and replace, Pine syntax colours, **Copy all** (to paste into TradingView's Pine Editor) and **Replace with clipboard**. Documents save automatically as files in ~/Library/Application Support/StockScreener/.

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
