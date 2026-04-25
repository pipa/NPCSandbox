import SpriteKit
import GameplayKit

class GameScene: SKScene {

    private let mapColumns = 20
    private let mapRows = 15
    private let tileSize: CGFloat = 16

    private var navGraph: GKGridGraph<GKGridGraphNode>!
    private var gameClock = GameClock()
    private var npcs: [NPC] = []
    private var timeLabel: SKLabelNode!
    private var lastUpdateTime: TimeInterval = 0

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
        setupHUD()
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
            tileID: CharTile.villager1,
            startPos: MapLocation.bakeryDoor,
            schedule: [
                ScheduleEntry(hour: 6, minute: 0, location: MapLocation.bakeryDoor, activity: "Baking"),
                ScheduleEntry(hour: 12, minute: 0, location: MapLocation.townSquare, activity: "Lunch"),
                ScheduleEntry(hour: 13, minute: 0, location: MapLocation.bakeryDoor, activity: "Baking"),
                ScheduleEntry(hour: 18, minute: 0, location: MapLocation.bakeryDoor, activity: "Closing"),
            ],
            sociability: 0.6,
            tileSize: tileSize,
            mapRows: mapRows
        )

        let farmer = NPC(
            name: "Gareth",
            tileID: CharTile.villager2,
            startPos: MapLocation.farmField,
            schedule: [
                ScheduleEntry(hour: 6, minute: 0, location: MapLocation.farmField, activity: "Farming"),
                ScheduleEntry(hour: 12, minute: 0, location: MapLocation.tavernDoor, activity: "Lunch"),
                ScheduleEntry(hour: 13, minute: 0, location: MapLocation.farmField, activity: "Farming"),
                ScheduleEntry(hour: 18, minute: 0, location: MapLocation.farmhouseDoor, activity: "Home"),
            ],
            sociability: 0.4,
            tileSize: tileSize,
            mapRows: mapRows
        )

        let keeper = NPC(
            name: "Mora",
            tileID: CharTile.villager3,
            startPos: MapLocation.tavernDoor,
            schedule: [
                ScheduleEntry(hour: 8, minute: 0, location: MapLocation.tavernDoor, activity: "Opening"),
                ScheduleEntry(hour: 12, minute: 0, location: MapLocation.tavernDoor, activity: "Serving"),
                ScheduleEntry(hour: 17, minute: 0, location: MapLocation.townSquare, activity: "Strolling"),
                ScheduleEntry(hour: 20, minute: 0, location: MapLocation.tavernDoor, activity: "Closing"),
            ],
            sociability: 0.8,
            tileSize: tileSize,
            mapRows: mapRows
        )

        npcs = [baker, farmer, keeper]
        for npc in npcs {
            addChild(npc.sprite)
        }
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

        // Social interrupts (symmetric — evaluate each pair once)
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
                    a.beginChat(with: b, clock: gameClock)
                    b.beginChat(with: a, clock: gameClock)
                }
            }
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

        if gameClock.advance(by: dt) {
            timeLabel.text = gameClock.timeString
        }

        for npc in npcs {
            npc.checkSchedule(clock: gameClock, navGraph: navGraph)
        }

        checkObservations()
    }
}
