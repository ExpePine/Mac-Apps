import Foundation

/// The AI workflows: parse JD → benchmark resume → missing stories → your resume → interview.
extension AppStore {

    // MARK: Budgeted AI call

    /// Builds the prompt to fit the account's tokens-per-minute limit (free tier: 8,000 per request incl. output),
    /// shrinking the variable parts until it fits. If Groq still says "too large", it learns the real limit and rebuilds once.
    func ask(system: String = Prompts.system, output: Int, temperature: Double,
             build: (Int) -> String) async throws -> [String: Any] {
        var lastError: Error?
        for _ in 0..<2 {
            let limit = GroqClient.tpmLimit(for: model)
            let out = min(output, Int(Double(limit) * 0.45))
            let allowed = max(1200, limit - out - 350)
            var budget = allowed * 3
            var prompt = build(budget)
            for _ in 0..<5 {
                let est = GroqClient.estimateTokens(system) + GroqClient.estimateTokens(prompt) + 20
                if est <= allowed { break }
                budget = max(1200, budget - (est - allowed) * 3 - 300)
                prompt = build(budget)
            }
            do {
                return try await client.json(system: system, user: prompt, temperature: temperature, maxTokens: out)
            } catch let e as GroqClient.RequestTooLarge {
                lastError = e      // limit is now learned — loop rebuilds smaller
            }
        }
        throw lastError ?? GroqError(message: "Request too large for your Groq plan.")
    }

    /// Maps the short story ids used in prompts ("1a2b3c4d") back to full ids.
    func resolveStoryIDs(_ ids: [String]) -> [String] {
        let all = data.stories.map(\.id.uuidString)
        return ids.compactMap { raw in
            let k = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
            guard !k.isEmpty else { return nil }
            return all.first { $0.lowercased() == k || $0.lowercased().hasPrefix(k) }
        }
    }

    // MARK: Clean up a captured page into a proper JD

    func parseJob(_ id: UUID) async throws {
        guard let i = jobIndex(id) else { return }
        let j = data.jobs[i]
        // Prefer the extracted description; fall back to the whole page text.
        let input = j.description.count >= 600 ? j.description : (j.rawText.count > j.description.count ? j.rawText : j.description)
        guard !input.isEmpty else { return }

        let o = try await ask(output: 2500, temperature: 0.1) { budget in
            Prompts.parseJob(pageText: String(input.prefix(max(1500, budget - 900))), hint: j)
        }
        guard let k = jobIndex(id) else { return }
        var job = data.jobs[k]
        func fill(_ kp: WritableKeyPath<JobPosting, String>, _ key: String) {
            let v = J.str(o, key)
            if job[keyPath: kp].isEmpty, !v.isEmpty { job[keyPath: kp] = v }
        }
        fill(\.title, "title")
        fill(\.company, "company")
        fill(\.location, "location")
        fill(\.experience, "experience")
        fill(\.salary, "salary")
        let desc = J.str(o, "description")
        if desc.count > 150 { job.description = desc }
        if job.skills.isEmpty { job.skills = J.strings(o, "skills") }
        job.parsed = true
        data.jobs[k] = job
    }

    // MARK: The "best resume" for this JD

    func generateBenchmark(_ id: UUID) async throws {
        guard let i = jobIndex(id) else { return }
        let job = data.jobs[i]
        let o = try await ask(output: 3000, temperature: 0.6) { budget in
            Prompts.benchmark(job: job, budget: max(1500, budget - 3200))
        }
        let resumeJSON = J.dict(o, "resume") ?? o
        guard let k = jobIndex(id) else { return }
        data.jobs[k].benchmark = ResumeDoc(json: resumeJSON, mode: "benchmark")
        data.jobs[k].keywords = J.strings(o, "keywords")
    }

    // MARK: Missing stories

    func analyzeGaps(_ id: UUID) async throws {
        if jobIndex(id).flatMap({ data.jobs[$0].benchmark }) == nil {
            busy = "Writing the benchmark resume first…"
            try await generateBenchmark(id)
            busy = "Finding missing stories…"
        }
        guard let i = jobIndex(id), let bench = data.jobs[i].benchmark else { return }
        let job = data.jobs[i], profile = data.profile, stories = data.stories
        let o = try await ask(output: 2000, temperature: 0.4) { budget in
            Prompts.gaps(job: job, benchmark: bench, profile: profile, stories: stories, budget: max(2500, budget - 1500))
        }
        let gaps = J.dicts(o, "gaps").map {
            StoryGap(theme: J.str($0, "theme"),
                     priority: J.str($0, "priority").lowercased().isEmpty ? "medium" : J.str($0, "priority").lowercased(),
                     whyItMatters: J.str($0, "whyItMatters"),
                     benchmarkExample: J.str($0, "benchmarkExample"),
                     questions: J.strings($0, "questions"),
                     coveredBy: resolveStoryIDs(J.strings($0, "coveredBy")))
        }.filter { !$0.theme.isEmpty }
        guard let k = jobIndex(id) else { return }
        // Keep answered/skipped status for gaps that come back with the same theme.
        let previous = Dictionary(data.jobs[k].gaps.map { ($0.theme.lowercased(), $0.status) }, uniquingKeysWith: { a, _ in a })
        data.jobs[k].gaps = gaps.map { g in
            var g = g
            if let st = previous[g.theme.lowercased()] { g.status = st }
            return g
        }
        data.jobs[k].strengths = J.strings(o, "strengths")
    }

