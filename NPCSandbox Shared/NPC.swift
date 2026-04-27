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
    /// Distinctive voice notes injected into the model's Instructions. Concrete
    /// quirks/opinions/pet peeves so the model has texture to draw from instead
    /// of falling back to polite small talk.
    let personality: String
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
    /// dialogue prompts AND parsed into schedule shifts so the day's rhythm
    /// actually deviates when intentions call for it.
    var intentions: [String] = [] {
        didSet { applyIntentionsToSchedule() }
    }

    /// Per-entry minute offsets derived from `intentions`. Combined with
    /// `scheduleJitter` in `triggerMinute(for:)` to compute when an entry fires.
    private(set) var scheduleShifts: [Int: Int] = [:]

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

    // MARK: - Needs (energy + social)

    /// Drains during the day; restores when the NPC is at home / sleeping.
    /// Low energy -> "tired" mood, dialogue colored accordingly.
    private(set) var energy: Double = 1.0
    /// Drains in isolation; +0.3 boost on each chat. Low social -> "withdrawn".
    private(set) var social: Double = 0.7
    private var lastNeedsTickMinute: Int = -1

    /// Tick needs forward. Called every frame from GameScene.update().
    func tickNeeds(currentMinute: Int) {
        if lastNeedsTickMinute < 0 || currentMinute < lastNeedsTickMinute {
            lastNeedsTickMinute = currentMinute
            return
        }
        let delta = currentMinute - lastNeedsTickMinute
        guard delta > 0 else { return }
        lastNeedsTickMinute = currentMinute

        let isAtHome = currentActivity.lowercased().contains("home")
            || currentActivity.lowercased().contains("waking")
            || currentActivity.lowercased().contains("sleep")
        let energyDelta = (isAtHome ? 0.003 : -0.001) * Double(delta)
        energy = max(0, min(1, energy + energyDelta))
        social = max(0, min(1, social - 0.0006 * Double(delta)))
    }

    /// Boost social when a chat happens.
    func registerChatNeedBoost() {
        social = min(1, social + 0.3)
    }

    /// Derived mood string. Surfaced into dialogue prompts so voice
    /// reflects current state — "tired" when low energy, "withdrawn"
    /// when low social, "cheerful" when both are high, etc.
    var currentMood: String {
        if energy < 0.25 && social < 0.3 { return "spent and a little lonely" }
        if energy < 0.25 { return "tired" }
        if social < 0.25 { return "a bit withdrawn" }
        if energy > 0.8 && social > 0.7 { return "lively" }

        let sentimentValues = relationships.values.map { $0.sentiment }
        let avgSentiment = sentimentValues.isEmpty ? 0 :
            Double(sentimentValues.reduce(0, +)) / Double(sentimentValues.count)
        if avgSentiment > 2 { return "content" }
        if avgSentiment < -2 { return "uneasy" }
        return "settled"
    }

    // MARK: - Wandering

    private var lastWanderMinute: Int = -100
    private let wanderRadius = 2
    private let wanderIntervalMinutes = 8
    private let slackBeforeWanderMinutes = 5

    init(name: String, role: String, personality: String, tileID: Int, startPos: GridPosition,
         schedule: [ScheduleEntry], sociability: Double, dialogueColor: SKColor,
         tileSize: CGFloat, mapRows: Int) {
        self.name = name
        self.role = role
        self.personality = personality
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
        entry.totalMinutes
            + (scheduleJitter[entry.totalMinutes] ?? 0)
            + (scheduleShifts[entry.totalMinutes] ?? 0)
    }

    /// Translate today's intentions into schedule shifts via keyword match.
    /// Best-effort: catches the obvious shapes ("rise earlier", "linger after
    /// lunch", "late evening") and ignores the rest.
    private func applyIntentionsToSchedule() {
        scheduleShifts.removeAll()
        guard !intentions.isEmpty else { return }
        let text = intentions.joined(separator: " ").lowercased()

        if text.contains("earlier") || text.contains("before dawn") || text.contains("at dawn") || text.contains("rise early") {
            if let first = schedule.first {
                scheduleShifts[first.totalMinutes, default: 0] -= 20
            }
        }

        if text.contains("linger") || text.contains("longer") || text.contains("stay") {
            for (i, entry) in schedule.enumerated() where i < schedule.count - 1 {
                let lastWord = entry.activity.lowercased().split(separator: " ").last.map(String.init) ?? ""
                if !lastWord.isEmpty && text.contains(lastWord) {
                    let next = schedule[i + 1]
                    scheduleShifts[next.totalMinutes, default: 0] += 25
                    break
                }
            }
        }

        if text.contains("late evening") || text.contains("after dinner") || text.contains("late at night") {
            if let last = schedule.last {
                scheduleShifts[last.totalMinutes, default: 0] += 30
            }
        }

        if !scheduleShifts.isEmpty {
            let summary = scheduleShifts
                .sorted { $0.key < $1.key }
                .map { String(format: "%02d:%02d %@%d", $0.key / 60, $0.key % 60, $0.value >= 0 ? "+" : "", $0.value) }
                .joined(separator: ", ")
            print("[\(name)] schedule shifts from intentions: \(summary)")
        }
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
        registerChatNeedBoost()
    }

    func endChat(clock: GameClock) {
        guard isInterrupted else { return }
        isInterrupted = false
        restoreScheduleActivity(clock: clock)
    }

    /// Player-chat versions: same interrupt semantics, no chat-cooldown bookkeeping
    /// (the player isn't another NPC and shouldn't take up the daily social budget).
    func beginPlayerChat(clock: GameClock) {
        isInterrupted = true
        let location = MapLocation.nearestName(to: gridPos)
        memory.logAction("Talking with a visitor near \(location)", at: clock.timeString)
        currentActivity = "Talking"
        updateLabel()
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

    /// When idle near a schedule destination with significant slack until the
    /// next entry, take a small unscheduled wander so NPCs don't stand frozen
    /// waiting for the next schedule trigger.
    func considerWander(clock: GameClock, navGraph: GKGridGraph<GKGridGraphNode>) {
        guard !isInterrupted, !isWalking else { return }
        let now = clock.totalMinutes
        if now - lastWanderMinute < wanderIntervalMinutes { return }

        // Find the active entry's anchor location.
        var activeEntry: ScheduleEntry?
        for entry in schedule.reversed() {
            if now >= triggerMinute(for: entry) { activeEntry = entry; break }
        }
        guard let anchor = activeEntry?.location else { return }

        let distFromAnchor = abs(gridPos.col - anchor.col) + abs(gridPos.row - anchor.row)
        guard distFromAnchor <= wanderRadius else { return }

        // Slack — must have time until the next entry actually fires.
        let nextTrigger = schedule
            .first { triggerMinute(for: $0) > now }
            .map { triggerMinute(for: $0) } ?? Int.max
        guard nextTrigger - now > slackBeforeWanderMinutes else { return }

        // Pick a random walkable tile within wanderRadius of the ANCHOR
        // (not current position) so wanders stay bounded around the spot.
        var candidates: [GridPosition] = []
        for dr in -wanderRadius...wanderRadius {
            for dc in -wanderRadius...wanderRadius {
                if dr == 0 && dc == 0 { continue }
                let pos = GridPosition(col: anchor.col + dc, row: anchor.row + dr)
                if pos == gridPos { continue }
                if navGraph.node(atGridPosition: vector_int2(Int32(pos.col), Int32(pos.row))) != nil {
                    candidates.append(pos)
                }
            }
        }
        guard let target = candidates.randomElement() else { return }
        lastWanderMinute = now
        walkTo(target, navGraph: navGraph)
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
