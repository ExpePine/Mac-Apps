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

1. **Profile ▸ Import from my existing resume…** — paste your CV text. This fills in your roles and education and seeds your story bank.
2. On a job page, click the ResumeForge toolbar button, check the fields, and press **Send to ResumeForge**. The app comes to the front with the job.
3. Work through the job's tabs: **Job Description → Best Resume → Missing Stories → (Interview) → My Resume → Export PDF**.
   - **Facts from my stories only** keeps every line traceable to something you said.
   - **Allow [VERIFY] placeholders** adds orange, clearly marked guesses for you to confirm or delete.

If **Send** doesn't work, use **Copy as JSON** in the popup, then in the app go to **Jobs ▸ Add job manually** and paste.

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
- **Hand-off.** It relies on the sandboxed extension being allowed to open the app's URL scheme. If that fails on your macOS version, the Copy-as-JSON fallback always works.
- **Groq models.** Groq's model line-up changes often. Use Settings ▸ Test & list models rather than relying on the default.
