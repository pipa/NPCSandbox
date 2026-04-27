import Foundation
import FoundationModels

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

    /// Per-NPC session registry. Each NPC gets a `LanguageModelSession` whose
    /// `Instructions` carry the role — so the role tokenizes once and is reused
    /// for every prompt. Sessions are recycled after a bounded number of calls
    /// or on error to keep transcript growth in check.
    private actor SessionRegistry {
        private struct Slot {
            var session: LanguageModelSession
            var callsSinceFresh: Int
        }

        private let recreateAfterCalls = 8
        private var slots: [String: Slot] = [:]

        func session(for npcName: String, role: String) -> LanguageModelSession {
            if let existing = slots[npcName], existing.callsSinceFresh < recreateAfterCalls {
                return existing.session
            }
            let fresh = makeSession(npcName: npcName, role: role)
            fresh.prewarm()
            slots[npcName] = Slot(session: fresh, callsSinceFresh: 0)
            return fresh
        }

        func bumpCallCount(for npcName: String) {
            guard var slot = slots[npcName] else { return }
            slot.callsSinceFresh += 1
            slots[npcName] = slot
        }

        func invalidate(_ npcName: String) {
            slots.removeValue(forKey: npcName)
        }

        func warmUp(npcName: String, role: String) {
            _ = session(for: npcName, role: role)
        }

        private func makeSession(npcName: String, role: String) -> LanguageModelSession {
            let instructions = Instructions(
                "Your name is \(npcName). You are \(role) in a small medieval town. " +
                "You speak ONLY as \(npcName). You never speak for or address yourself; " +
                "you never write the other person's reply; you never produce more than one sentence at a time. " +
                "Reply with a single short sentence — under 20 words, no quotes, no stage directions, " +
                "no closing salutations. Stay grounded in what you are actually doing right now."
            )
            return LanguageModelSession(instructions: instructions)
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
            await registry.warmUp(npcName: npcName, role: role)
            print("[LLM] Session prewarmed for \(npcName)")
        }
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }

    /// The model sometimes ignores "one sentence" and produces a full back-and-forth
    /// in a single response. Take only the first non-empty line, then chop at the
    /// first sentence boundary so we never emit the imagined reply.
    private static func cleanLine(_ raw: String) -> String {
        let firstLine = raw
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        var trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))

        // Chop at the first sentence terminator so a stray "Good day, Gareth."
        // tacked on after the real line gets dropped.
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
            await registry.bumpCallCount(for: npcName)
            let response = try await session.respond(to: prompt, options: reflectionOptions)
            let elapsed = Date().timeIntervalSince(start)
            print("[LLM] \(npcName) reflection: \(formatSeconds(elapsed))")
            print("[LLM] \(npcName) reflects: \(response.content)")
            return response.content
        } catch {
            await handle(error: error, npcName: npcName, label: "reflection")
            return nil
        }
    }

    // MARK: - Dialogue

    static func generateDialogue(
        speaker: String,
        speakerRole: String,
        listener: String,
        listenerRole: String,
        location: String,
        timeOfDay: String,
        speakerActivity: String,
        speakerActivityDuration: String,
        speakerObservations: [String],
        priorChatsToday: Int,
        chatHistory: [String]
    ) async -> String? {
        guard isAvailable else { return nil }

        let observationsBlock = speakerObservations.isEmpty
            ? ""
            : "\nEarlier today you noticed:\n" + speakerObservations.joined(separator: "\n")

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

        let prompt = """
            It's \(timeOfDay). You're near the \(location); you've been \(speakerActivity.lowercased()) \(speakerActivityDuration).
            \(listener) (\(listenerRole)) just walked up.\(observationsBlock)

            \(historyBlock)

            Say ONE sentence (under 20 words) grounded in what you're doing right now or something you noticed today. Do not greet generically. Do not write \(listener)'s reply. Do not address yourself. Output only your single sentence.
            """

        return await respond(npcName: speaker, role: speakerRole, label: "\(speaker) dialogue", prompt: prompt)
    }

    static func generateResponse(
        responder: String,
        responderRole: String,
        to speaker: String,
        speakerRole: String,
        location: String,
        timeOfDay: String,
        responderActivity: String,
        responderActivityDuration: String,
        responderObservations: [String],
        previousLine: String,
        chatHistory: [String],
        isFinal: Bool = false
    ) async -> String? {
        guard isAvailable else { return nil }

        let observationsBlock = responderObservations.isEmpty
            ? ""
            : "\nEarlier today you noticed:\n" + responderObservations.joined(separator: "\n")

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

        let prompt = """
            It's \(timeOfDay). You're near the \(location); you've been \(responderActivity.lowercased()) \(responderActivityDuration).
            \(speaker) (\(speakerRole)) just said: "\(previousLine)"\(observationsBlock)\(historyBlock)

            Say ONE sentence (under 20 words) reacting to what \(speaker) said. Stay grounded in what you're doing. Do not write \(speaker)'s next line. Do not address yourself.\(closingNote) Output only your single sentence.
            """

        return await respond(npcName: responder, role: responderRole, label: "\(responder) response", prompt: prompt)
    }

    private static func respond(npcName: String, role: String, label: String, prompt: String) async -> String? {
        print("[LLM] Generating \(label)...")
        let start = Date()
        do {
            let session = await registry.session(for: npcName, role: role)
            await registry.bumpCallCount(for: npcName)
            let response = try await session.respond(to: prompt, options: dialogueOptions)
            let total = Date().timeIntervalSince(start)
            let cleaned = cleanLine(response.content)
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
