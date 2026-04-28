import Foundation
import FoundationModels

/// Structured output for end-of-day planning. The model fills 2-3 short
/// first-person intentions for the next day; we surface these to the NPC
/// the following morning so chats can reference them.
@Generable
struct DailyIntentions {
    @Guide(description: "2 to 3 short first-person intentions for tomorrow, each one sentence")
    let intentions: [String]

    @Guide(description: "If you intend to rise earlier or sleep in tomorrow, the shift in minutes (negative for earlier, positive for later, 0 for no change). Range -45 to 45.")
    let wakeShiftMinutes: Int
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

/// NPC reply to the player. Combines the spoken line with a flag indicating
/// whether the NPC just revealed their fragment in this turn — set true
/// only when the player's last message clearly satisfied an unlock condition.
@Generable
struct NPCReply: Sendable {
    @Guide(description: "What the NPC says — one short sentence, the literal words spoken, in their character's voice. Under 20 words. No narration.")
    let line: String

    @Guide(description: "True ONLY if the visitor's last message clearly satisfied one of your unlock conditions and you just revealed your secret in the line above. Otherwise false. Default to false when in doubt.")
    let fragmentRevealed: Bool
}

enum NPCBrain {

    private static let dialogueOptions = GenerationOptions(
        sampling: .random(top: 40),
        temperature: 0.85,
        maximumResponseTokens: 60
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
        private let personality: String
        private var session: LanguageModelSession
        private var callsSinceFresh = 0

        init(npcName: String, role: String, personality: String) {
            self.npcName = npcName
            self.role = role
            self.personality = personality
            self.session = NPCSession.makeSession(npcName: npcName, role: role, personality: personality)
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
            session = NPCSession.makeSession(npcName: npcName, role: role, personality: personality)
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

        private static func makeSession(npcName: String, role: String, personality: String) -> LanguageModelSession {
            let identity = "Your name is \(npcName). You are \(role) in a small medieval town."
            let voice = "Personality: \(personality). Speak in YOUR voice — opinionated, specific, sometimes cranky, dry, gossipy, proud, complaining, or teasing — whatever fits your personality. Do NOT default to polite small talk."
            let world = "The town has these places only: a bakery (Elara's), a tavern (Mora's), farm fields with a farmhouse (Gareth's), an old keep at the east edge (sealed shut, no one goes inside), an old crone's cottage in the south wood (Hilda's), and a stranger's camp on the south edge. There is no market, blacksmith, mill, smithy, harbor, or church. The only people are Elara (the baker), Mora (the tavern keeper), Gareth (the farmer), Father Aldric (the drunk priest who once tended the chapel that crumbled), Old Hilda (the reclusive crone), the Stranger (a quiet traveler who arrived a few days ago), and a Visitor — the player. Never invent other places or people."
            let outputRule = "Your output is the LITERAL WORDS YOU SPEAK OUT LOUD — what someone standing nearby would hear. NOT description, NOT narration, NOT a stage direction."
            let narrationBan = "NEVER write 'I smile', 'I notice', 'I walk', 'X greets me', 'X smiles', 'X continues'. Those are narration — wrong. Speak the dialogue itself."
            let format = "One short in-character sentence — under 20 words. No quotes, no parentheticals, no name prefix like '\(npcName):'."
            let opener = "Don't open with generic greetings ('Good morning', 'Hello'). Start mid-thought — react to what's happening, comment on something specific you saw, share an opinion, or grumble about something concrete."
            let instructions = Instructions("\(identity) \(voice) \(world) \(outputRule) \(narrationBan) \(format) \(opener)")
            return LanguageModelSession(instructions: instructions)
        }
    }

    /// Holds one NPCSession actor per NPC so callers can grab the right one
    /// in O(1) and have its calls serialize.
    private actor SessionRegistry {
        private var sessions: [String: NPCSession] = [:]

        func session(for npcName: String, role: String, personality: String) -> NPCSession {
            if let existing = sessions[npcName] { return existing }
            let fresh = NPCSession(npcName: npcName, role: role, personality: personality)
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

    static func warmUp(npcName: String, role: String, personality: String) {
        guard isAvailable else { return }
        Task.detached {
            let s = await registry.session(for: npcName, role: role, personality: personality)
            await s.warmUp()
            print("[LLM] Session prewarmed for \(npcName)")
        }
    }

    /// Drop this NPC's session so its next call starts with a fresh
    /// transcript. Used on loop reset — NPCs don't remember the prior loop.
    static func invalidate(npcName: String) async {
        await registry.invalidate(npcName)
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
        personality: String,
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
            let session = await registry.session(for: npcName, role: role, personality: personality)
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
        personality: String,
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
            let session = await registry.session(for: npcName, role: role, personality: personality)
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
        personality: String,
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
            let session = await registry.session(for: npcName, role: role, personality: personality)
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
        personality: String,
        mood: String,
        location: String,
        timeOfDay: String,
        npcActivity: String,
        npcActivityDuration: String,
        npcObservations: [String],
        npcIntentions: [String],
        fragment: Fragment?,
        unlockConditions: [String],
        dodgesTopics: [String],
        fragmentAlreadyRevealed: Bool,
        playerMessage: String,
        chatHistory: [String]
    ) async -> NPCReply? {
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

        let dodgesBlock = dodgesTopics.isEmpty
            ? ""
            : "\nYou tend to dodge these topics — deflect or change subject if the visitor pushes on them: \(dodgesTopics.joined(separator: "; "))."

        let secretBlock: String
        if let fragment, !fragmentAlreadyRevealed {
            let conditions = unlockConditions.map { "- \($0)" }.joined(separator: "\n")
            secretBlock = """

                You hold a secret: \(fragment.promptDescription)
                You will reveal it ONLY if the visitor's last message clearly satisfies one of these conditions:
                \(conditions)
                If satisfied, weave the secret naturally into your reply (don't recite like a script) and set fragmentRevealed = true.
                Otherwise, respond in character without revealing it. Set fragmentRevealed = false.
                """
        } else {
            secretBlock = "\n\nYou have nothing to reveal in this exchange. fragmentRevealed must be false."
        }

        let prompt = """
            It's \(timeOfDay). You're at the \(location), \(npcActivity.lowercased()) \(npcActivityDuration). You feel \(mood).
            A visitor — a stranger to the village — is here speaking with you. They just said: "\(playerMessage)"\(observationsBlock)\(intentionsBlock)\(historyBlock)\(dodgesBlock)\(secretBlock)

            Reply with one short sentence — the actual words you'd say out loud, in your character's voice. React to what they actually said. Don't narrate. Output only the spoken line and the fragmentRevealed flag.
            """

        do {
            let session = await registry.session(for: npcName, role: role, personality: personality)
            return try await session.respondGenerable(
                prompt: prompt,
                type: NPCReply.self,
                options: dialogueOptions
            )
        } catch {
            await handle(error: error, npcName: npcName, label: "\(npcName) -> visitor")
            return nil
        }
    }

    // MARK: - Dialogue

    static func generateDialogue(
        speaker: String,
        speakerRole: String,
        speakerPersonality: String,
        speakerMood: String,
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
            : " \(othersPresent.joined(separator: " and ")) \(othersPresent.count == 1 ? "is" : "are") standing right here with you, within earshot — address them directly when it makes sense, don't refer to them in the third person."

        let prompt = """
            It's \(timeOfDay). You're at the \(location), \(speakerActivity.lowercased()) \(speakerActivityDuration). You feel \(speakerMood).
            \(listener) (\(listenerRole)) is here with you.\(othersBlock)\(observationsBlock)\(intentionsBlock)\(relationshipBlock)

            \(historyBlock)

            Speak one short sentence to \(listener) — the actual words you'd say out loud, in your character's voice. Open mid-thought: react to what you saw, complain or tease, share a specific opinion, mention a concrete detail of your day. Do NOT repeat anything either of you has said today. Don't be polite for politeness' sake. Don't greet. Don't narrate ("I smile", "I notice"). Output only the spoken line.
            """

        return await respond(npcName: speaker, role: speakerRole, personality: speakerPersonality, label: "\(speaker) dialogue", prompt: prompt)
    }

    static func generateResponse(
        responder: String,
        responderRole: String,
        responderPersonality: String,
        responderMood: String,
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
            : " \(othersPresent.joined(separator: " and ")) \(othersPresent.count == 1 ? "is" : "are") standing right here too, within earshot — address them directly when it makes sense, don't refer to them in the third person."

        let prompt = """
            It's \(timeOfDay). You're at the \(location), \(responderActivity.lowercased()) \(responderActivityDuration). You feel \(responderMood).
            \(speaker) (\(speakerRole)) just said: "\(previousLine)"\(othersBlock)\(observationsBlock)\(intentionsBlock)\(relationshipBlock)\(historyBlock)

            Reply to \(speaker) with one short sentence — the actual words you'd say out loud, in your character's voice. React to what they said with an opinion, a complaint, a tease, or a specific fact from your day. Do NOT repeat any line that's already been said in this exchange. Don't narrate, don't be generically polite, don't write \(speaker)'s next line.\(closingNote) Output only the spoken line.
            """

        return await respond(npcName: responder, role: responderRole, personality: responderPersonality, label: "\(responder) response", prompt: prompt)
    }

    private static func respond(npcName: String, role: String, personality: String, label: String, prompt: String) async -> String? {
        print("[LLM] Generating \(label)...")
        let start = Date()
        do {
            let session = await registry.session(for: npcName, role: role, personality: personality)
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
