import Foundation

/// What the player has learned across loops. Persists when the world resets
/// — knowledge-only persistence is the looper's core mechanic.
struct JournalEntry: Sendable {
    let npcName: String
    let fragment: Fragment
    let unlockedAtDay: Int

    var summary: String {
        "Day \(unlockedAtDay) — \(npcName): \(fragment.journalSummary)"
    }
}

@MainActor
final class Journal {
    private(set) var entries: [JournalEntry] = []

    /// Record an unlocked fragment. No-op if this NPC's fragment is already
    /// in the journal — fragments are unlocked once across the run.
    func record(_ entry: JournalEntry) {
        guard !entries.contains(where: { $0.npcName == entry.npcName }) else { return }
        entries.append(entry)
        print("[Journal] \(entry.summary)")
    }

    var unlockedNames: Set<String> {
        Set(entries.map(\.npcName))
    }

    var allFour: Bool {
        // The four fragment types — once one of each is logged, the player
        // has the pieces to attempt the ritual.
        var hasSong = false, hasPlace = false, hasWords = false, hasOffering = false
        for e in entries {
            switch e.fragment {
            case .song: hasSong = true
            case .place: hasPlace = true
            case .words: hasWords = true
            case .offering: hasOffering = true
            }
        }
        return hasSong && hasPlace && hasWords && hasOffering
    }
}
