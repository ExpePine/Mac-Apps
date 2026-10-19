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
4. In the app, open **Settings** (⌘,), paste your Groq key from <https://console.groq.com/keys>, and click **Test & list models**. If the default model isn't listed, pick a large text model from the list.
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

   To see recently sent jobs, reset today's count, or forget sent jobs (so you can send them again), go to **Safari ▸ Settings ▸ Extensions ▸ ResumeForge Capture ▸ Settings**.
3. **Later, in the app**, work through each job's tabs: **Job Description → Best Resume → Missing Stories → (Interview) → My Resume → Export PDF**.
   - **Facts from my stories only** keeps every line traceable to something you said.
   - **Allow [VERIFY] placeholders** adds orange, clearly marked guesses for you to confirm or delete.

Your data is stored in `~/Library/Application Support/ResumeForge/ResumeForge.json`. Your Groq key is kept in the macOS Keychain.

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
