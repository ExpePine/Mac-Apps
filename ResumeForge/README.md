# ResumeForge

A Safari extension plus a macOS app.

The extension captures job descriptions from Naukri, Wellfound and LinkedIn. The app uses the **Groq API** to:

- write the **best resume** for each job description, in the reference format
- find the **missing stories** in your experience
- **interview you** to draw those stories out
- build **your** resume from your own stories, exported as a PDF

## Install (from the DMG)

1. Download **ResumeForge.dmg** from the [`resumeforge-latest` release](../../releases/tag/resumeforge-latest).
2. Open the DMG and drag **ResumeForge** into **Applications**.
3. Open the app once. It's ad-hoc signed and not notarized, so macOS blocks it the first time. Go to **System Settings ▸ Privacy & Security** and click **Open Anyway**.
4. In the app, open **Settings ▸ AI Providers** (⌘,). Paste a key for at least one provider, then click **Test & list models** and pick a current model.
   - **Google Gemini** ([get a key](https://aistudio.google.com/apikey)) has the roomiest free tier, and it's the provider that can read template screenshots.
   - **Groq, Cerebras, Mistral, OpenRouter** and any **OpenAI-compatible** endpoint also work.
   - Drag providers into the order you want them tried. When one runs out of free quota, the app falls back to the next.
   - **Keep my contact details private** is on by default: your name, phone, email and LinkedIn are never sent to a provider, and the resume header is filled in on your Mac. Free tiers may use your inputs to improve their models; Google and Mistral both say so in their terms.
5. Enable the Safari extension. Menu names vary a little by Safari version.
   1. Safari ▸ Settings ▸ Advanced ▸ ✓ *Show features for web developers*.
   2. Develop ▸ ✓ *Allow Unsigned Extensions*. Safari turns this off every time it quits, so re-tick it after each restart. That's the cost of not having a paid Apple Developer account.
   3. Safari ▸ Settings ▸ Extensions ▸ ✓ **ResumeForge Capture**, then allow it on naukri.com and wellfound.com.

## Use

1. **Profile ▸ Import from my existing resume…** — paste your CV text to fill in your roles and education and seed your story bank.
   **Stories ▸ Import…** brings in stories you've already written, from Word, PDF, text/Markdown, RTF, CSV or JSON files, or pasted text. You can drop files onto the window, and one file can hold many stories. Groq splits the text into separate stories without rewriting your wording; without a key, the app splits on headings instead. You review and untick before anything is added, and duplicates are flagged. Each story stays fully editable in the Stories tab. The **⋯** menu exports your stories to Markdown or JSON, so you can back them up or edit them elsewhere and re-import.
2. **Capture while you browse.** On any job page on Naukri, Wellfound or LinkedIn, **click the ResumeForge toolbar icon**. That's it. There's no popup, and the app stays in the background.

   The icon's badge tells you what happened:

   | Badge | Meaning |
   |---|---|
   | **12** | JDs sent today. Resets at midnight. The app's Dock icon and Jobs list show the same count. |
   | **✓** | Just sent. |
   | **DUP** | Already sent before, either the same page or the same title + company. Nothing is sent. |
   | **?** | No job description found on this page. Open the job itself and click again. |
   | **ERR** | Sending failed. A status page opens with the reason and a *Copy job as JSON* fallback. |

   To see recently sent jobs, reset today's count, forget sent jobs (so you can send them again), or turn on **auto-capture** (job pages are captured as soon as you open them, no click), go to **Safari ▸ Settings ▸ Extensions ▸ ResumeForge Capture ▸ Settings**.
3. **Background processing.** Each new JD is automatically run through *clean up → Best Resume → Missing Stories → My Resume*, one job at a time, while you keep browsing. The Jobs list shows each job's progress (Queued, Best resume…, Ready). If a step fails, open the job and press Retry. On Groq's free tier the daily allowance covers roughly 8–12 full jobs. You can choose a shorter depth, or turn this off, under Settings ▸ Background processing. When the daily allowance runs out, the queue pauses and resumes later.
4. **Then**, review each job's tabs: **Job Description → Best Resume → Missing Stories → (Interview) → My Resume → Export PDF**.
   - **Facts from my stories only** keeps every line traceable to something you said.
   - **Allow [VERIFY] placeholders** adds orange, clearly marked guesses for you to confirm or delete.

Your data is stored in `~/Library/Application Support/ResumeForge/ResumeForge.json`. API keys and your GitHub token are kept in the macOS Keychain.

## Templates (copy a CV design from a screenshot)

Go to **Templates** in the sidebar and drop a screenshot of a CV you like. The AI reads the design (fonts, sizes, colours, heading style, single or two-column, section order) and saves it as a template. Fine-tune it in the editor, which shows a live preview. Pick a template on any resume, or set a default under **Settings ▸ Processing**. It approximates the design: photos, icons and charts aren't reproduced.

## Job Feed (collected on GitHub, ranked by fit)

`.github/workflows/job-collector.yml` runs `JobCollector/collect.py` three times a day. It also runs when you press **Collect now**, or when you save your search from the app. It collects jobs for your roles and locations from:

| Source | Secret(s) to add in GitHub ▸ Settings ▸ Secrets ▸ Actions |
|---|---|
| Adzuna (job aggregator, India supported) | `ADZUNA_APP_ID`, `ADZUNA_APP_KEY` — <https://developer.adzuna.com> |
| Jooble | `JOOBLE_KEY` — <https://jooble.org/api/about> |
| JSearch (Google for Jobs, often lists Naukri/LinkedIn jobs) | `RAPIDAPI_KEY` — subscribe to JSearch on RapidAPI (small free quota) |
| **Naukri / Wellfound / LinkedIn job-alert emails** | `IMAP_HOST` (e.g. `imap.gmail.com`), `IMAP_USER`, `IMAP_PASSWORD` (an app password, not your normal password) |
| Any site with an RSS/Atom feed | add the feed URLs in Settings ▸ Job Feed |

The collector never crawls Naukri or Wellfound pages. Naukri's terms prohibit automated crawling, and Wellfound uses bot protection. Instead, set up saved searches and job-alert emails on both sites; the collector reads those emails from your inbox. When you open a posting, the Safari extension captures the full JD, and with **auto-capture** turned on that needs no click.

The feed is published to the `job-feed` release. Because this repo is public, your search terms and the collected listings are visible to anyone. Your API keys stay in GitHub secrets, which are never shown.

In the app, **Job Feed** lists every job with a fit score:
- **Quick score (free, on your Mac):** keyword overlap, title, location and years of experience.
- **AI fit check (top matches only):** a score plus **conflicts** (likely deal-breakers), **gaps** you could address, and strengths.

**Add to my Jobs** sends a job through the background steps to your resume. You can also have strong matches (AI score ≥ 80, no conflicts) added automatically. Set roles, locations, the GitHub token, the number of daily AI checks and the auto-add rules under **Settings ▸ Job Feed**.

## Build

GitHub Actions runs `.github/workflows/resumeforge-dmg.yml` on every push that touches `ResumeForge/`. It runs XcodeGen and `xcodebuild`, ad-hoc signs the app, creates the DMG with `hdiutil`, and publishes it as a Release.

To build locally: `cd ResumeForge && ./scripts/build-dmg.sh`. You need Xcode 15 or newer; the script installs XcodeGen through Homebrew. You can also run `xcodegen generate` and open `ResumeForge.xcodeproj`.

| File | What it does |
|---|---|
| `App/Prompts.swift` | All the AI writing rules: tone, bullet length and truthfulness |
| `App/ResumeEngine.swift` | Steps: clean the JD, write the best resume, find gaps, build your resume, run the interview, import your CV |
| `App/ResumePDFRenderer.swift` | The PDF layout |
| `Extension/Resources/content.js` | Reads the job page. It tries JSON-LD `JobPosting` first, then site selectors, then headings, then the raw page text |
| `Extension/SafariWebExtensionHandler.swift` | Hands the job to the app through a `resumeforge://import?job=…` link |

## Things worth verifying

- **Site selectors.** The Naukri, Wellfound and LinkedIn selectors are best guesses, and these sites change their markup. If a field is empty, the app's **Clean up with AI** step fills it in from the full page text.
- **Hand-off.** It relies on the sandboxed extension being allowed to open the app's URL scheme in the background. If that fails on your macOS version, the badge shows ERR and the status page offers the Copy-as-JSON fallback.
- **Duplicate memory.** The extension remembers sent jobs for a year. If you delete a job in the app and want it back, use *Forget sent jobs* on the status page.
- **Same title, different posting.** Two postings with the same title and company (e.g. different cities) count as duplicates.
- **Groq models.** Groq's model line-up changes often. Use Settings ▸ Test & list models rather than relying on the default.
- **Free-tier limits.** On Groq's free tier, each request has to fit within about 8,000 tokens per minute, counting both input and output. The app learns your limit from Groq's responses and sends your most relevant stories in full and the rest as titles. It runs one request at a time and waits when Groq asks it to. A paid Groq tier raises the limit, and the app then uses the extra room automatically.
