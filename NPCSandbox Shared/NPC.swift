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
    private var interruptEndMinute: Int = 0
    private var chatCooldowns: [String: Int] = [:]
    private let chatCooldownMinutes = 120
    private let baseChatDurationMinutes = 15
    private let perTurnChatDurationMinutes = 8

    init(name: String, role: String, tileID: Int, startPos: GridPosition, schedule: [ScheduleEntry],
         sociability: Double, tileSize: CGFloat, mapRows: Int) {
        self.name = name
        self.role = role
        self.gridPos = startPos
        self.schedule = schedule.sorted { $0.totalMinutes < $1.totalMinutes }
        self.sociability = sociability
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
        label.fontSize = 4
        label.fontColor = .white
        label.fontName = "Helvetica-Bold"
        label.verticalAlignmentMode = .bottom
        label.position = CGPoint(x: 0, y: tileSize * 0.6)
        label.zPosition = 11
        sprite.addChild(label)
    }

    // MARK: - Day Reset

    func resetForNewDay() {
        lastTriggeredMinute = -1
        chatCooldowns.removeAll()
        isInterrupted = false
        currentActivity = ""
        updateLabel()
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

        return utility
    }

    var scheduleUtility: Double {
        isWalking ? 0.8 : 0.3
    }

    // MARK: - Interrupts

    func beginChat(with other: NPC, clock: GameClock, turnCount: Int) {
        isInterrupted = true
        interruptEndMinute = clock.totalMinutes + baseChatDurationMinutes + turnCount * perTurnChatDurationMinutes
        chatCooldowns[other.name] = clock.totalMinutes

        let location = MapLocation.nearestName(to: gridPos)
        memory.logAction("Chatting with \(other.name) near \(location)", at: clock.timeString)

        currentActivity = "Chatting"
        updateLabel()
    }

    // MARK: - Schedule

    func checkSchedule(clock: GameClock, navGraph: GKGridGraph<GKGridGraphNode>) {
        if isInterrupted {
            if clock.totalMinutes >= interruptEndMinute {
                isInterrupted = false
                restoreScheduleActivity(clock: clock)
            } else {
                return
            }
        }

        guard !isWalking else { return }

        let now = clock.totalMinutes

        var activeEntry: ScheduleEntry?
        for entry in schedule.reversed() {
            if now >= entry.totalMinutes {
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
            if clock.totalMinutes >= entry.totalMinutes {
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
