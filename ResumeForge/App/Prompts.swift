import Foundation

/// All prompts in one place so you can tune the writing style without touching app logic.
enum Prompts {

    static let system = """
    You are an elite resume writer and career coach for senior professionals in the Indian job market \
    (Naukri, Wellfound, LinkedIn). You know how recruiters skim (6–8 seconds) and how ATS keyword matching works. \
    You write crisp, specific, achievement-led English (Indian English spelling). \
    You ALWAYS reply with a single valid JSON object and nothing else — no markdown, no commentary.
    """

    // Shared description of the reference layout (the screenshot format).
    static let resumeSchema = """
    RESUME JSON SHAPE (mirrors the reference resume layout exactly):
    {
      "name": "FULL NAME",
      "contactLine": "City, Country | P: +91 phone | email",
      "summary": "one paragraph",
      "experience": [
        {"company": "COMPANY NAME", "location": "City, Country", "title": "Job Title",
         "dates": "Month YYYY - Present",
         "bullets": [{"text": "...", "sources": ["<story id from the [brackets]>", ...]}]}
      ],
      "achievements": [
        {"label": "Two-To-Four Word Label", "text": "1–2 sentences.", "subItems": [], "sources": ["<story id>"]}
      ],
      "education": [{"qualification": "DEGREE NAME", "institution": "Institute", "location": "City, Country", "year": "Graduated: YYYY"}],
      "additional": [{"label": "Languages", "value": "..."}, {"label": "Certifications", "value": "..."}, {"label": "Technical Skills", "value": "comma-separated"}]
    }

    WRITING RULES:
    - summary: 4–6 sentences, no "I". Open with "<Identity> with <N>+ years of expertise in <3 focus areas>". \
    Then proof of leadership/scale, recognitions, and a closing strength. Weave in the top JD keywords naturally.
    - experience: reverse chronological. Recent/relevant roles 4–6 bullets, older roles 1–3. \
    Each bullet is ONE sentence of 18–35 words: strong past-tense verb + what you did + scope (team, budget, volume, users) + result.
    - achievements: 5–8 items. Each "label" is a 2–4 word headline (e.g. "Team Leadership and Development"); \
    "text" is the proof. Use "subItems" only for a list of awards/recognitions.
    - Mirror the JD's vocabulary where it honestly describes the same thing (ATS).
    - Must fit on 1–2 A4 pages. No first person, no clichés like "results-driven" or "go-getter".
    """

    // MARK: Job parsing

    static func parseJob(pageText: String, hint: JobPosting) -> String {
        """
        TASK: Extract structured fields from this captured job page.
        Known so far (may be empty or wrong): title="\(hint.title)", company="\(hint.company)", location="\(hint.location)".

        Return:
        {"title": "", "company": "", "location": "", "experience": "", "salary": "", "skills": [],
         "description": "the cleaned, complete job description — about the company/role, responsibilities, requirements, nice-to-haves. Remove navigation, ads, 'similar jobs', reviews and footer text. Keep the original wording; use line breaks and • bullets."}
        Use "" when unknown. Never invent anything.

        PAGE TEXT:
        \(pageText)
        """
    }

    // MARK: Benchmark ("best resume" for the JD)

    static func benchmark(job: JobPosting, budget: Int) -> String {
        """
        TASK: Write the BENCHMARK resume for the job below — the resume of the ideal, top-5% candidate this employer \
        would shortlist instantly. It is a TARGET to aim for, not a real person.
        - name: "IDEAL CANDIDATE"; contactLine: "City, India | P: +91 XXXXXXXXXX | candidate@email.com".
        - Use 3 realistic roles with descriptive placeholder employers, e.g. "LEADING FINTECH COMPANY (comparable to the employer)".
        - Make every bullet show exactly the kind of evidence this JD screens for, with plausible, specific metrics.
        - All "sources" arrays are [].
        - Also return "keywords": the 15–25 most important ATS keywords/phrases from the JD, most important first.

        \(resumeSchema)

        Return: {"resume": <RESUME JSON>, "keywords": [..]}

        JOB:
        \(jobBlock(job, maxChars: budget))
        """
    }

    // MARK: Gap analysis → missing stories

