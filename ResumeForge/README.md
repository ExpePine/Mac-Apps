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

## Actions (one place for everything you need to do)

- **From Safari:** right-click a job page, choose **ResumeForge: add action**, then pick **Meet on LinkedIn**, **Message on WhatsApp**, **Call**, **Email follow-up**, **Apply** or **Custom action…** (write your own). The action goes to the app along with that JD, and the JD is added to Jobs if it isn't there yet. The AI then reads the JD and the page to fill in the **company**, the **consultant or recruiter**, their **contact details** if shown, and the **date** from what you wrote (e.g. "tomorrow 11am"). Text you've selected on the page, such as a phone number, is used too. Right-clicking on a recruiter's LinkedIn profile also works: the action is linked to the job with the matching company.
- **In the app:** the **Actions** tab shows every action across all jobs, grouped into Overdue / Today / Upcoming / No date.
  - The **↗** button opens WhatsApp (wa.me with the number), a LinkedIn profile or people search, email, or the job.
  - Each job's page also lists its actions.
- **Workload commentary:** a panel beside the board where the AI looks across all your jobs and actions. It tells you what to do now and why, what's overdue, which jobs have stalled (a resume is ready but nothing has been sent, or a strong match has no action), and what to reschedule. It refreshes after changes, at most every 20 minutes, and when you press ⟳.

The app never sends messages for you. It opens the right place, and you send.

## Connections (LinkedIn networking)

- **When you press Apply**, the app finds key people at that company: the likely hiring manager, recruiters and HR, leaders of the function, and a couple of peers.
  - The AI writes the Google searches (`site:linkedin.com/in "Company" ("Head of Product" OR …)`). They run through **Serper** (Google results) or **Tavily**, and the AI then ranks the results.
  - The top 8 are added to **Connections**, grouped by company. You can also press **Find people** on any job.