    // MARK: Your resume (per job, or the master resume)

    func buildTailored(_ id: UUID, allowPlaceholders: Bool) async throws {
        try requireMaterial()
        guard let i = jobIndex(id) else { return }
        let job = data.jobs[i]
        let profile = data.profile, stories = data.stories
        let o = try await ask(output: 3000, temperature: 0.35) { budget in
            Prompts.tailored(job: job, benchmark: job.benchmark, profile: profile, stories: stories,
                             allowPlaceholders: allowPlaceholders, budget: max(2500, budget - 5200))
        }
        guard let k = jobIndex(id) else { return }
        data.jobs[k].tailored = finalize(ResumeDoc(json: J.dict(o, "resume") ?? o,
                                                   mode: allowPlaceholders ? "placeholders" : "strict"))
        data.jobs[k].tailoredMissing = J.strings(o, "missing")
    }

    func buildMaster(allowPlaceholders: Bool) async throws {
        try requireMaterial()
        let profile = data.profile, stories = data.stories
        let o = try await ask(output: 3000, temperature: 0.35) { budget in
            Prompts.tailored(job: nil, benchmark: nil, profile: profile, stories: stories,
                             allowPlaceholders: allowPlaceholders, budget: max(2500, budget - 5200))
        }
        data.masterResume = finalize(ResumeDoc(json: J.dict(o, "resume") ?? o,
                                               mode: allowPlaceholders ? "placeholders" : "strict"))
        data.masterMissing = J.strings(o, "missing")
    }

    private func requireMaterial() throws {
        if data.stories.isEmpty && data.profile.roles.isEmpty {
            throw GroqError(message: "Add your profile (Profile → Import from my existing resume) or a few stories first — the resume is built only from your own material.")
        }
    }

    /// Fill header/education/details from the profile when the model leaves them blank,
    /// and drop story IDs that don't exist.
    private func finalize(_ doc: ResumeDoc) -> ResumeDoc {
        var d = doc
        let p = data.profile
        if !p.name.isEmpty { d.name = p.name }
        if !p.contactLine.isEmpty { d.contactLine = p.contactLine }
        if d.education.isEmpty {
            d.education = p.education.map {
                ResumeEducation(qualification: $0.qualification, institution: $0.institution,
                                location: $0.location, year: $0.year.isEmpty ? "" : "Graduated: \($0.year)")
            }
        }
        if d.additional.isEmpty {
            d.additional = [("Languages", p.languages), ("Certifications", p.certifications), ("Technical Skills", p.technicalSkills)]
                .filter { !$0.1.isEmpty }
                .map { LabeledLine(label: $0.0, value: $0.1) }
        }
        for r in d.experience.indices {
            for b in d.experience[r].bullets.indices {
                d.experience[r].bullets[b].sources = resolveStoryIDs(d.experience[r].bullets[b].sources)
            }
        }
        for a in d.achievements.indices {
            d.achievements[a].sources = resolveStoryIDs(d.achievements[a].sources)
        }
        return d
    }

    // MARK: Interview

    func startInterview(jobID: UUID?, gapID: UUID?) {
        data.interview = InterviewSession(focusJobID: jobID, focusGapID: gapID)
        section = .interview
        run("Preparing first question…") { try await self.interviewSend(nil) }
    }

    func interviewSend(_ text: String?) async throws {
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            data.interview.turns.append(ChatTurn(role: "user", text: t))
        }
        let session = data.interview
        let job = session.focusJobID.flatMap { id in data.jobs.first { $0.id == id } }
        let gap = session.focusGapID.flatMap { gid in job?.gaps.first { $0.id == gid } }

        let systemPrompt = Prompts.interviewer(profile: data.profile, stories: data.stories,
                                               job: job, gap: gap, draft: session.draft)
        var messages = [GroqClient.Message(role: "system", content: systemPrompt)]
        if session.turns.isEmpty {
            messages.append(.init(role: "user", content: "(Start the interview with your first question.)"))
        } else {
            // Keep the most recent turns that fit the per-minute budget (the draft carries what was said earlier).
            let output = 900
            var room = GroqClient.tpmLimit(for: model) - output - 400 - GroqClient.estimateTokens(systemPrompt)
            var recent: [GroqClient.Message] = []
            for t in session.turns.reversed() {
                let cost = GroqClient.estimateTokens(t.text) + 8
                if cost > room && !recent.isEmpty { break }
                room -= cost
                recent.insert(.init(role: t.role, content: String(t.text.prefix(4000))), at: 0)
            }
            if recent.first?.role == "assistant" {
                recent.insert(.init(role: "user", content: "(Continuing the interview.)"), at: 0)
            }
            messages += recent
        }