    static func gaps(job: JobPosting, benchmark: ResumeDoc, profile: Profile, stories: [Story], budget: Int) -> String {
        let prof = profileBlock(profile, maxChars: 1200)
        let jd = jobBlock(job, maxChars: Int(Double(budget) * 0.28))
        let bench = resumeText(benchmark, maxChars: Int(Double(budget) * 0.22))
        let storyBudget = max(800, budget - prof.count - jd.count - bench.count)
        let context: String = job.title + " " + job.description + " " + job.keywords.joined(separator: " ")
        let storyList = storiesBlock(stories, relevantTo: context, maxChars: storyBudget)
        return """
        TASK: Compare the CANDIDATE STORIES with what the JOB and the BENCHMARK resume demand. \
        Find the missing or weak stories — evidence the employer will look for that the candidate has NOT yet written down.

        Return:
        {"gaps": [{"theme": "short title", "priority": "high|medium|low",
                   "whyItMatters": "1–2 sentences tied to specific JD requirements",
                   "benchmarkExample": "one bullet from the benchmark showing what strong evidence looks like",
                   "coveredBy": ["<story ids that partially cover it>"],
                   "questions": ["3–4 probing questions"]}],
         "strengths": ["themes the stories already cover well"]}

        RULES:
        - 5–8 gaps, highest priority first. Skip anything the stories already evidence well.
        - Questions must be concrete and answerable from memory, ONE idea each, and reference the candidate's \
        real companies/roles where possible (e.g. "At Mantra Softech, have you ever…?"). Ask for numbers, scale, \
        stakeholders, tools and outcomes. Never assume the answer.

        JOB:
        \(jd)

        BENCHMARK RESUME (target):
        \(bench)

        CANDIDATE PROFILE:
        \(prof)

        CANDIDATE STORIES (most relevant first; [id] in brackets):
        \(storyList)
        """
    }

    // MARK: Your resume from your stories

    static func tailored(job: JobPosting?, benchmark: ResumeDoc?, profile: Profile,
                         stories: [Story], allowPlaceholders: Bool, budget: Int) -> String {
        let target: String
        let prof = profileBlock(profile, maxChars: 1500)
        if let job {
            let benchChars = Int(Double(budget) * 0.12)
            let bench = (benchmark != nil && benchChars >= 700)
                ? "BENCHMARK RESUME (use it for emphasis, ordering and vocabulary — NOT as a source of facts):\n" + resumeText(benchmark!, maxChars: benchChars)
                : ""
            target = """
            TARGET JOB:
            \(jobBlock(job, maxChars: Int(Double(budget) * 0.25)))

            \(bench)
            """
        } else {
            target = """
            TARGET: a strong general-purpose resume for the candidate's headline "\(profile.headline)". \
            Pick the stories that best show seniority, scale and measurable impact.
            """
        }

        let truth = """
        TRUTH RULES (always):
        - Every claim must come from the CANDIDATE PROFILE or STORIES. You MAY rephrase, combine, reorder, choose emphasis, \
        and use the JD's vocabulary when it honestly describes the same thing.
        - NEVER invent numbers, employers, titles, dates, tools, certifications, awards or outcomes. If a story has no number, \
        write a strong bullet without one.
        - Every experience bullet and achievement lists in "sources" the id(s) of the stories it is based on. \
        Use [] only for facts taken directly from the profile.
        - Put each bullet under the role whose company matches the story's company. Use the profile's roles for company/title/location/dates.
        - Name/contactLine/education/additional come from the profile.
        """

        let mode = allowPlaceholders ? """
        PLACEHOLDER MODE (ON):
        - For important JD requirements the stories don't cover, you MAY add bullets that start with "[VERIFY] " and use \
        bracketed blanks for unknowns, e.g. "[VERIFY] Negotiated with [X] component vendors, cutting BOM cost by [Y]%." \
        Their "sources" are []. Add at most 1–2 per role. These are prompts for the candidate to confirm or delete — never facts.
        """ : """
        STRICT MODE: no placeholders. Leave uncovered requirements out of the resume and list them in "missing".
        """

        let context: String
        if let job {
            context = job.title + " " + job.description + " " + job.keywords.joined(separator: " ")
        } else {
            context = profile.headline
        }
        let storyList = storiesBlock(stories, relevantTo: context, maxChars: max(1500, budget - prof.count - target.count))

        return """
        TASK: Write the candidate's resume.

        \(target)

        \(truth)

        \(mode)

        \(resumeSchema)

        Return: {"resume": <RESUME JSON>, "missing": ["short descriptions of important requirements with no supporting story"]}

        CANDIDATE PROFILE:
        \(prof)

        CANDIDATE STORIES (most relevant first; [id] in brackets — use these ids in "sources"):
        \(storyList)
        """
    }

    // MARK: Interviewer

