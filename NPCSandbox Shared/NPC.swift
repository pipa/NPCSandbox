import SpriteKit
import GameplayKit

struct GridPosition: Equatable {
    let col: Int
    let row: Int
}

enum MapLocation {
    static let bakeryDoor = GridPosition(col: 7, row: 4)
    static let tavernDoor = GridPosition(col: 11, row: 4)
    static let farmhouseDoor = GridPosition(col: 7, row: 11)
    static let farmField = GridPosition(col: 14, row: 10)
    static let townSquare = GridPosition(col: 9, row: 7)

    private static let named: [(String, GridPosition)] = [
        ("Bakery", bakeryDoor),
        ("Tavern", tavernDoor),
        ("Farmhouse", farmhouseDoor),
        ("Farm Field", farmField),
        ("Town Square", townSquare),
    ]

    static func nearestName(to pos: GridPosition) -> String {
        var closest = "town"
        var bestDist = Int.max
        for (name, loc) in named {
            let dist = abs(pos.col - loc.col) + abs(pos.row - loc.row)
            if dist < bestDist {
                bestDist = dist
                closest = name
            }
        }
        return closest
    }
}

struct ScheduleEntry {
    let hour: Int
    let minute: Int
    let location: GridPosition
    let activity: String

    var totalMinutes: Int { hour * 60 + minute }
}

class NPC {
    let name: String
    let role: String
    let sprite: SKSpriteNode
    let label: SKLabelNode
    let memory: MemoryStream
    let sociability: Double
    let dialogueColor: SKColor
    var gridPos: GridPosition
    let schedule: [ScheduleEntry]

    var scheduleDescription: String {
        schedule.map { "\($0.activity) at \(String(format: "%02d:%02d", $0.hour, $0.minute))" }
            .joined(separator: ", ")
    }

    var dialogSummary: String {
        let recent = memory.recentEntries
        if recent.isEmpty {
            if let lastDay = memory.dailySummaries.last {
                let lines = lastDay.bullets.prefix(5).joined(separator: "\n")
                return "Yesterday:\n\(lines)"
            }
            return "Nothing notable yet."
        }
        return recent.suffix(6).map { "[\($0.gameTime)] \($0.text)" }.joined(separator: "\n")
    }

    private let tileSize: CGFloat
    private let mapRows: Int
    private var lastTriggeredMinute: Int = -1
    private(set) var currentActivity: String = ""
    private(set) var isWalking = false
    private(set) var isInterrupted = false
    private var chatCooldowns: [String: Int] = [:]
    private let chatCooldownMinutes = 120

    /// First-person intentions produced by last night's reflection. Surfaced into
    /// dialogue prompts so chats can reference what the NPC decided to do today.
    var intentions: [String] = []

    /// Per-partner relationship state — cumulative warmth and a short tag —
    /// updated after each chat by an @Generable rating call.
    struct RelationshipState: Sendable {
        var totalChats: Int = 0
        var sentiment: Int = 0      // running, clamped to [-10, 10]
        var summary: String = ""    // last short phrase the model produced
    }
    private(set) var relationships: [String: RelationshipState] = [:]

    func recordChatRating(partner: String, affinity: Int, summary: String) {
        var state = relationships[partner] ?? RelationshipState()
        state.totalChats += 1
        state.sentiment = max(-10, min(10, state.sentiment + affinity))
        if !summary.isEmpty { state.summary = summary }
        relationships[partner] = state
    }

    /// Short hint for dialogue prompts so the model knows the existing
    /// relationship — nil if they've never spoken.
    func relationshipNote(with otherName: String) -> String? {
        guard let state = relationships[otherName], state.totalChats > 0 else { return nil }
        let warmth: String
        switch state.sentiment {
        case ..<(-2): warmth = "tense"
        case -2 ... -1: warmth = "a bit cool"
        case 0: warmth = "cordial"
        case 1 ... 2: warmth = "warm"
        default: warmth = "very close"
        }
        return state.summary.isEmpty ? warmth : "\(warmth) — \(state.summary)"
    }

    /// Per-day random offset (0-9 game-min) added to each schedule entry's
    /// trigger time so days don't tick on identical clockwork. Regenerated on
    /// `resetForNewDay`.
    private var scheduleJitter: [Int: Int] = [:]

    init(name: String, role: String, tileID: Int, startPos: GridPosition, schedule: [ScheduleEntry],
         sociability: Double, dialogueColor: SKColor, tileSize: CGFloat, mapRows: Int) {
        self.name = name
        self.role = role
        self.gridPos = startPos
        self.schedule = schedule.sorted { $0.totalMinutes < $1.totalMinutes }
        self.sociability = sociability
        self.dialogueColor = dialogueColor
        self.tileSize = tileSize
        self.mapRows = mapRows
        self.memory = MemoryStream(ownerName: name)

        let atlas = SKTextureAtlas(named: "TinyDungeon")
        let texName = String(format: "tile_%04d", tileID)
        let tex = atlas.textureNamed(texName)
        tex.filteringMode = .nearest

        let startPoint = CGPoint(
            x: CGFloat(startPos.col) * tileSize + tileSize / 2,
            y: CGFloat(mapRows - 1 - startPos.row) * tileSize + tileSize / 2
        )

        sprite = SKSpriteNode(texture: tex)
        sprite.position = startPoint
        sprite.zPosition = 10

        label = SKLabelNode(text: name)
        label.fontSize = 5
        label.fontColor = dialogueColor
        label.fontName = "Menlo-Bold"
        label.verticalAlignmentMode = .bottom
        label.position = CGPoint(x: 0, y: tileSize * 0.65)
        label.zPosition = 60  // above sky tint
        sprite.addChild(label)
    }