- **Messages:** pick a person, a **connection type** and a **tone**, and the AI writes the messages from your real story highlights and their headline.
  - Connection types: referral, hiring manager, recruiter, informational chat, common ground, after applying, or thank you.
  - You get **3 connection notes**, each at most 200 characters (LinkedIn's limit), and **2 longer messages** for after they accept.
  - **Copy & connect** copies the note, opens their profile and logs it in their history. You paste and send it yourself.
  - The AI never invents shared history or mutual connections.
- **History:** drop or paste screenshots of LinkedIn conversations, invites or profiles, or paste the text. The AI reads who it's with and the messages, adds them to that person's history (creating them if needed), and updates the status (requested → connected → replied → meeting).
- Pending and replied connections feed into the **workload commentary**.
- Keys and limits are under **Settings ▸ Networking**:
  - **Serper:** 2,500 free searches, one-time. Use a fresh key, not one that's visible on a web page.
  - **Tavily:** 1,000 a month.
  - A daily search cap.

Free LinkedIn accounts get only a few personalised notes a month. When you run out, connect without a note and send the "after they accept" message.

## Outreach (learn which LinkedIn messages work)

Every note and message you send is logged together with what happened next. The **Outreach** tab has three views: Messages, What works and Coach.

**Ways to log a message:**
- In Connections, **Copy & connect** / **Copy & open** on a draft. The type, purpose and angle are saved with it.
- In Safari, on LinkedIn: right-click → **ResumeForge: LinkedIn → Log the message I'm sending**. This uses the text you've selected, or the text still in the message box.
- **Log this conversation** reads the open chat, so replies are picked up automatically.
- In the app, **Log copied message** / **Log a message**, or drop a screenshot into Connections.

**How outcomes are worked out:**
- A reply from them after your message means *Replied*.
- An accepted invitation means *Accepted*.
- No answer after 14 days means *No response*.
- You can override any outcome yourself.

**What works:** acceptance and reply rates, split by type, purpose, who you wrote to, angle, length, question, company mention, numbers, day and tone. There is also a 12-week chart. Groups smaller than 5 are greyed out.

**Coach:**
- With 5 or more messages that have an outcome, the coach writes your playbook: what's working, what isn't, rules, A/B tests and templates.
- The rules, and your notes that were accepted or answered, are given to the draft writer, so new drafts follow your own results.
- **Check a message** scores a draft before you send it.
- Names and companies are replaced with placeholders before anything goes to the AI.

The app never sends anything on LinkedIn for you.

## Templates (copy a CV design from a screenshot)

Go to **Templates** in the sidebar and drop a screenshot of a CV you like. The AI reads the design (fonts, sizes, colours, heading style, single or two-column, section order) and saves it as a template. Fine-tune it in the editor, which shows a live preview. Pick a template on any resume, or set a default under **Settings ▸ Processing**. It approximates the design: photos, icons and charts aren't reproduced.

## Job Feed (collected on GitHub, ranked by fit)

`.github/workflows/job-collector.yml` runs `JobCollector/collect.py` three times a day. It also runs when you press **Collect now**, or when you save your search from the app. It collects jobs for your roles and locations from:

| Source | Secret(s) to add in GitHub ▸ Settings ▸ Secrets ▸ Actions |
|---|---|
| **My Naukri sheet** (rajakrishna.in/naukri) | none — the app reads it straight from your Mac (see below) |
| Jooble | `JOOBLE_KEY` — <https://jooble.org/api/about>. Capped at 120 requests a month and 480 in total (change `joobleMonthlyBudget` / `joobleTotalBudget` in `config.json`) |
| Adzuna (off by default — its sign-up asks for a card) | `ADZUNA_APP_ID`, `ADZUNA_APP_KEY` — <https://developer.adzuna.com> |
| JSearch (Google for Jobs, often lists Naukri/LinkedIn jobs) | `RAPIDAPI_KEY` — subscribe to JSearch on RapidAPI (small free quota) |
| **Naukri / Wellfound / LinkedIn job-alert emails** | `IMAP_HOST` (e.g. `imap.gmail.com`), `IMAP_USER`, `IMAP_PASSWORD` (an app password, not your normal password) |
| Any site with an RSS/Atom feed | add the feed URLs in Settings ▸ Job Feed |

The collector never crawls Naukri or Wellfound pages. Naukri's terms prohibit automated crawling, and Wellfound uses bot protection. Instead, set up saved searches and job-alert emails on both sites; the collector reads those emails from your inbox. When you open a posting, the Safari extension captures the full JD, and with **auto-capture** turned on that needs no click.

**My Naukri sheet.** The app reads the same jobs you see in *Sheet View* on rajakrishna.in/naukri, using the site's `fetch_stored_jobs` endpoint. Each job comes with its full JD, company, experience, location, category and Naukri link. It fetches from your Mac when the app opens and every 2 hours (or press ⟳ in Job Feed), then merges the jobs into the Job Feed, where they're scored and fit-checked like the rest. You can turn it off or change the endpoint in Settings ▸ Job Feed.

The feed is published to the `job-feed` release. Because this repo is public, your search terms and the collected listings are visible to anyone. Your API keys stay in GitHub secrets, which are never shown.

In the app, **Job Feed** lists every job with a fit score:
- **Quick score (free, on your Mac):** keyword overlap, title, location and years of experience.
- **AI fit check (top matches only):** a score plus **conflicts** (likely deal-breakers), **gaps** you could address, and strengths.

**Apply** (green button) opens the job's link, such as the Naukri link from your sheet, so you can apply. The app then tracks the application: the job moves into Jobs marked *Applied*, a done "Applied" action is logged, and a follow-up action is set for 5 days later.

**Sorting:** Best match, AI-checked first, Newest, or Company A–Z. The list re-sorts by itself as background checks finish.

**Background fit checks:** these run all the time, up to 60 a day by default. Unchecked jobs with the best quick score go first. Then the app re-checks any job that was judged against an older version of your stories or profile.

**Add to my Jobs** sends a job through the background steps to your resume. You can also have strong matches (AI score ≥ 80, no conflicts) added automatically. Set roles, locations, the GitHub token, the number of daily AI checks and the auto-add rules under **Settings ▸ Job Feed**.

## Google Sheets, Saved JDs and Lines

- **Google Sheets:** Sheet 3 and Sheet 4 of your job sheet are read straight into the Job Feed every 2 hours, or when you press Refresh. Columns are worked out from the headers, or from the data when there are no headers. To add or fix a tab, go to Job Feed → Settings → Google Sheets and paste the tab's link (the one with `gid=`). The sheet must be shared as "anyone with the link can view".
- **Saved JDs:** press ♥ on any job. Saved jobs are grouped by Role, Domain, Seniority or Work mode (auto-classified), and they are fit-checked first.
- **Lines:** a bank of reusable sentences.
  - **Compress my stories** turns each story into bullets, a one-liner and an opener.
  - **Lines** on any job writes bullets, a summary line and openers for that JD.
  - Starred lines are passed to the resume writer as your preferred wording.

## Faster AI fit checks

- Every provider that has a key runs its own worker at the same time.
- Each JD is cut down to a short digest of its requirements, and up to 25 JDs go in one request.
- You can set an optional *fast model* per provider in Settings for bulk checks.
- Duplicate postings (same title and company) are checked only once.
- Re-checks only run for jobs that scored 55 or more, and only when you add or remove stories.
- A time budget (60 minutes by default) caps the queue; the rest waits for the next run. Job Feed shows an estimated finish time and the measured speed.

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