    static func interviewer(profile: Profile, stories: [Story], job: JobPosting?, gap: StoryGap?, draft: Story?) -> String {
        var focus = "FOCUS: General — find the candidate's strongest untold work stories (big wins, turnarounds, firsts, scale, awards). Start with their most recent role."
        if let gap {
            focus = """
            FOCUS GAP: "\(gap.theme)"
            Why it matters: \(gap.whyItMatters)
            What strong evidence looks like: \(gap.benchmarkExample)
            Starter questions you may adapt: \(gap.questions.joined(separator: " | "))
            """
        }
        if let job { focus += "\nTARGET JOB: \(job.title) at \(job.company). Key requirements:\n\(job.description.prefix(1500))" }

        let titles = clip(stories.map { "\($0.title) (\($0.company))" }.joined(separator: "; "), 1200)
        let draftJSON: String = {
            guard let d = draft else { return "null" }
            return jsonString(["title": d.title, "company": d.company, "role": d.role, "period": d.period,
                               "text": d.text, "metrics": d.metrics, "skills": d.skills])
        }()

        return """
        \(system)

        ROLE: You are a warm but sharp career interviewer. Your job is to PROBE until you have a resume-ready story, \
        then help the candidate see it in the best honest light.

        Draw out, one question at a time:
        1. Context — company, role, period, what was at stake and why it mattered to the business.
        2. Their PERSONAL actions (not the team's) — decisions, leadership, influence, hard trade-offs.
        3. Scale — team size, budget, revenue, units, users, sites, clients, geographies, timelines.
        4. Results — %, ₹, time saved, defects reduced, revenue, ratings, awards, before/after. Approximations are fine (record as "~").
        5. Proof — recognition, who noticed, what changed afterwards.

        RULES:
        - Exactly ONE question per message, max 2 short sentences, plain language. Briefly reflect what they said, then ask.
        - If an answer is vague ("improved efficiency"), ask for the concrete version ("roughly how much faster — hours to minutes?").
        - If they don't know a number, offer proxies (before vs after, how many people, how often) or move on. Never pressure.
        - NEVER suggest achievements, numbers or facts they haven't said. Don't put words in their mouth.
        - After every answer, update "draft" using ONLY what the candidate has said. "text" is a 3–6 sentence first-person \
        narrative in Situation → Action → Result order.
        - When the draft has context + personal actions + at least one concrete result (or they can't add more), set \
        "readyToSave": true and tell them it's ready to save, asking if anything is missing.
        - Don't re-collect stories they already have (listed below) unless deepening one.

        \(focus)

        CANDIDATE PROFILE:
        \(profileBlock(profile, maxChars: 1200))

        EXISTING STORY TITLES: \(titles)

        CURRENT DRAFT: \(draftJSON)

        Return: {"message": "your next message to the candidate",
                 "draft": {"title": "", "company": "", "role": "", "period": "", "text": "", "metrics": [], "skills": []} or null,
                 "readyToSave": false}
        """
    }

    // MARK: Import an existing resume

    static func importResume(text: String) -> String {
        """
        TASK: The candidate pasted their existing resume / LinkedIn profile. Extract their profile and turn their \
        experience into raw STORIES the app can reuse.

        Return:
        {"profile": {"name": "", "headline": "", "location": "", "phone": "", "email": "", "linkedin": "",
                     "roles": [{"company": "", "title": "", "location": "", "start": "Month YYYY", "end": "Month YYYY or Present"}],
                     "education": [{"qualification": "", "institution": "", "location": "", "year": ""}],
                     "languages": "", "certifications": "", "technicalSkills": ""},
         "stories": [{"title": "short name of the initiative", "company": "", "role": "", "period": "",
                      "text": "first-person narrative of what happened, using only facts in the text",
                      "metrics": ["numbers exactly as stated"], "skills": []}]}

        RULES: merge bullets about the same initiative into one story; keep only facts present in the text; \
        do not embellish or add numbers; "" when unknown.

        TEXT:
        \(text)
        """
    }

    // MARK: Import stories the candidate already wrote

    static func splitStories(text: String, source: String, part: Int, of total: Int, companies: [String]) -> String {
        """
        TASK: The candidate is importing STORIES they already wrote about their own work. \
        Split the text into separate stories — one per initiative, project, achievement or problem solved.

        Return:
        {"stories": [{"title": "", "company": "", "role": "", "period": "", "text": "", "metrics": [], "skills": []}]}

        RULES:
        - "text" must be the candidate's ORIGINAL wording for that story. Copy their sentences; you may only drop \
        headings/numbering and re-join lines broken by the file format. Never rewrite, shorten, summarise, embellish or add facts.
        - "title": their heading if there is one, otherwise a short name (max 8 words) for the initiative.
        - "company", "role", "period": only when stated in or around the story (headings count). Prefer the exact \
        spelling from KNOWN COMPANIES when the text clearly refers to one. Otherwise "".
        - "metrics": numbers and results exactly as written (e.g. "reduced RMA by 40%", "team of 12").
        - "skills": skills/tools/methods the story demonstrates, as written or obvious (max 8).
        - Skip anything that isn't a work story: contact details, tables of contents, page headers/footers, generic notes.
        - If a story continues from a previous part of the file, still return it (the app merges duplicates).

        KNOWN COMPANIES: \(companies.isEmpty ? "(none yet)" : companies.joined(separator: "; "))

        TEXT (from "\(source)", part \(part) of \(total)):
        \(text)
        """
    }

