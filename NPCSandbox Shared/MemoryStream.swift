import Foundation

struct MemoryEntry {
    let gameTime: String
    let text: String
    let kind: Kind
    let partner: String?

    init(gameTime: String, text: String, kind: Kind, partner: String? = nil) {
        self.gameTime = gameTime
        self.text = text
        self.kind = kind
        self.partner = partner
    }

    enum Kind: String {
        case observation
        case action
        case dialogue
    }
}

struct DailySummary {
    let day: Int
    let bullets: [String]
}

class MemoryStream {
    let ownerName: String
    private(set) var entries: [MemoryEntry] = []
    private(set) var dailySummaries: [DailySummary] = []
    private var observationCooldowns: [String: Int] = [:]
    private var dayCounter: Int = 1

    var cooldownMinutes: Int = 60

    init(ownerName: String) {
        self.ownerName = ownerName
    }

    @discardableResult
    func observe(_ text: String, at gameTime: String, about targetName: String, currentMinutes: Int) -> Bool {
        if let lastSeen = observationCooldowns[targetName], currentMinutes - lastSeen < cooldownMinutes {
            return false
        }
        observationCooldowns[targetName] = currentMinutes
        let entry = MemoryEntry(gameTime: gameTime, text: text, kind: .observation)
        entries.append(entry)
        print("[\(gameTime)] \(ownerName) [OBS] \(text)")
        return true
    }

    func logAction(_ text: String, at gameTime: String) {
        let entry = MemoryEntry(gameTime: gameTime, text: text, kind: .action)
        entries.append(entry)
        print("[\(gameTime)] \(ownerName) [ACT] \(text)")
    }

    func logDialogue(speaker: String, partner: String, line: String, at gameTime: String) {
        let text = "\(speaker): \"\(line)\""
        let entry = MemoryEntry(gameTime: gameTime, text: text, kind: .dialogue, partner: partner)
        entries.append(entry)
    }

    /// Returns recent dialogue lines exchanged with `partner` today, oldest first.
    func recentChatHistory(with partner: String, limit: Int = 3) -> [String] {
        let lines = entries
            .filter { $0.kind == .dialogue && $0.partner == partner }
            .map { "[\($0.gameTime)] \($0.text)" }
        return Array(lines.suffix(limit))
    }

    /// Last few observations (what this NPC has noticed others doing today),
    /// formatted oldest-first for use in dialogue prompts.
    func recentObservations(limit: Int = 3) -> [String] {
        let obs = entries
            .filter { $0.kind == .observation }
            .map { "[\($0.gameTime)] \($0.text)" }
        return Array(obs.suffix(limit))
    }

    /// How many distinct chat sessions today involved `partner` (counts speaker turns).
    func chatSessionCount(with partner: String) -> Int {
        entries.filter {
            $0.kind == .dialogue && $0.partner == partner && $0.text.hasPrefix("\(ownerName): ")
        }.count
    }

    @discardableResult
    func reflect() -> DailySummary {
        var bullets: [String] = []

        // Collect unique actions with timestamps
        var seenActions: Set<String> = []
        for entry in entries where entry.kind == .action {
            if seenActions.insert(entry.text).inserted {
                bullets.append("[\(entry.gameTime)] \(entry.text)")
            }
        }

        // Collect unique NPCs observed
        var seenNPCs: [String: String] = [:]
        for entry in entries where entry.kind == .observation {
            let words = entry.text.split(separator: " ")
            if words.count >= 2 && words[0] == "Saw" {
                let npcName = String(words[1])
                if seenNPCs[npcName] == nil {
                    seenNPCs[npcName] = entry.gameTime
                }
            }
        }
        for (npcName, time) in seenNPCs.sorted(by: { $0.value < $1.value }) {
            bullets.append("[\(time)] Saw \(npcName)")
        }

        // Keep the most memorable dialogue exchanges (last 3 lines per partner)
        // so the reflection LLM has actual conversation content to riff on.
        var byPartner: [String: [MemoryEntry]] = [:]
        for entry in entries where entry.kind == .dialogue {
            guard let partner = entry.partner else { continue }
            byPartner[partner, default: []].append(entry)
        }
        for partner in byPartner.keys.sorted() {
            let recent = byPartner[partner]!.suffix(3)
            for entry in recent {
                bullets.append("[\(entry.gameTime)] \(entry.text)")
            }
        }

        let summary = DailySummary(day: dayCounter, bullets: bullets)
        dailySummaries.append(summary)

        print("=== \(ownerName) Day \(summary.day) Reflection ===")
        for bullet in summary.bullets {
            print("  - \(bullet)")
        }
        if bullets.isEmpty {
            print("  (nothing notable)")
        }

        dayCounter += 1
        entries.removeAll()
        observationCooldowns.removeAll()

        return summary
    }

    var recentEntries: [MemoryEntry] {
        Array(entries.suffix(10))
    }
}
