import Foundation
import FoundationModels

/// Structured output for end-of-day planning. The model fills 2-3 short
/// first-person intentions for the next day; we surface these to the NPC
/// the following morning so chats can reference them.
@Generable
struct DailyIntentions {
    @Guide(description: "2 to 3 short first-person intentions for tomorrow, each one sentence")
    let intentions: [String]
}

/// Post-chat sentiment rating, run once per NPC per chat. Affinity drives
/// future social utility; summary is a short relationship-state phrase fed
/// into later dialogue prompts.
@Generable
struct ChatRating {
    @Guide(description: "How the exchange felt to you: -2 (tense or cold), -1 (slightly off), 0 (neutral), 1 (friendly), 2 (warm or close)")
    let affinity: Int

    @Guide(description: "Three to six words describing your standing with this person now, e.g. 'old friends', 'cordial colleagues', 'a touch awkward'")
    let summary: String
}

enum NPCBrain {

    private static let dialogueOptions = GenerationOptions(
        sampling: .random(top: 40),
        temperature: 0.85,
        maximumResponseTokens: 40
    )
    private static let reflectionOptions = GenerationOptions(
        sampling: .greedy,
        temperature: 0.7,
        maximumResponseTokens: 220
    )

    /// One actor per NPC owns that NPC's `LanguageModelSession`. Calls into
    /// `respond` / `respondGenerable` serialize through the actor — Apple's
    /// model only allows one in-flight request per session, and a per-NPC
    /// actor enforces that *without* serializing across different NPCs (so
    /// two NPCs can be rated in parallel).
    private actor NPCSession {
        private static let recreateAfterCalls = 8

        private let npcName: String
        private let role: String
        private var session: LanguageModelSession
        private var callsSinceFresh = 0

        init(npcName: String, role: String) {
            self.npcName = npcName
            self.role = role
            self.session = NPCSession.makeSession(npcName: npcName, role: role)
            self.session.prewarm()
        }

        func respondString(prompt: String, options: GenerationOptions) async throws -> String {
            ensureFresh()
            callsSinceFresh += 1
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        }

        func respondGenerable<T: Generable & Sendable>(prompt: String, type: T.Type, options: GenerationOptions) async throws -> T {
            ensureFresh()
            callsSinceFresh += 1
            let response = try await session.respond(to: prompt, generating: type, options: options)
            return response.content
        }

        func invalidate() {
            session = NPCSession.makeSession(npcName: npcName, role: role)
            session.prewarm()
            callsSinceFresh = 0
        }

        func warmUp() {
            // session is already prewarmed in init; this is a no-op but exists
            // so callers can `await` warm-up completion.
        }

        private func ensureFresh() {
            if callsSinceFresh >= NPCSession.recreateAfterCalls {
                invalidate()
            }
        }

        private static func makeSession(npcName: String, role: String) -> LanguageModelSession {
            let identity = "Your name is \(npcName). You are \(role) in a small medieval town."
            let world = "The town has only three places: a bakery (Elara's), a tavern (Mora's), and farm fields with a farmhouse (Gareth's). There is no market, blacksmith, mill, smithy, harbor, church, or any other place — never refer to them. The only people are Elara, Mora, and Gareth."
            let outputRule = "Your output is the LITERAL WORDS YOU SPEAK OUT LOUD — exactly what someone standing nearby would hear. It is NOT a description, NOT narration, NOT a stage direction."
            let narrationBan = "NEVER write narration like 'I smile', 'I notice', 'I walk', 'I continue', 'X greets me', 'X smiles', 'X is about to', 'I'm grateful'. Those describe actions and feelings — they are wrong. Speak the dialogue line only."
            let format = "Reply with one short in-character sentence — under 20 words. No quotes, no parentheticals, no name prefix like '\(npcName):'."
            let bans = "Never greet ('Good morning', 'Hello', 'Good day'). Never close ('have a lovely day', 'see you', 'good day to you')."
            let grounding = "Ground every line in what you are actually doing right now or something concrete you noticed today."
            let instructions = Instructions("\(identity) \(world) \(outputRule) \(narrationBan) \(format) \(bans) \(grounding)")
            return LanguageModelSession(instructions: instructions)
        }
    }

