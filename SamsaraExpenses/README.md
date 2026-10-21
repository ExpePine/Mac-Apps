# Samsara Expenses (macOS)

Downloads your expenses from the Samsara page (https://rajakrishna.in/samsara/) automatically —
the same CSV its 📥 "Download table as CSV" button gives you — and analyses them.

## Download
GitHub → Releases → **Samsara Expenses (latest)** → `SamsaraExpenses.dmg`.
Open it, drag the app to Applications. The app is not signed with an Apple Developer ID, so on
first launch macOS blocks it: System Settings → Privacy & Security → **Open Anyway**
(or right-click the app → Open).

## How the automatic download works
The page builds the CSV in the browser, so there is no fixed CSV link. The app opens the page in
an invisible web view, presses 📥 and catches the file. It does this when the app opens and then on
a schedule (Settings: every 15 min … once a day). Closing the window keeps it running in the menu
bar; quit with ⌘Q.

If the page needs a sign-in, use **Sync → Sign in to Samsara…** once; the sign-in is remembered.

You can also import a CSV yourself (⌘O) or drop it onto the window.

## What it shows
- Dashboard: total, per day, month-end estimate, monthly and daily charts, categories, weekdays, top items
- Insights: change vs previous period, category movers, eating out share, biggest purchase, busiest day
- Transactions: searchable, sortable table with filters and CSV export
- Categories, Vendors & People (Dona / Raja)

## Data
Stored only on your Mac: `~/Library/Application Support/SamsaraExpenses/`
(`latest.csv` + one copy per day in `archive/`). Nothing is uploaded anywhere.
This repository is public, so no real expense data is committed; screenshots use made-up data.

## Build locally
```bash
cd SamsaraExpenses
swift test
./scripts/build-dmg.sh
```
Needs macOS 13+ and Xcode 15+ (Swift 5.9).