    // MARK: - Helpers

    static func jobBlock(_ j: JobPosting, maxChars: Int = 12000) -> String {
        let head = """
        Title: \(j.title)
        Company: \(j.company)
        Location: \(j.location)
        Experience: \(j.experience)
        Skills listed: \(j.skills.joined(separator: ", "))
        Description:

        """
        return head + clip(j.description, max(400, maxChars - head.count))
    }

    /// Compact plain-text profile (cheaper in tokens than JSON).
    static func profileBlock(_ p: Profile, maxChars: Int = 2000) -> String {
        var lines: [String] = []
        if Redactor.enabled {
            lines.append("Name: (added locally — not needed)")
            if !p.location.isEmpty { lines.append("Based in: \(p.location)") }
        } else {
            lines.append("Name: \(p.name)")
            if !p.contactLine.isEmpty { lines.append("Contact: \(p.contactLine)") }
        }
        if !p.headline.isEmpty { lines.append("Headline: \(p.headline)") }
        if !p.roles.isEmpty {
            lines.append("Roles:")
            lines += p.roles.map { "- \($0.title) | \($0.company) | \($0.location) | \($0.start) - \($0.end)" }
        }
        if !p.education.isEmpty {
            lines.append("Education:")
            lines += p.education.map { "- \($0.qualification) | \($0.institution) | \($0.location) | \($0.year)" }
        }
        if !p.languages.isEmpty { lines.append("Languages: \(p.languages)") }
        if !p.certifications.isEmpty { lines.append("Certifications: \(p.certifications)") }
        if !p.technicalSkills.isEmpty { lines.append("Technical skills: \(p.technicalSkills)") }
        return clip(lines.joined(separator: "\n"), maxChars)
    }

    /// Short story id used in prompts (first 8 characters of the UUID). Mapped back by the engine.
    static func shortID(_ s: Story) -> String { String(s.id.uuidString.prefix(8)).lowercased() }

    /// Stories ranked by relevance to `relevantTo`, packed into `maxChars`:
    /// the most relevant get their full text, then shortened text, then title-only lines.
    static func storiesBlock(_ stories: [Story], relevantTo context: String, maxChars: Int) -> String {
        if stories.isEmpty { return "(no stories yet)" }
        let ranked = rank(stories, by: context)
        var out = ""
        var omitted = 0
        for (i, st) in ranked.enumerated() {
            let head = "[\(shortID(st))] \(st.title) | \(st.company) | \(st.role) | \(st.period)"
            let metrics = st.metrics.isEmpty ? "" : "\nMetrics: \(st.metrics.joined(separator: "; "))"
            let remaining = maxChars - out.count
            let left = ranked.count - i
            // Leave room for at least a title line for every remaining story.
            let share = max(120, (remaining - left * 90) / max(1, min(left, 4)))
            let full = head + metrics + "\n" + st.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            if full.count <= share {
                out += full
            } else if share >= 400 {
                out += head + metrics + "\n" + clip(st.text, share - head.count - metrics.count - 4) + "\n\n"
            } else if remaining > head.count + 2 {
                out += head + "\n"
            } else {
                omitted += 1
            }
        }
        if omitted > 0 { out += "(+\(omitted) more stories not shown)" }
        return out
    }

    private static let stopwords: Set<String> = ["with", "that", "this", "from", "have", "will", "your", "their", "they", "them",
        "were", "been", "into", "about", "which", "while", "would", "should", "could", "there", "what", "when", "where",
        "also", "more", "than", "such", "able", "work", "working", "team", "role", "experience", "years", "including"]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopwords.contains($0) })
    }

    static func rank(_ stories: [Story], by context: String) -> [Story] {
        let ctx = words(context)
        func score(_ s: Story) -> Double {
            let w = words(s.title + " " + s.text + " " + s.skills.joined(separator: " "))
            return Double(w.intersection(ctx).count) + 1.5 * Double(s.metrics.count)
        }
        return stories.enumerated()
            .sorted { (a, b) in
                let sa = score(a.element), sb = score(b.element)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

    static func resumeText(_ r: ResumeDoc, maxChars: Int = 8000) -> String {
        var out = "SUMMARY: \(r.summary)\n"
        for role in r.experience {
            out += "\n\(role.company) — \(role.title) (\(role.dates))\n"
            out += role.bullets.map { "• \($0.text)" }.joined(separator: "\n")
        }
        if !r.achievements.isEmpty {
            out += "\n\nKEY ACHIEVEMENTS:\n" + r.achievements.map { "• \($0.label): \($0.text)" }.joined(separator: "\n")
        }
        return clip(out, maxChars)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        return String(s.prefix(max(0, n - 1))) + "…"
    }

    static func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}
