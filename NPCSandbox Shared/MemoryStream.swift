import Foundation

struct MemoryEntry {
    let gameTime: String
    let text: String
    let kind: Kind

    enum Kind: String {
        case observation
        case action
    }
}

class MemoryStream {
    let ownerName: String
    private(set) var entries: [MemoryEntry] = []
    private var observationCooldowns: [String: Int] = [:]

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

    var recentEntries: [MemoryEntry] {
        Array(entries.suffix(10))
    }
}
