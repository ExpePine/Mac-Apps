import Foundation

/// The AI workflows: parse JD → benchmark resume → missing stories → your resume → interview.
extension AppStore {

    // MARK: Clean up a captured page into a proper JD

    func parseJob(_ id: UUID) async throws {
        guard let i = jobIndex(id) else { return }
        let j = data.jobs[i]
        let input = j.rawText.count > j.description.count ? j.rawText : j.description
        guard !input.isEmpty else { return }

        let o = try await client.json(system: Prompts.system,
                                      user: Prompts.parseJob(pageText: String(input.prefix(30000)), hint: j),
                                      temperature: 0.1)
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
        let o = try await client.json(system: Prompts.system,
                                      user: Prompts.benchmark(job: data.jobs[i]),
                                      temperature: 0.6)
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
        let o = try await client.json(system: Prompts.system,
                                      user: Prompts.gaps(job: data.jobs[i], benchmark: bench,
                                                         profile: data.profile, stories: data.stories),
                                      temperature: 0.4)
        let gaps = J.dicts(o, "gaps").map {
            StoryGap(theme: J.str($0, "theme"),
                     priority: J.str($0, "priority").lowercased().isEmpty ? "medium" : J.str($0, "priority").lowercased(),
                     whyItMatters: J.str($0, "whyItMatters"),
                     benchmarkExample: J.str($0, "benchmarkExample"),
                     questions: J.strings($0, "questions"),
                     coveredBy: J.strings($0, "coveredBy"))
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
        let o = try await client.json(system: Prompts.system,
                                      user: Prompts.tailored(job: job, benchmark: job.benchmark, profile: data.profile,
                                                             stories: data.stories, allowPlaceholders: allowPlaceholders),
                                      temperature: 0.35)
        guard let k = jobIndex(id) else { return }
        data.jobs[k].tailored = finalize(ResumeDoc(json: J.dict(o, "resume") ?? o,
                                                   mode: allowPlaceholders ? "placeholders" : "strict"))
        data.jobs[k].tailoredMissing = J.strings(o, "missing")
    }

    func buildMaster(allowPlaceholders: Bool) async throws {
        try requireMaterial()
        let o = try await client.json(system: Prompts.system,
                                      user: Prompts.tailored(job: nil, benchmark: nil, profile: data.profile,
                                                             stories: data.stories, allowPlaceholders: allowPlaceholders),
                                      temperature: 0.35)
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
        let valid = Set(data.stories.map(\.id.uuidString))
        for r in d.experience.indices {
            for b in d.experience[r].bullets.indices {
                d.experience[r].bullets[b].sources = d.experience[r].bullets[b].sources.filter { valid.contains($0) }
            }
        }
        for a in d.achievements.indices {
            d.achievements[a].sources = d.achievements[a].sources.filter { valid.contains($0) }
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

        var messages = [GroqClient.Message(role: "system",
                                           content: Prompts.interviewer(profile: data.profile, stories: data.stories,
                                                                        job: job, gap: gap, draft: session.draft))]
        if session.turns.isEmpty {
            messages.append(.init(role: "user", content: "(Start the interview with your first question.)"))
        } else {
            messages += session.turns.suffix(30).map { .init(role: $0.role, content: $0.text) }
        }

        let o = try await client.json(messages: messages, temperature: 0.5)
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
        let o = try await client.json(system: Prompts.system, user: Prompts.importResume(text: text), temperature: 0.1)
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
        let parts = StoryImport.chunks(clean)
        var out: [Story] = []
        for (i, part) in parts.enumerated() {
            progress(parts.count > 1 ? "Finding stories in \(source) (part \(i + 1) of \(parts.count))…" : "Finding stories in \(source)…")
            let o = try await client.json(system: Prompts.system,
                                          user: Prompts.splitStories(text: part, source: source, part: i + 1,
                                                                     of: parts.count, companies: companies),
                                          temperature: 0.1)
            out += J.dicts(o, "stories").map { Story(json: $0, origin: "file") }.filter { !$0.text.isEmpty }
        }
        return out
    }
}