        let o = try await client.json(messages: messages, temperature: 0.5, maxTokens: 900)
        let reply = J.str(o, "message")
        data.interview.turns.append(ChatTurn(role: "assistant",
                                             text: reply.isEmpty ? "Could you tell me a bit more about that?" : reply))
        if let d = J.dict(o, "draft") {
            var s = Story(json: d, origin: "interview")
            if let existing = data.interview.draft { s.id = existing.id; s.createdAt = existing.createdAt }
            if !s.text.isEmpty || !s.title.isEmpty { data.interview.draft = s }
        }
        data.interview.readyToSave = J.bool(o, "readyToSave")
    }

    func saveInterviewDraft() {
        guard var s = data.interview.draft, !s.text.isEmpty else { return }
        s.updatedAt = Date()
        s.origin = "interview"
        data.stories.insert(s, at: 0)
        if let jid = data.interview.focusJobID, let gid = data.interview.focusGapID,
           let ji = jobIndex(jid), let gi = data.jobs[ji].gaps.firstIndex(where: { $0.id == gid }) {
            data.jobs[ji].gaps[gi].status = .answered
            data.jobs[ji].gaps[gi].coveredBy.append(s.id.uuidString)
        }
        data.interview = InterviewSession()
    }

    // MARK: Import an existing resume

    func importResume(text: String) async throws {
        // Long CVs are read in parts so each request fits the per-minute limit.
        let limit = GroqClient.tpmLimit(for: model)
        let chunkChars = max(3000, Int(Double(limit - 1200) / 2.2) * 3 - 2200)
        let parts = StoryImport.chunks(text, maxChars: chunkChars)
        var o: [String: Any] = [:]
        var extraStories: [[String: Any]] = []
        for (n, part) in parts.enumerated() {
            if parts.count > 1 { busy = "Reading your resume (part \(n + 1) of \(parts.count))…" }
            let r = try await ask(output: 3500, temperature: 0.1) { _ in Prompts.importResume(text: part) }
            if n == 0 { o = r } else { extraStories += J.dicts(r, "stories") }
        }
        if !extraStories.isEmpty { o["stories"] = J.dicts(o, "stories") + extraStories }
        let p = J.dict(o, "profile")
        var prof = data.profile
        func fill(_ kp: WritableKeyPath<Profile, String>, _ key: String) {
            let v = J.str(p, key)
            if prof[keyPath: kp].isEmpty, !v.isEmpty { prof[keyPath: kp] = v }
        }
        fill(\.name, "name"); fill(\.headline, "headline"); fill(\.location, "location")
        fill(\.phone, "phone"); fill(\.email, "email"); fill(\.linkedin, "linkedin")
        fill(\.languages, "languages"); fill(\.certifications, "certifications"); fill(\.technicalSkills, "technicalSkills")
        if prof.roles.isEmpty {
            prof.roles = J.dicts(p, "roles").map {
                RoleEntry(company: J.str($0, "company"), title: J.str($0, "title"), location: J.str($0, "location"),
                          start: J.str($0, "start"), end: J.str($0, "end").isEmpty ? "Present" : J.str($0, "end"))
            }
        }
        if prof.education.isEmpty {
            prof.education = J.dicts(p, "education").map {
                EducationEntry(qualification: J.str($0, "qualification"), institution: J.str($0, "institution"),
                               location: J.str($0, "location"), year: J.str($0, "year"))
            }
        }
        data.profile = prof
        let stories = J.dicts(o, "stories").map { Story(json: $0, origin: "import") }.filter { !$0.text.isEmpty }
        data.stories.insert(contentsOf: stories, at: 0)
    }

    // MARK: Import stories from files / pasted text

    /// Splits free text into stories. With AI: Groq finds the stories and keeps your wording.
    /// Without AI (or no key): one story per heading / block.
    func parseStories(from text: String, source: String, useAI: Bool,
                      progress: @escaping (String) -> Void = { _ in }) async throws -> [Story] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        guard useAI, !Keychain.load().isEmpty else { return StoryImport.splitByHeadings(clean) }

        let companies = Array(Set(data.profile.roles.map(\.company).filter { !$0.isEmpty })).sorted()
        // The reply repeats your text, so each part gets less than half the per-minute budget.
        let limit = GroqClient.tpmLimit(for: model)
        let chunkChars = max(2500, Int(Double(limit - 1300) / 2.3) * 3 - 1800)
        let parts = StoryImport.chunks(clean, maxChars: chunkChars)
        var out: [Story] = []
        for (i, part) in parts.enumerated() {
            progress(parts.count > 1 ? "Finding stories in \(source) (part \(i + 1) of \(parts.count))…" : "Finding stories in \(source)…")
            let o = try await ask(output: 4000, temperature: 0.1) { _ in
                Prompts.splitStories(text: part, source: source, part: i + 1, of: parts.count, companies: companies)
            }
            out += J.dicts(o, "stories").map { Story(json: $0, origin: "file") }.filter { !$0.text.isEmpty }
        }
        return out
    }
}
