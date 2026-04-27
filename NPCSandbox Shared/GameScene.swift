import SpriteKit
import GameplayKit
#if os(iOS)
import UIKit
#endif

@MainActor
class GameScene: SKScene {

    private let mapColumns = 20
    private let mapRows = 15
    private let tileSize: CGFloat = 16

    private var navGraph: GKGridGraph<GKGridGraphNode>!
    private var gameClock = GameClock()
    private var npcs: [NPC] = []
    private var timeLabel: SKLabelNode!
    private var lastUpdateTime: TimeInterval = 0
    private var didReflectToday = false
    private var currentDay: Int = 1
    private var dialogNode: SKNode?
    private var chatBackground: SKShapeNode?
    private var chatLines: [SKLabelNode] = []
    private var currentThinkingLabel: SKLabelNode?
    private var waitingForDialogue = false
    private var skyOverlay: SKSpriteNode!

    // Player chat state (iOS only).
    private var playerChatActive = false
    private var playerChatNPC: NPC?
    private var playerChatTranscript: [String] = []
    private var playerChatNPCThinking = false
    private var playerChatNPCActivity = ""
    private var playerChatNPCActivityDuration = ""
    #if os(iOS)
    private var playerInputField: UITextField?
    private var playerInputDelegate: PlayerInputDelegate?
    #endif

    private let playerColor = SKColor(red: 1.0, green: 1.0, blue: 0.85, alpha: 1)

    private let chatBoxMargin: CGFloat = 6
    private let chatPadding: CGFloat = 6
    private let chatFontSize: CGFloat = 7
    private let chatLineSpacing: CGFloat = 2

    class func newGameScene() -> GameScene {
        let scene = GameScene(size: CGSize(width: 320, height: 240))
        scene.scaleMode = .aspectFit
        return scene
    }

    override func didMove(to view: SKView) {
        backgroundColor = .black
        let overlay = buildOverlayData()
        renderTileMap(overlay: overlay)
        buildNavGraph(from: overlay)
        spawnNPCs()
        setupSkyOverlay()
        setupHUD()
        for npc in npcs {
            NPCBrain.warmUp(npcName: npc.name, role: npc.role)
        }
    }

    // MARK: - Tile Map

    private func renderTileMap(overlay: [[Int]]) {
        let atlas = SKTextureAtlas(named: "TinyTown")
        var textureCache: [Int: SKTexture] = [:]

        func texture(for id: Int) -> SKTexture {
            if let cached = textureCache[id] { return cached }
            let name = String(format: "tile_%04d", id)
            let tex = atlas.textureNamed(name)
            tex.filteringMode = .nearest
            textureCache[id] = tex
            return tex
        }

        let grassTexture = texture(for: TownTile.grass)

        for row in 0..<mapRows {
            for col in 0..<mapColumns {
                let grassSprite = SKSpriteNode(texture: grassTexture)
                grassSprite.position = tilePosition(col: col, row: row)
                addChild(grassSprite)

                let overlayID = overlay[row][col]
                if overlayID >= 0 {
                    let sprite = SKSpriteNode(texture: texture(for: overlayID))
                    sprite.position = tilePosition(col: col, row: row)
                    sprite.zPosition = 1
                    addChild(sprite)
                }
            }
        }
    }

    private func buildOverlayData() -> [[Int]] {
        let P = TownTile.path
        let T = TownTile.treePine
        let G = TownTile.treeGreen
        let W = TownTile.wheat
        let _ = -1 // grass (unused var to clarify intent)

        // Start with all grass
        var grid = Array(repeating: Array(repeating: -1, count: mapColumns), count: mapRows)

        // Trees around edges
        let treePositions: [(Int, Int, Int)] = [
            (0,0,T), (0,1,G), (0,2,T), (0,17,T), (0,18,G), (0,19,T),
            (1,0,G), (1,19,G),
            (13,0,G), (13,19,G),
            (14,0,T), (14,1,G), (14,2,T), (14,7,T), (14,11,T), (14,17,T), (14,18,G), (14,19,T),
        ]
        for (r, c, tile) in treePositions {
            grid[r][c] = tile
        }

        // Main street (vertical, column 9)
        for row in 1...12 {
            grid[row][9] = P
        }

        // Cross street (horizontal, row 7)
        for col in 2...17 {
            grid[7][col] = P
        }

        // Bakery — blue house, upper left
        placeBuilding(TownTile.blueHouse, in: &grid, atRow: 2, col: 3)

        // Path branch from bakery to main street (row 4, cols 7-8)
        grid[4][7] = P
        grid[4][8] = P

        // Tavern — red house, upper right
        placeBuilding(TownTile.redHouse, in: &grid, atRow: 2, col: 12)

        // Path branch from tavern to main street (row 4, cols 10-11)
        grid[4][10] = P
        grid[4][11] = P

        // Farmhouse — blue house, lower left
        placeBuilding(TownTile.blueHouse, in: &grid, atRow: 9, col: 3)

        // Path branch from farmhouse to main street (row 11, cols 7-8)
        grid[11][7] = P
        grid[11][8] = P

        // Farm fields (lower right)
        for row in 9...12 {
            for col in 13...15 {
                grid[row][col] = W
            }
        }

        return grid
    }

    private func placeBuilding(_ building: [[Int]], in grid: inout [[Int]], atRow row: Int, col: Int) {
        for (dr, tileRow) in building.enumerated() {
            for (dc, tileID) in tileRow.enumerated() {
                let r = row + dr
                let c = col + dc
                if r < mapRows && c < mapColumns {
                    grid[r][c] = tileID
                }
            }
        }
    }