    // MARK: - Day Reset

    func resetForNewDay() {
        lastTriggeredMinute = -1
        chatCooldowns.removeAll()
        isInterrupted = false
        currentActivity = ""
        scheduleJitter = Dictionary(uniqueKeysWithValues: schedule.map { ($0.totalMinutes, Int.random(in: 0...9)) })
        updateLabel()
    }

    private func triggerMinute(for entry: ScheduleEntry) -> Int {
        entry.totalMinutes + (scheduleJitter[entry.totalMinutes] ?? 0)
    }

    // MARK: - Utility Scoring

    func socialUtility(with other: NPC, currentMinutes: Int) -> Double {
        guard !isInterrupted, !isWalking else { return 0 }

        var utility = sociability * 0.7

        if let lastChat = chatCooldowns[other.name] {
            let elapsed = currentMinutes - lastChat
            if elapsed < chatCooldownMinutes {
                utility *= Double(elapsed) / Double(chatCooldownMinutes)
            }
        }

        // Agenda boost: if last night's intentions name this person, we're
        // actively trying to find them, which lifts the utility past the
        // schedule-utility threshold even when cooldown decay would block it.
        if intentionsName(other) {
            utility *= 1.6
        }

        // Relationship sentiment: warm pairs hover above the threshold longer;
        // cool pairs drift apart. ±10 sentiment maps to ±50% utility, clamped.
        if let state = relationships[other.name] {
            let factor = 1.0 + Double(state.sentiment) * 0.05
            utility *= max(0.5, min(1.5, factor))
        }

        return utility
    }

    /// True if any of today's intentions explicitly mention the other NPC by name.
    func intentionsName(_ other: NPC) -> Bool {
        intentions.contains { $0.localizedCaseInsensitiveContains(other.name) }
    }

    var scheduleUtility: Double {
        isWalking ? 0.8 : 0.3
    }

    // MARK: - Interrupts

    func beginChat(with other: NPC, clock: GameClock) {
        isInterrupted = true
        chatCooldowns[other.name] = clock.totalMinutes

        let location = MapLocation.nearestName(to: gridPos)
        memory.logAction("Chatting with \(other.name) near \(location)", at: clock.timeString)

        currentActivity = "Chatting"
        updateLabel()
    }

    func endChat(clock: GameClock) {
        guard isInterrupted else { return }
        isInterrupted = false
        restoreScheduleActivity(clock: clock)
    }

    /// Human-friendly description of how long the NPC has been on their current
    /// schedule entry. Used to ground dialogue prompts.
    func activityDurationDescription(currentMinutes: Int) -> String {
        let started = max(lastTriggeredMinute, 0)
        let mins = currentMinutes - started
        if mins < 5 { return "just now" }
        if mins < 30 { return "for about \(mins) minutes" }
        if mins < 90 { return "for the past hour or so" }
        if mins < 240 { return "for several hours" }
        return "since this morning"
    }

    // MARK: - Schedule

    func checkSchedule(clock: GameClock, navGraph: GKGridGraph<GKGridGraphNode>) {
        guard !isInterrupted, !isWalking else { return }

        let now = clock.totalMinutes

        var activeEntry: ScheduleEntry?
        for entry in schedule.reversed() {
            if now >= triggerMinute(for: entry) {
                activeEntry = entry
                break
            }
        }

        guard let entry = activeEntry else { return }
        guard entry.totalMinutes != lastTriggeredMinute else { return }

        lastTriggeredMinute = entry.totalMinutes
        currentActivity = entry.activity
        updateLabel()

        let locationName = MapLocation.nearestName(to: entry.location)
        memory.logAction("\(entry.activity) at \(locationName)", at: clock.timeString)

        guard entry.location != gridPos else { return }
        walkTo(entry.location, navGraph: navGraph)
    }

    private func restoreScheduleActivity(clock: GameClock) {
        for entry in schedule.reversed() {
            if clock.totalMinutes >= triggerMinute(for: entry) {
                currentActivity = entry.activity
                updateLabel()
                return
            }
        }
    }

    private func updateLabel() {
        label.text = currentActivity.isEmpty ? name : "\(name): \(currentActivity)"
    }

    // MARK: - Movement

    private func walkTo(_ target: GridPosition, navGraph: GKGridGraph<GKGridGraphNode>) {
        guard let startNode = navGraph.node(atGridPosition: vector_int2(Int32(gridPos.col), Int32(gridPos.row))),
              let endNode = navGraph.node(atGridPosition: vector_int2(Int32(target.col), Int32(target.row)))
        else { return }

        let path = navGraph.findPath(from: startNode, to: endNode)
        guard let gridPath = path as? [GKGridGraphNode], gridPath.count > 1 else { return }

        isWalking = true
        var actions: [SKAction] = []

        for node in gridPath.dropFirst() {
            let col = Int(node.gridPosition.x)
            let row = Int(node.gridPosition.y)
            actions.append(SKAction.move(to: tilePosition(GridPosition(col: col, row: row)), duration: 0.25))
        }

        let lastNode = gridPath.last!
        actions.append(SKAction.run { [weak self] in
            guard let self else { return }
            self.gridPos = GridPosition(col: Int(lastNode.gridPosition.x), row: Int(lastNode.gridPosition.y))
            self.isWalking = false
        })

        sprite.run(SKAction.sequence(actions))
    }

    private func tilePosition(_ pos: GridPosition) -> CGPoint {
        CGPoint(
            x: CGFloat(pos.col) * tileSize + tileSize / 2,
            y: CGFloat(mapRows - 1 - pos.row) * tileSize + tileSize / 2
        )
    }
}