    /// Holds one NPCSession actor per NPC so callers can grab the right one
    /// in O(1) and have its calls serialize.
    private actor SessionRegistry {
        private var sessions: [String: NPCSession] = [:]

        func session(for npcName: String, role: String) -> NPCSession {
            if let existing = sessions[npcName] { return existing }
            let fresh = NPCSession(npcName: npcName, role: role)
            sessions[npcName] = fresh
            return fresh
        }

        func invalidate(_ npcName: String) async {
            if let s = sessions[npcName] { await s.invalidate() }
        }
    }

    private static let registry = SessionRegistry()

    // MARK: - Availability

    private static let availabilityLock = NSLock()
    nonisolated(unsafe) private static var _checkedAvailability = false
    nonisolated(unsafe) private static var _modelAvailable = false

    static var isAvailable: Bool {
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        if !_checkedAvailability {
            _checkedAvailability = true
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                _modelAvailable = true
                print("[LLM] On-device model available")
            case .unavailable(.deviceNotEligible):
                print("[LLM] Device does not support Apple Intelligence")
            case .unavailable(.appleIntelligenceNotEnabled):
                print("[LLM] Apple Intelligence is not enabled — turn it on in System Settings > Apple Intelligence & Siri")
            case .unavailable(.modelNotReady):
                print("[LLM] Model not ready — still downloading or system busy")
            case .unavailable(let reason):
                print("[LLM] Model unavailable: \(reason)")
            }
        }
        return _modelAvailable
    }

    static func warmUp(npcName: String, role: String) {
        guard isAvailable else { return }
        Task.detached {
            let s = await registry.session(for: npcName, role: role)
            await s.warmUp()
            print("[LLM] Session prewarmed for \(npcName)")
        }
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }

    /// Strip the model's bad habits from a raw line:
    /// - take only the first non-empty line
    /// - strip leading/trailing quotes and whitespace
    /// - strip any leading "<npcName>:" prefix (repeated, since the model can nest them)
    /// - cap at the first sentence terminator so a stray follow-up gets dropped.
    private static func cleanLine(_ raw: String, npcName: String) -> String {
        let firstLine = raw
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        var trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))

        let prefix = "\(npcName):"
        while true {
            let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
            if stripped.lowercased().hasPrefix(prefix.lowercased()) {
                trimmed = String(stripped.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
            } else {
                trimmed = stripped
                break
            }
        }

        let terminators: [Character] = [".", "!", "?"]
        if let firstTerminator = trimmed.firstIndex(where: { terminators.contains($0) }) {
            let endIdx = trimmed.index(after: firstTerminator)
            trimmed = String(trimmed[..<endIdx])
        }
        return trimmed
    }

    // MARK: - Reflection

    static func generateReflection(
        npcName: String,
        role: String,
        schedule: String,
        memories: [String]
    ) async -> String? {
        guard isAvailable else { return nil }

        let memoryText = memories.joined(separator: "\n")
        let prompt = """
            Reflect on your day in first person in 1-2 sentences. \
            Mention specifics from today — names, places, what was actually said or done. \
            Your routine: \(schedule). \
            Today's events:
            \(memoryText)
            """

        print("[LLM] Generating reflection for \(npcName)...")
        let start = Date()
        do {
            let session = await registry.session(for: npcName, role: role)
            let content = try await session.respondString(prompt: prompt, options: reflectionOptions)
            let elapsed = Date().timeIntervalSince(start)
            print("[LLM] \(npcName) reflection: \(formatSeconds(elapsed))")
            print("[LLM] \(npcName) reflects: \(content)")
            return content
        } catch {
            await handle(error: error, npcName: npcName, label: "reflection")
            return nil
        }
    }

    // MARK: - Intentions

    static func generateIntentions(
        npcName: String,
        role: String,
        reflectionText: String,
        schedule: String
    ) async -> [String]? {
        guard isAvailable else { return nil }

        let prompt = """
            You just reflected on today: \(reflectionText)
            Your usual routine: \(schedule)

            What 2-3 things do you want to do differently or look forward to tomorrow?
            Keep each one short, first-person, concrete (a person, place, or task), grounded in your role.
            Examples: "seek out Mora to ask about the harvest", "rise earlier to start the rye", "linger at the tavern after lunch".
            """

        print("[LLM] Generating intentions for \(npcName)...")
        let start = Date()
        do {
            let session = await registry.session(for: npcName, role: role)
            let result = try await session.respondGenerable(prompt: prompt, type: DailyIntentions.self, options: reflectionOptions)
            let elapsed = Date().timeIntervalSince(start)
            print("[LLM] \(npcName) intentions: \(formatSeconds(elapsed))")
            for line in result.intentions {
                print("[LLM] \(npcName) intends: \(line)")
            }
            return result.intentions
        } catch {
            await handle(error: error, npcName: npcName, label: "intentions")
            return nil
        }
    }

    // MARK: - Chat rating

    static func rateExchange(
        npcName: String,
        role: String,
        partner: String,
        transcript: [String]
    ) async -> ChatRating? {
        guard isAvailable else { return nil }

        let prompt = """
            You just had this conversation with \(partner):
            \(transcript.joined(separator: "\n"))

            From your perspective, how did it feel? Provide an integer affinity in [-2, 2] and a short summary phrase of where the relationship stands now.
            """

        do {
            let session = await registry.session(for: npcName, role: role)
            let rating = try await session.respondGenerable(prompt: prompt, type: ChatRating.self, options: reflectionOptions)
            print("[LLM] \(npcName) rates chat with \(partner): \(rating.affinity) (\(rating.summary))")
            return rating
        } catch {
            await handle(error: error, npcName: npcName, label: "rating")
            return nil
        }
    }

    // MARK: - Player chat

    /// Player talks to an NPC. The visitor is anonymous — no relationship,
    /// no intentions toward them, just a stranger speaking. Uses the NPC's
    /// existing per-NPC session so role + recent activity context carry over.
    static func respondToPlayer(
        npcName: String,
        role: String,
        location: String,
        timeOfDay: String,
        npcActivity: String,
        npcActivityDuration: String,
        npcObservations: [String],
        npcIntentions: [String],
        playerMessage: String,
        chatHistory: [String]
    ) async -> String? {
        guard isAvailable else { return nil }

        let observationsBlock = npcObservations.isEmpty
            ? ""
            : "\nEarlier today you noticed:\n" + npcObservations.joined(separator: "\n")

        let intentionsBlock = npcIntentions.isEmpty
            ? ""
            : "\nLast night you decided:\n" + npcIntentions.map { "- \($0)" }.joined(separator: "\n")

        let historyBlock: String
        if chatHistory.isEmpty {
            historyBlock = ""
        } else {
            let joined = chatHistory.joined(separator: "\n")
            historyBlock = "\n\nEarlier in this exchange:\n\(joined)"
        }

        let prompt = """
            It's \(timeOfDay). You're at the \(location), \(npcActivity.lowercased()) \(npcActivityDuration).
            A visitor — a stranger to the village — is here speaking with you. They just said: "\(playerMessage)"\(observationsBlock)\(intentionsBlock)\(historyBlock)

            Reply to the visitor with one short sentence — the actual words you'd say out loud. Stay in character as \(npcName) the \(role). Do NOT narrate. Output only the spoken line.
            """

        return await respond(npcName: npcName, role: role, label: "\(npcName) -> visitor", prompt: prompt)
    }

    // MARK: - Dialogue

    static func generateDialogue(
        speaker: String,
        speakerRole: String,
        listener: String,
        listenerRole: String,
        othersPresent: [String] = [],
        location: String,
        timeOfDay: String,
        speakerActivity: String,
        speakerActivityDuration: String,
        speakerObservations: [String],
        speakerIntentions: [String],
        relationshipNote: String?,
        priorChatsToday: Int,
        chatHistory: [String]
    ) async -> String? {
        guard isAvailable else { return nil }

        let observationsBlock = speakerObservations.isEmpty
            ? ""
            : "\nEarlier today you noticed:\n" + speakerObservations.joined(separator: "\n")

        let intentionsBlock = speakerIntentions.isEmpty
            ? ""
            : "\nLast night you decided:\n" + speakerIntentions.map { "- \($0)" }.joined(separator: "\n")

        let relationshipBlock = relationshipNote.map { "\nYour standing with \(listener): \($0)." } ?? ""

        let historyBlock: String
        if priorChatsToday == 0 {
            historyBlock = "This is the first time you've spoken with \(listener) today."
        } else {
            let joined = chatHistory.joined(separator: "\n")
            historyBlock = """
                You've already spoken with \(listener) \(priorChatsToday == 1 ? "once" : "\(priorChatsToday) times") today. Recent exchange:
                \(joined)

                Do NOT greet them again. Pick up naturally — share something new from your day, react to the last thing they said, or bring up a different topic.
                """
        }

        let othersBlock = othersPresent.isEmpty
            ? ""
            : " \(othersPresent.joined(separator: " and ")) \(othersPresent.count == 1 ? "is" : "are") also here."

        let prompt = """
            It's \(timeOfDay). You're at the \(location), \(speakerActivity.lowercased()) \(speakerActivityDuration).
            \(listener) (\(listenerRole)) is here with you.\(othersBlock)\(observationsBlock)\(intentionsBlock)\(relationshipBlock)

            \(historyBlock)

            Speak one short sentence to \(listener) — the actual words you'd say out loud. Mention something concrete from your day. Do NOT narrate ("I smile", "I notice", "\(listener) greets me"). Do NOT greet. Output only the spoken line.
            """

        return await respond(npcName: speaker, role: speakerRole, label: "\(speaker) dialogue", prompt: prompt)
    }

    static func generateResponse(
        responder: String,
        responderRole: String,
        to speaker: String,
        speakerRole: String,
        othersPresent: [String] = [],
        location: String,
        timeOfDay: String,
        responderActivity: String,
        responderActivityDuration: String,
        responderObservations: [String],
        responderIntentions: [String],
        relationshipNote: String?,
        previousLine: String,
        chatHistory: [String],
        isFinal: Bool = false
    ) async -> String? {
        guard isAvailable else { return nil }

        let observationsBlock = responderObservations.isEmpty
            ? ""
            : "\nEarlier today you noticed:\n" + responderObservations.joined(separator: "\n")

        let intentionsBlock = responderIntentions.isEmpty
            ? ""
            : "\nLast night you decided:\n" + responderIntentions.map { "- \($0)" }.joined(separator: "\n")

        let relationshipBlock = relationshipNote.map { "\nYour standing with \(speaker): \($0)." } ?? ""

        let historyBlock: String
        if chatHistory.isEmpty {
            historyBlock = ""
        } else {
            let joined = chatHistory.joined(separator: "\n")
            historyBlock = """

                Earlier in this exchange:
                \(joined)
                """
        }

        let closingNote = isFinal
            ? " This is your closing line — wrap up naturally and part ways. Don't ask a new question."
            : ""

        let othersBlock = othersPresent.isEmpty
            ? ""
            : " \(othersPresent.joined(separator: " and ")) \(othersPresent.count == 1 ? "is" : "are") also here."

        let prompt = """
            It's \(timeOfDay). You're at the \(location), \(responderActivity.lowercased()) \(responderActivityDuration).
            \(speaker) (\(speakerRole)) just said: "\(previousLine)"\(othersBlock)\(observationsBlock)\(intentionsBlock)\(relationshipBlock)\(historyBlock)

            Reply to \(speaker) with one short sentence — the actual words you'd say out loud. React to what they said. Do NOT narrate ("I smile", "I notice", "\(speaker) greets me"). Do NOT write \(speaker)'s next line.\(closingNote) Output only the spoken line.
            """

        return await respond(npcName: responder, role: responderRole, label: "\(responder) response", prompt: prompt)
    }

    private static func respond(npcName: String, role: String, label: String, prompt: String) async -> String? {
        print("[LLM] Generating \(label)...")
        let start = Date()
        do {
            let session = await registry.session(for: npcName, role: role)
            let content = try await session.respondString(prompt: prompt, options: dialogueOptions)
            let total = Date().timeIntervalSince(start)
            let cleaned = cleanLine(content, npcName: npcName)
            print("[LLM] \(label): total \(formatSeconds(total))")
            print("[LLM] [DLG] \(npcName): \"\(cleaned)\"")
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            await handle(error: error, npcName: npcName, label: label)
            return nil
        }
    }

    private static func handle(error: Error, npcName: String, label: String) async {
        if let genError = error as? LanguageModelSession.GenerationError {
            switch genError {
            case .rateLimited:
                print("[LLM] \(label) rate limited for \(npcName): \(genError)")
            case .exceededContextWindowSize:
                print("[LLM] \(label) exceeded context window for \(npcName); recreating session")
                await registry.invalidate(npcName)
                return
            case .guardrailViolation:
                print("[LLM] \(label) guardrail violation for \(npcName): \(genError)")
            default:
                print("[LLM] \(label) generation error for \(npcName): \(genError)")
            }
        } else {
            print("[LLM] \(label) error for \(npcName): \(error)")
        }
        await registry.invalidate(npcName)
    }
}