    private func tilePosition(col: Int, row: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(col) * tileSize + tileSize / 2,
            y: CGFloat(mapRows - 1 - row) * tileSize + tileSize / 2
        )
    }

    // MARK: - Navigation

    private func buildNavGraph(from overlay: [[Int]]) {
        let graph = GKGridGraph(
            fromGridStartingAt: vector_int2(0, 0),
            width: Int32(mapColumns),
            height: Int32(mapRows),
            diagonalsAllowed: false
        )

        var nodesToRemove: [GKGridGraphNode] = []
        for row in 0..<mapRows {
            for col in 0..<mapColumns {
                let tileID = overlay[row][col]
                let walkable = tileID == -1
                    || tileID == TownTile.path
                    || tileID == TownTile.wheat
                if !walkable {
                    if let node = graph.node(atGridPosition: vector_int2(Int32(col), Int32(row))) {
                        nodesToRemove.append(node)
                    }
                }
            }
        }
        graph.remove(nodesToRemove)
        navGraph = graph
    }

    // MARK: - NPCs

    private func spawnNPCs() {
        let baker = NPC(
            name: "Elara",
            role: "the village baker",
            tileID: CharTile.villager1,
            startPos: MapLocation.bakeryDoor,
            schedule: [
                ScheduleEntry(hour: 6, minute: 0, location: MapLocation.bakeryDoor, activity: "Baking"),
                ScheduleEntry(hour: 6, minute: 30, location: MapLocation.townSquare, activity: "Morning stroll"),
                ScheduleEntry(hour: 8, minute: 0, location: MapLocation.bakeryDoor, activity: "Baking"),
                ScheduleEntry(hour: 10, minute: 0, location: MapLocation.townSquare, activity: "Buying supplies"),
                ScheduleEntry(hour: 11, minute: 0, location: MapLocation.bakeryDoor, activity: "Baking"),
                ScheduleEntry(hour: 13, minute: 0, location: MapLocation.tavernDoor, activity: "Delivering bread"),
                ScheduleEntry(hour: 14, minute: 0, location: MapLocation.bakeryDoor, activity: "Baking"),
                ScheduleEntry(hour: 17, minute: 0, location: MapLocation.townSquare, activity: "Evening walk"),
                ScheduleEntry(hour: 19, minute: 0, location: MapLocation.bakeryDoor, activity: "Home"),
            ],
            sociability: 0.7,
            dialogueColor: SKColor(red: 0.6, green: 0.9, blue: 1.0, alpha: 1),
            tileSize: tileSize,
            mapRows: mapRows
        )

        let keeper = NPC(
            name: "Mora",
            role: "the tavern keeper",
            tileID: CharTile.villager3,
            startPos: MapLocation.tavernDoor,
            schedule: [
                ScheduleEntry(hour: 6, minute: 30, location: MapLocation.townSquare, activity: "Morning walk"),
                ScheduleEntry(hour: 8, minute: 0, location: MapLocation.tavernDoor, activity: "Opening tavern"),
                ScheduleEntry(hour: 10, minute: 0, location: MapLocation.bakeryDoor, activity: "Picking up bread"),
                ScheduleEntry(hour: 11, minute: 0, location: MapLocation.tavernDoor, activity: "Preparing"),
                ScheduleEntry(hour: 13, minute: 0, location: MapLocation.tavernDoor, activity: "Serving lunch"),
                ScheduleEntry(hour: 15, minute: 0, location: MapLocation.townSquare, activity: "Afternoon break"),
                ScheduleEntry(hour: 16, minute: 0, location: MapLocation.tavernDoor, activity: "Serving"),
                ScheduleEntry(hour: 17, minute: 0, location: MapLocation.townSquare, activity: "Strolling"),
                ScheduleEntry(hour: 18, minute: 30, location: MapLocation.tavernDoor, activity: "Evening service"),
                ScheduleEntry(hour: 21, minute: 0, location: MapLocation.tavernDoor, activity: "Closing"),
            ],
            sociability: 0.8,
            dialogueColor: SKColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 1),
            tileSize: tileSize,
            mapRows: mapRows
        )

        let farmer = NPC(
            name: "Gareth",
            role: "the village farmer",
            tileID: CharTile.villager2,
            startPos: MapLocation.farmhouseDoor,
            schedule: [
                ScheduleEntry(hour: 6, minute: 0, location: MapLocation.farmhouseDoor, activity: "Waking up"),
                ScheduleEntry(hour: 6, minute: 30, location: MapLocation.townSquare, activity: "Morning walk"),
                ScheduleEntry(hour: 7, minute: 30, location: MapLocation.farmField, activity: "Working the fields"),
                ScheduleEntry(hour: 9, minute: 0, location: MapLocation.bakeryDoor, activity: "Delivering grain"),
                ScheduleEntry(hour: 10, minute: 30, location: MapLocation.farmField, activity: "Working the fields"),
                ScheduleEntry(hour: 13, minute: 0, location: MapLocation.tavernDoor, activity: "Lunch"),
                ScheduleEntry(hour: 14, minute: 30, location: MapLocation.farmField, activity: "Working the fields"),
                ScheduleEntry(hour: 17, minute: 0, location: MapLocation.townSquare, activity: "Evening walk"),
                ScheduleEntry(hour: 19, minute: 0, location: MapLocation.farmhouseDoor, activity: "Home"),
            ],
            sociability: 0.6,
            dialogueColor: SKColor(red: 0.75, green: 1.0, blue: 0.7, alpha: 1),
            tileSize: tileSize,
            mapRows: mapRows
        )

        npcs = [baker, keeper, farmer]
        for npc in npcs {
            addChild(npc.sprite)
        }
    }

    // MARK: - Sky overlay

    private func setupSkyOverlay() {
        skyOverlay = SKSpriteNode(color: .black, size: size)
        skyOverlay.anchorPoint = .zero
        skyOverlay.position = .zero
        skyOverlay.zPosition = 50
        skyOverlay.alpha = 0
        addChild(skyOverlay)
        updateSkyOverlay()
    }

    /// Lerp through dawn/day/dusk/night anchors so the world tints with the clock.
    private func updateSkyOverlay() {
        guard let skyOverlay else { return }
        let t = CGFloat(gameClock.hour) + CGFloat(gameClock.minute) / 60
        let stops: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            // hour, r, g, b, alpha
            (0,  0.05, 0.05, 0.20, 0.55),  // deep night
            (5,  0.05, 0.05, 0.20, 0.55),
            (6,  0.95, 0.55, 0.45, 0.30),  // dawn
            (7,  1.00, 1.00, 1.00, 0.00),  // clear morning
            (17, 1.00, 1.00, 1.00, 0.00),  // clear afternoon
            (18, 0.95, 0.45, 0.30, 0.30),  // dusk
            (19, 0.40, 0.20, 0.45, 0.45),  // late dusk / blue hour
            (21, 0.05, 0.05, 0.20, 0.55),  // deep night
            (24, 0.05, 0.05, 0.20, 0.55),
        ]
        var prev = stops[0]
        for stop in stops.dropFirst() {
            if t <= stop.0 {
                let span = stop.0 - prev.0
                let frac = span > 0 ? (t - prev.0) / span : 0
                skyOverlay.color = SKColor(
                    red: prev.1 + (stop.1 - prev.1) * frac,
                    green: prev.2 + (stop.2 - prev.2) * frac,
                    blue: prev.3 + (stop.3 - prev.3) * frac,
                    alpha: 1
                )
                skyOverlay.alpha = prev.4 + (stop.4 - prev.4) * frac
                return
            }
            prev = stop
        }
        skyOverlay.color = SKColor(red: prev.1, green: prev.2, blue: prev.3, alpha: 1)
        skyOverlay.alpha = prev.4
    }

    // MARK: - HUD

    private func setupHUD() {
        timeLabel = SKLabelNode(text: gameClock.timeString)
        timeLabel.fontSize = 8
        timeLabel.fontColor = .yellow
        timeLabel.fontName = "Menlo-Bold"
        timeLabel.horizontalAlignmentMode = .left
        timeLabel.verticalAlignmentMode = .top
        timeLabel.position = CGPoint(x: 4, y: size.height - 4)
        timeLabel.zPosition = 100
        addChild(timeLabel)
    }

    // MARK: - Observation

    private let observationRadius = 3

    private func checkObservations() {
        let now = gameClock.totalMinutes

        // Observations (asymmetric)
        for i in 0..<npcs.count {
            for j in 0..<npcs.count where i != j {
                let observer = npcs[i]
                let target = npcs[j]
                let dist = abs(observer.gridPos.col - target.gridPos.col)
                    + abs(observer.gridPos.row - target.gridPos.row)
                if dist <= observationRadius {
                    let activity = target.currentActivity.isEmpty
                        ? "nearby"
                        : target.currentActivity.lowercased()
                    let location = MapLocation.nearestName(to: target.gridPos)
                    let text = "Saw \(target.name) \(activity) near \(location)"
                    observer.memory.observe(
                        text,
                        at: gameClock.timeString,
                        about: target.name,
                        currentMinutes: now
                    )
                }
            }
        }

        // Group chat detection: if all NPCs are mutually within radius and
        // eligible, run a 3+ way conversation instead of a pair. This keeps
        // the third (or fourth) NPC from being structurally excluded when
        // everyone converges at the same square.
        if npcs.count >= 3,
           npcs.allSatisfy({ !$0.isInterrupted && !$0.isWalking }) {
            let allClose = (0..<npcs.count).allSatisfy { i in
                ((i + 1)..<npcs.count).allSatisfy { j in
                    let dx = abs(npcs[i].gridPos.col - npcs[j].gridPos.col)
                    let dy = abs(npcs[i].gridPos.row - npcs[j].gridPos.row)
                    return dx + dy <= observationRadius
                }
            }
            if allClose {
                let wantCount = npcs.reduce(0) { acc, npc in
                    let bestUtility = npcs
                        .filter { $0 !== npc }
                        .map { npc.socialUtility(with: $0, currentMinutes: now) }
                        .max() ?? 0
                    return acc + (bestUtility > npc.scheduleUtility ? 1 : 0)
                }
                if wantCount >= 2 {
                    requestGroupDialogue(participants: npcs, turnCount: 5)
                    return
                }
            }
        }

        // Collect all socially eligible pairs, then pick one at random so
        // no fixed iteration order can lock the third NPC out of conversations.
        var eligiblePairs: [(NPC, NPC)] = []
        for i in 0..<npcs.count {
            for j in (i + 1)..<npcs.count {
                let a = npcs[i]
                let b = npcs[j]
                guard !a.isInterrupted, !b.isInterrupted,
                      !a.isWalking, !b.isWalking else { continue }

                let dist = abs(a.gridPos.col - b.gridPos.col)
                    + abs(a.gridPos.row - b.gridPos.row)
                guard dist <= observationRadius else { continue }

                let aScore = a.socialUtility(with: b, currentMinutes: now)
                let bScore = b.socialUtility(with: a, currentMinutes: now)
                if aScore > a.scheduleUtility && bScore > b.scheduleUtility {
                    eligiblePairs.append((a, b))
                }
            }
        }

        // Agenda v2: when an NPC's nightly intentions named someone in the
        // pair, that pair is the "intentional" one — pick from those first
        // so memory→action actually shows up as a steered chat.
        let intentionalPairs = eligiblePairs.filter { (a, b) in
            a.intentionsName(b) || b.intentionsName(a)
        }
        let pool = intentionalPairs.isEmpty ? eligiblePairs : intentionalPairs

        if let (a, b) = pool.randomElement() {
            if a.intentionsName(b) {
                print("[\(a.name)] honoring intention — seeking out \(b.name)")
            }
            if b.intentionsName(a) {
                print("[\(b.name)] honoring intention — seeking out \(a.name)")
            }
            let turns = turnCount(for: a, b)
            requestDialogue(speaker: a, listener: b, turnCount: turns)
        }
    }

    // MARK: - Update

    override func update(_ currentTime: TimeInterval) {
        let dt: TimeInterval
        if lastUpdateTime == 0 {
            dt = 0
        } else {
            dt = currentTime - lastUpdateTime
        }
        lastUpdateTime = currentTime

        let isNight = gameClock.hour >= 22 || gameClock.hour < 6
        gameClock.minutesPerSecond = isNight ? 60.0 : 5.0

        // While the player is talking with an NPC the world holds still —
        // schedules don't advance, the clock doesn't tick, no other chats
        // start. Lets the user read replies and type without time pressure.
        if playerChatActive { return }

        if gameClock.advance(by: dt) {
            timeLabel.text = gameClock.timeString
            updateSkyOverlay()
        }

        if gameClock.day != currentDay {
            currentDay = gameClock.day
            print("\n=== New Day: \(gameClock.day) ===\n")
            for npc in npcs {
                npc.resetForNewDay()
            }
        }

        for npc in npcs {
            npc.checkSchedule(clock: gameClock, navGraph: navGraph)
        }

        // Gate only the LLM-driven branches: don't kick off a new chat or daily
        // reflection while one is already in flight or while a dialog is open.
        // Clock, schedules, and movement above must keep running so the UI
        // stays responsive during the 5-20s the model takes to respond.
        guard !waitingForDialogue, dialogNode == nil else { return }

        checkObservations()
        checkDailyReflection()
    }

    // MARK: - Input

    private func handleTap(at point: CGPoint) {
        // Player-chat: tap outside the chat bubble closes the chat. Taps
        // inside it (or on the text field, which intercepts at the view
        // layer) are ignored here.
        if playerChatActive {
            if !chatBoxContains(point) {
                endPlayerChat()
            }
            return
        }

        if dialogNode != nil {
            dismissDialog()
            waitingForDialogue = false
            return
        }

        for npc in npcs {
            let dist = hypot(npc.sprite.position.x - point.x, npc.sprite.position.y - point.y)
            if dist < tileSize * 1.2 {
                #if os(iOS)
                startPlayerChat(with: npc)
                #else
                showNPCDialog(for: npc)
                #endif
                return
            }
        }
    }

    private func chatBoxContains(_ scenePoint: CGPoint) -> Bool {
        guard let dialog = dialogNode, let bg = chatBackground else { return false }
        let local = dialog.convert(scenePoint, from: self)
        return bg.frame.contains(local)
    }

    #if os(iOS)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        handleTap(at: touch.location(in: self))
    }
    #endif

    #if os(macOS)
    override func mouseDown(with event: NSEvent) {
        handleTap(at: event.location(in: self))
    }
    #endif

    // MARK: - Dialogue Generation

    /// Average sociability maps to 3-5 turns. Pairs of low-sociability NPCs chat briefly;
    /// chatty pairs linger.
    private func turnCount(for a: NPC, _ b: NPC) -> Int {
        let avg = (a.sociability + b.sociability) / 2
        let normalized = min(max((avg - 0.5) / 0.4, 0), 1)
        return 3 + Int((normalized * 2).rounded())
    }

    /// Group chat with 3+ participants. Round-robin speakers; each turn
    /// addresses the previous speaker, with the rest mentioned as "also here".
    private func requestGroupDialogue(participants: [NPC], turnCount: Int) {
        guard participants.count >= 3 else { return }

        let now = gameClock.totalMinutes
        let timeOfDay = gameClock.timeString
        let location = MapLocation.nearestName(to: participants[0].gridPos)

        struct ParticipantContext: Sendable {
            let name: String
            let role: String
            let activity: String
            let activityDuration: String
            let observations: [String]
            let intentions: [String]
        }
        let contexts = participants.map { npc in
            ParticipantContext(
                name: npc.name,
                role: npc.role,
                activity: npc.currentActivity,
                activityDuration: npc.activityDurationDescription(currentMinutes: now),
                observations: npc.memory.recentObservations(),
                intentions: npc.intentions
            )
        }

        for npc in participants {
            for other in participants where other !== npc {
                npc.beginChat(with: other, clock: gameClock)
            }
        }

        waitingForDialogue = true
        openChatLog()
        prepareNextLine(speaker: contexts[0].name, color: participants[0].dialogueColor)

        let participantsRef = participants

        Task.detached { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.dismissDialog()
                    self?.waitingForDialogue = false
                    if let scene = self {
                        for npc in participantsRef {
                            npc.endChat(clock: scene.gameClock)
                        }
                    }
                }
            }

            do {
                var transcript: [(speaker: String, line: String)] = []

                // Turn 0 — opener addresses the next NPC in the round-robin.
                let opener = contexts[0]
                let primaryListener = contexts[1]
                let othersForOpener = contexts.dropFirst(2).map { $0.name }

                let openingLine = await NPCBrain.generateDialogue(
                    speaker: opener.name,
                    speakerRole: opener.role,
                    listener: primaryListener.name,
                    listenerRole: primaryListener.role,
                    othersPresent: Array(othersForOpener),
                    location: location,
                    timeOfDay: timeOfDay,
                    speakerActivity: opener.activity,
                    speakerActivityDuration: opener.activityDuration,
                    speakerObservations: opener.observations,
                    speakerIntentions: opener.intentions,
                    relationshipNote: nil,
                    priorChatsToday: 0,
                    chatHistory: []
                ) ?? "..."
                transcript.append((opener.name, openingLine))

                await MainActor.run { [weak self] in
                    self?.commitCurrentLine(text: openingLine)
                    if turnCount > 1 {
                        let nextIdx = 1 % contexts.count
                        self?.prepareNextLine(speaker: contexts[nextIdx].name, color: participantsRef[nextIdx].dialogueColor)
                    }
                }

                // Turns 1…N-1 — round-robin responses.
                for turnIndex in 1..<turnCount {
                    if turnIndex > 1 { try await Task.sleep(for: .seconds(2)) }

                    let currentIdx = turnIndex % contexts.count
                    let prevIdx = (turnIndex - 1 + contexts.count) % contexts.count
                    let current = contexts[currentIdx]
                    let prev = contexts[prevIdx]
                    let others = (0..<contexts.count)
                        .filter { $0 != currentIdx && $0 != prevIdx }
                        .map { contexts[$0].name }
                    let isFinal = (turnIndex == turnCount - 1)
                    let inSessionHistory = transcript.map { "\($0.speaker): \"\($0.line)\"" }
                    let prevLine = transcript.last!.line

                    let line = await NPCBrain.generateResponse(
                        responder: current.name,
                        responderRole: current.role,
                        to: prev.name,
                        speakerRole: prev.role,
                        othersPresent: others,
                        location: location,
                        timeOfDay: timeOfDay,
                        responderActivity: current.activity,
                        responderActivityDuration: current.activityDuration,
                        responderObservations: current.observations,
                        responderIntentions: current.intentions,
                        relationshipNote: nil,
                        previousLine: prevLine,
                        chatHistory: inSessionHistory,
                        isFinal: isFinal
                    ) ?? "..."
                    transcript.append((current.name, line))

                    await MainActor.run { [weak self] in
                        self?.commitCurrentLine(text: line)
                        if !isFinal {
                            let nextIdx = (turnIndex + 1) % contexts.count
                            self?.prepareNextLine(speaker: contexts[nextIdx].name, color: participantsRef[nextIdx].dialogueColor)
                        }
                    }
                }

                // Memory: log every line on every other participant's stream.
                let finalTranscript = transcript
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let timeStr = self.gameClock.timeString
                    for entry in finalTranscript {
                        print("[\(timeStr)] [DLG] \(entry.speaker): \"\(entry.line)\"")
                        for npc in participantsRef where npc.name != entry.speaker {
                            npc.memory.logDialogue(speaker: entry.speaker, partner: entry.speaker, line: entry.line, at: timeStr)
                        }
                    }
                }

                try await Task.sleep(for: .seconds(3))
            } catch {
                print("[GroupDialogue] cancelled or failed: \(error)")
            }
        }
    }

    private func requestDialogue(speaker: NPC, listener: NPC, turnCount: Int) {
        // Capture grounding context BEFORE beginChat overwrites currentActivity
        // with "Chatting" — we want the prior activity to feed prompts.
        let now = gameClock.totalMinutes
        let speakerName = speaker.name
        let speakerRole = speaker.role
        let speakerColor = speaker.dialogueColor
        let listenerName = listener.name
        let listenerRole = listener.role
        let listenerColor = listener.dialogueColor
        let location = MapLocation.nearestName(to: speaker.gridPos)
        let speakerActivity = speaker.currentActivity
        let listenerActivity = listener.currentActivity
        let speakerActivityDuration = speaker.activityDurationDescription(currentMinutes: now)
        let listenerActivityDuration = listener.activityDurationDescription(currentMinutes: now)
        let speakerObservations = speaker.memory.recentObservations()
        let listenerObservations = listener.memory.recentObservations()
        let speakerIntentions = speaker.intentions
        let listenerIntentions = listener.intentions
        let speakerRelationshipNote = speaker.relationshipNote(with: listenerName)
        let listenerRelationshipNote = listener.relationshipNote(with: speakerName)
        let speakerHistory = speaker.memory.recentChatHistory(with: listenerName)
        let priorChats = speaker.memory.chatSessionCount(with: listenerName)
        let timeOfDay = gameClock.timeString

        speaker.beginChat(with: listener, clock: gameClock)
        listener.beginChat(with: speaker, clock: gameClock)

        waitingForDialogue = true
        openChatLog()
        prepareNextLine(speaker: speakerName, color: speakerColor)

        Task.detached { [weak self, weak speaker, weak listener] in
            defer {
                Task { @MainActor [weak self, weak speaker, weak listener] in
                    self?.dismissDialog()
                    self?.waitingForDialogue = false
                    if let self {
                        speaker?.endChat(clock: self.gameClock)
                        listener?.endChat(clock: self.gameClock)
                    }
                }
            }

            do {
                // Turn 1 — speaker opens.
                let openingLine = await NPCBrain.generateDialogue(
                    speaker: speakerName,
                    speakerRole: speakerRole,
                    listener: listenerName,
                    listenerRole: listenerRole,
                    location: location,
                    timeOfDay: timeOfDay,
                    speakerActivity: speakerActivity,
                    speakerActivityDuration: speakerActivityDuration,
                    speakerObservations: speakerObservations,
                    speakerIntentions: speakerIntentions,
                    relationshipNote: speakerRelationshipNote,
                    priorChatsToday: priorChats,
                    chatHistory: speakerHistory
                ) ?? "Good day!"

                var transcript: [(speaker: String, line: String)] = [(speakerName, openingLine)]

                await MainActor.run { [weak self] in
                    self?.commitCurrentLine(text: openingLine)
                    if turnCount > 1 {
                        self?.prepareNextLine(speaker: listenerName, color: listenerColor)
                    }
                }

                // Turns 2…N — alternate sides, each replying to the previous line.
                for turnIndex in 1..<turnCount {
                    if turnIndex > 1 {
                        try await Task.sleep(for: .seconds(2))
                    }

                    let responderIsListener = (turnIndex % 2 == 1)
                    let responderName = responderIsListener ? listenerName : speakerName
                    let responderRole = responderIsListener ? listenerRole : speakerRole
                    let otherName = responderIsListener ? speakerName : listenerName
                    let otherRole = responderIsListener ? speakerRole : listenerRole
                    let responderActivity = responderIsListener ? listenerActivity : speakerActivity
                    let responderActivityDuration = responderIsListener ? listenerActivityDuration : speakerActivityDuration
                    let responderObservations = responderIsListener ? listenerObservations : speakerObservations
                    let responderIntentions = responderIsListener ? listenerIntentions : speakerIntentions
                    let responderRelationshipNote = responderIsListener ? listenerRelationshipNote : speakerRelationshipNote
                    let nextResponderName = responderIsListener ? speakerName : listenerName
                    let nextResponderColor = responderIsListener ? speakerColor : listenerColor
                    let isFinal = (turnIndex == turnCount - 1)

                    let inSessionHistory = transcript.map { "\($0.speaker): \"\($0.line)\"" }
                    let prevLine = transcript.last!.line

                    let line = await NPCBrain.generateResponse(
                        responder: responderName,
                        responderRole: responderRole,
                        to: otherName,
                        speakerRole: otherRole,
                        location: location,
                        timeOfDay: timeOfDay,
                        responderActivity: responderActivity,
                        responderActivityDuration: responderActivityDuration,
                        responderObservations: responderObservations,
                        responderIntentions: responderIntentions,
                        relationshipNote: responderRelationshipNote,
                        previousLine: prevLine,
                        chatHistory: inSessionHistory,
                        isFinal: isFinal
                    ) ?? "..."

                    transcript.append((responderName, line))

                    await MainActor.run { [weak self] in
                        self?.commitCurrentLine(text: line)
                        if !isFinal {
                            self?.prepareNextLine(speaker: nextResponderName, color: nextResponderColor)
                        }
                    }
                }

                // Flush the entire exchange to both NPCs' memory streams in one shot.
                let finalTranscript = transcript
                await MainActor.run { [weak self, weak speaker, weak listener] in
                    guard let self else { return }
                    let timeStr = self.gameClock.timeString
                    for entry in finalTranscript {
                        print("[\(timeStr)] [DLG] \(entry.speaker): \"\(entry.line)\"")
                        speaker?.memory.logDialogue(speaker: entry.speaker, partner: listenerName, line: entry.line, at: timeStr)
                        listener?.memory.logDialogue(speaker: entry.speaker, partner: speakerName, line: entry.line, at: timeStr)
                    }
                }

                // Fire-and-forget sentiment rating in the background. Each NPC
                // rates the exchange from their own session; results land on
                // the NPC asynchronously so the UI dismiss isn't delayed.
                let transcriptStrings = finalTranscript.map { "\($0.speaker): \"\($0.line)\"" }
                Task.detached { [weak speaker, weak listener] in
                    async let speakerRating = NPCBrain.rateExchange(
                        npcName: speakerName, role: speakerRole,
                        partner: listenerName, transcript: transcriptStrings
                    )
                    async let listenerRating = NPCBrain.rateExchange(
                        npcName: listenerName, role: listenerRole,
                        partner: speakerName, transcript: transcriptStrings
                    )
                    let (sRating, lRating) = await (speakerRating, listenerRating)
                    await MainActor.run { [weak speaker, weak listener] in
                        if let r = sRating {
                            speaker?.recordChatRating(partner: listenerName, affinity: r.affinity, summary: r.summary)
                        }
                        if let r = lRating {
                            listener?.recordChatRating(partner: speakerName, affinity: r.affinity, summary: r.summary)
                        }
                    }
                }

                try await Task.sleep(for: .seconds(3))
            } catch {
                print("[Dialogue] cancelled or failed: \(error)")
            }
        }
    }

    private func openChatLog() {
        dismissDialog()

        let container = SKNode()
        container.zPosition = 200

        let boxWidth = size.width - chatBoxMargin * 2
        let bg = SKShapeNode(rect: CGRect(x: 0, y: 0, width: boxWidth, height: chatPadding * 2),
                             cornerRadius: 2)
        bg.fillColor = SKColor(red: 0.08, green: 0.08, blue: 0.18, alpha: 0.95)
        bg.strokeColor = SKColor(red: 0.45, green: 0.5, blue: 0.7, alpha: 1)
        bg.lineWidth = 1
        container.addChild(bg)

        container.position = CGPoint(x: chatBoxMargin, y: chatBoxMargin)
        addChild(container)
        dialogNode = container
        chatBackground = bg
        chatLines = []
        currentThinkingLabel = nil
    }

    /// Append a "Speaker: ..." placeholder line that animates the thinking dots
    /// until `commitCurrentLine` replaces its text.
    private func prepareNextLine(speaker: String, color: SKColor) {
        guard let container = dialogNode else { return }
        let boxWidth = size.width - chatBoxMargin * 2

        let label = SKLabelNode(text: "\(speaker): .")
        label.fontName = "Menlo"
        label.fontSize = chatFontSize
        label.fontColor = color
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .top
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = boxWidth - chatPadding * 2
        container.addChild(label)
        chatLines.append(label)
        currentThinkingLabel = label

        let dot1 = "\(speaker): ."
        let dot2 = "\(speaker): .."
        let dot3 = "\(speaker): ..."
        let action = SKAction.repeatForever(SKAction.sequence([
            SKAction.run { [weak label] in label?.text = dot1 },
            SKAction.wait(forDuration: 0.3),
            SKAction.run { [weak label] in label?.text = dot2 },
            SKAction.wait(forDuration: 0.3),
            SKAction.run { [weak label] in label?.text = dot3 },
            SKAction.wait(forDuration: 0.3),
        ]))
        label.run(action, withKey: "thinking")
        relayoutChatLog()
    }

    /// Replace the current thinking label's dots with the real dialogue line.
    private func commitCurrentLine(text: String) {
        guard let label = currentThinkingLabel else { return }
        label.removeAction(forKey: "thinking")

        if let prefixEnd = label.text?.range(of: ": ") {
            let speakerPrefix = String(label.text![..<prefixEnd.upperBound])
            label.text = "\(speakerPrefix)\"\(text)\""
        } else {
            label.text = "\"\(text)\""
        }
        currentThinkingLabel = nil
        relayoutChatLog()
    }

    /// Stack lines top-to-bottom inside the box and resize the background
    /// to fit. Layout is recomputed any time text changes (and thus heights).
    private func relayoutChatLog() {
        guard dialogNode != nil, let bg = chatBackground else { return }
        let boxWidth = size.width - chatBoxMargin * 2

        var heights: [CGFloat] = []
        var totalHeight: CGFloat = chatPadding
        for label in chatLines {
            let h = max(label.frame.height, chatFontSize)
            heights.append(h)
            totalHeight += h + chatLineSpacing
        }
        totalHeight += chatPadding - chatLineSpacing

        for (i, label) in chatLines.enumerated() {
            var yFromTop = chatPadding
            for prior in heights.prefix(i) { yFromTop += prior + chatLineSpacing }
            label.position = CGPoint(x: chatPadding, y: totalHeight - yFromTop)
        }

        bg.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: boxWidth, height: totalHeight),
                         cornerWidth: 2, cornerHeight: 2, transform: nil)
    }

    // MARK: - Dialog

    private func showNPCDialog(for npc: NPC) {
        dismissDialog()

        let container = SKNode()
        container.zPosition = 200

        let margin: CGFloat = 6
        let boxWidth = size.width - margin * 2
        let boxHeight: CGFloat = 64
        let boxY = margin

        let outer = SKShapeNode(rect: CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight), cornerRadius: 2)
        outer.fillColor = SKColor(red: 0.08, green: 0.08, blue: 0.18, alpha: 0.95)
        outer.strokeColor = SKColor(red: 0.45, green: 0.5, blue: 0.7, alpha: 1)
        outer.lineWidth = 1
        container.addChild(outer)

        let inner = SKShapeNode(rect: CGRect(x: 2, y: 2, width: boxWidth - 4, height: boxHeight - 4), cornerRadius: 1)
        inner.fillColor = .clear
        inner.strokeColor = SKColor(red: 0.3, green: 0.35, blue: 0.5, alpha: 0.6)
        inner.lineWidth = 0.5
        container.addChild(inner)

        let location = MapLocation.nearestName(to: npc.gridPos)
        let activity = npc.currentActivity.isEmpty ? "Idle" : npc.currentActivity

        let nameLabel = SKLabelNode(text: "\(npc.name)  -  \(activity), \(location)")
        nameLabel.fontSize = 6
        nameLabel.fontName = "Menlo-Bold"
        nameLabel.fontColor = SKColor(red: 1, green: 0.9, blue: 0.5, alpha: 1)
        nameLabel.horizontalAlignmentMode = .left
        nameLabel.verticalAlignmentMode = .top
        nameLabel.position = CGPoint(x: 8, y: boxHeight - 6)
        container.addChild(nameLabel)

        let bodyLabel = SKLabelNode(text: npc.dialogSummary)
        bodyLabel.fontSize = 5
        bodyLabel.fontName = "Menlo"
        bodyLabel.fontColor = .white
        bodyLabel.numberOfLines = 0
        bodyLabel.preferredMaxLayoutWidth = boxWidth - 16
        bodyLabel.horizontalAlignmentMode = .left
        bodyLabel.verticalAlignmentMode = .top
        bodyLabel.position = CGPoint(x: 8, y: boxHeight - 16)
        container.addChild(bodyLabel)

        container.position = CGPoint(x: margin, y: boxY)
        addChild(container)
        dialogNode = container
    }

    private func dismissDialog() {
        dialogNode?.removeFromParent()
        dialogNode = nil
        chatBackground = nil
        chatLines = []
        currentThinkingLabel = nil
    }

    // MARK: - Reflection

    private func checkDailyReflection() {
        if gameClock.hour >= 22 && !didReflectToday {
            didReflectToday = true
            print("\n--- End of Day \(gameClock.timeString) ---")
            for npc in npcs {
                let summary = npc.memory.reflect()
                let memories = summary.bullets
                guard !memories.isEmpty else {
                    print("[\(npc.name)] Skipping reflection — no memories today.")
                    continue
                }
                let schedule = npc.scheduleDescription
                let npcName = npc.name
                let npcRole = npc.role
                Task.detached { [weak npc] in
                    let reflection = await NPCBrain.generateReflection(
                        npcName: npcName,
                        role: npcRole,
                        schedule: schedule,
                        memories: memories
                    )
                    guard let reflection else { return }
                    let intentions = await NPCBrain.generateIntentions(
                        npcName: npcName,
                        role: npcRole,
                        reflectionText: reflection,
                        schedule: schedule
                    )
                    if let intentions {
                        await MainActor.run { [weak npc] in
                            npc?.intentions = intentions
                        }
                    }
                }
            }
            print("---\n")
        }
        if gameClock.hour < 6 && didReflectToday {
            didReflectToday = false
        }
    }

    // MARK: - Player chat (iOS)

    #if os(iOS)
    private func startPlayerChat(with npc: NPC) {
        guard !playerChatActive, !waitingForDialogue, dialogNode == nil else { return }
        playerChatActive = true
        playerChatNPC = npc
        playerChatTranscript = []
        // Capture activity context BEFORE beginPlayerChat overrides it to "Talking".
        playerChatNPCActivity = npc.currentActivity
        playerChatNPCActivityDuration = npc.activityDurationDescription(currentMinutes: gameClock.totalMinutes)
        npc.beginPlayerChat(clock: gameClock)
        openChatLog()
        installPlayerInputField()
    }

    private func endPlayerChat() {
        guard playerChatActive else { return }
        if let npc = playerChatNPC {
            npc.endChat(clock: gameClock)
        }
        playerChatActive = false
        playerChatNPC = nil
        playerChatTranscript = []
        playerChatNPCThinking = false
        removePlayerInputField()
        dismissDialog()
    }

    private func installPlayerInputField() {
        guard let view = self.view else { return }

        let field = UITextField(frame: .zero)
        field.borderStyle = .roundedRect
        field.placeholder = "Say something…"
        field.returnKeyType = .send
        field.autocapitalizationType = .sentences
        field.font = UIFont(name: "Menlo", size: 14) ?? .systemFont(ofSize: 14)
        field.backgroundColor = UIColor(white: 0.08, alpha: 0.95)
        field.textColor = .white
        field.tintColor = .white
        field.attributedPlaceholder = NSAttributedString(
            string: "Say something…",
            attributes: [.foregroundColor: UIColor(white: 0.6, alpha: 1)]
        )

        let delegate = PlayerInputDelegate { [weak self] text in
            self?.submitPlayerMessage(text: text)
        }
        field.delegate = delegate
        playerInputDelegate = delegate

        view.addSubview(field)
        playerInputField = field
        positionPlayerInputField()
        field.becomeFirstResponder()
    }

    private func removePlayerInputField() {
        playerInputField?.resignFirstResponder()
        playerInputField?.removeFromSuperview()
        playerInputField = nil
        playerInputDelegate = nil
    }

    private func positionPlayerInputField() {
        guard let view = self.view, let field = playerInputField else { return }
        let margin: CGFloat = 12
        let height: CGFloat = 36
        let width = view.bounds.width - margin * 2
        // Keep the field high enough to clear the keyboard on most devices.
        let y = view.bounds.height * 0.45
        field.frame = CGRect(x: margin, y: y, width: width, height: height)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        positionPlayerInputField()
    }

    private func submitPlayerMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !playerChatNPCThinking, let npc = playerChatNPC else { return }

        // Append the player's line, then prep the NPC's thinking line.
        prepareNextLine(speaker: "You", color: playerColor)
        commitCurrentLine(text: trimmed)
        playerChatTranscript.append("You: \"\(trimmed)\"")
        prepareNextLine(speaker: npc.name, color: npc.dialogueColor)
        playerChatNPCThinking = true

        let npcName = npc.name
        let npcRole = npc.role
        let location = MapLocation.nearestName(to: npc.gridPos)
        let timeOfDay = gameClock.timeString
        let activity = playerChatNPCActivity
        let activityDuration = playerChatNPCActivityDuration
        let observations = npc.memory.recentObservations()
        let intentions = npc.intentions
        let history = playerChatTranscript

        Task.detached { [weak self, weak npc] in
            let reply = await NPCBrain.respondToPlayer(
                npcName: npcName,
                role: npcRole,
                location: location,
                timeOfDay: timeOfDay,
                npcActivity: activity,
                npcActivityDuration: activityDuration,
                npcObservations: observations,
                npcIntentions: intentions,
                playerMessage: trimmed,
                chatHistory: history
            ) ?? "..."

            await MainActor.run { [weak self, weak npc] in
                guard let self else { return }
                self.commitCurrentLine(text: reply)
                self.playerChatTranscript.append("\(npcName): \"\(reply)\"")
                self.playerChatNPCThinking = false
                if let npc {
                    let timeStr = self.gameClock.timeString
                    npc.memory.logDialogue(speaker: "Visitor", partner: "Visitor", line: trimmed, at: timeStr)
                    npc.memory.logDialogue(speaker: npcName, partner: "Visitor", line: reply, at: timeStr)
                }
            }
        }
    }
    #endif
}

#if os(iOS)
private final class PlayerInputDelegate: NSObject, UITextFieldDelegate {
    let onSubmit: (String) -> Void

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = textField.text ?? ""
        textField.text = ""
        onSubmit(text)
        return false
    }
}
#endif
