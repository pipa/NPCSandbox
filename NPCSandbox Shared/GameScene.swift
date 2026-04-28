import SpriteKit
import GameplayKit
#if os(iOS)
import UIKit
#endif

@MainActor
class GameScene: SKScene {

    private let mapColumns = 30
    private let mapRows = 20
    private let tileSize: CGFloat = 16

    // Set to "TinyTown" or "TinyDungeon" to render the atlas as a numbered
    // grid instead of running the game. Used to build tile references.
    private static let debugTileSheet: String? = nil
    private static let debugTileCount = 132
    private static let debugTileColumns = 12

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
    /// Number of newest lines to skip from the bottom — 0 means newest at
    /// bottom (default). Increases when the user scrolls back through history.
    private var chatScrollOffset: Int = 0
    /// While true, new messages keep the view pinned to the bottom. Flips to
    /// false the moment the user scrolls up; flips back when they return.
    private var chatStickyToBottom: Bool = true
    /// Pixel deltas accumulate here until they exceed a per-line threshold.
    private var chatScrollAccumulator: CGFloat = 0
    private var skyOverlay: SKSpriteNode!

    private var cameraNode: SKCameraNode!
    private var player: Player?
    /// What the player has learned. Persists across loops once we add the
    /// looper — knowledge-only persistence is the puzzle's spine.
    private let journal = Journal()
    private var journalOverlay: SKNode?
    private var journalIcon: SKNode?
    private var fragmentCounter: SKLabelNode?
    private var introCardNode: SKNode?
    private var resetOverlay: SKNode?
    private var catastropheActive = false
    private var loopAttempt = 1

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
    private var chatPanGesture: UIPanGestureRecognizer?
    private var chatPanTarget: ChatPanTarget?
    #endif

    private let playerColor = SKColor(red: 1.0, green: 1.0, blue: 0.85, alpha: 1)

    private let chatBoxMargin: CGFloat = 6
    private let chatPadding: CGFloat = 6
    private let chatFontSize: CGFloat = 7
    private let chatLineSpacing: CGFloat = 2
    /// Chat panel height as a fraction of the scene height. Fixed so the
    /// panel never overruns the play area; older messages scroll out.
    private let chatPanelHeightFraction: CGFloat = 0.45
    /// Height of the input bar that sits at the bottom of the chat panel.
    private let chatInputBarHeight: CGFloat = 16
    /// Vertical gap between the input bar and the chat lines above.
    private let chatDividerGap: CGFloat = 3

    class func newGameScene() -> GameScene {
        let scene = GameScene(size: CGSize(width: 320, height: 240))
        scene.scaleMode = .aspectFit
        return scene
    }

    override func didMove(to view: SKView) {
        backgroundColor = .black
        if let atlasName = Self.debugTileSheet {
            renderAllTilesNumbered(
                atlasName: atlasName,
                tileCount: Self.debugTileCount,
                columns: Self.debugTileColumns
            )
            return
        }
        let data = buildOverlayData()
        renderTileMap(underlay: data.underlay, overlay: data.overlay)
        buildNavGraph(from: data.overlay)
        spawnNPCs()
        spawnPlayer()
        setupCamera()
        setupSkyOverlay()
        setupHUD()
        setupJournalIcon()
        for npc in npcs {
            NPCBrain.warmUp(npcName: npc.name, role: npc.role, personality: npc.personality)
        }
        showIntroCard()
    }

    private func setupCamera() {
        let cam = SKCameraNode()
        addChild(cam)
        camera = cam
        cameraNode = cam
        if let player = player {
            cam.position = clampedCameraPosition(targeting: player.sprite.position)
        } else {
            cam.position = CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }

    /// Keep the camera within the map bounds so the view never reveals the
    /// black void outside the world.
    private func clampedCameraPosition(targeting target: CGPoint) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        let mapW = CGFloat(mapColumns) * tileSize
        let mapH = CGFloat(mapRows) * tileSize
        let clampedX = max(halfW, min(mapW - halfW, target.x))
        let clampedY = max(halfH, min(mapH - halfH, target.y))
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func spawnPlayer() {
        let p = Player(
            name: "Visitor",
            tileID: CharTile.manGreen,
            startPos: MapLocation.townSquare,
            dialogueColor: playerColor,
            tileSize: tileSize,
            mapRows: mapRows
        )
        addChild(p.sprite)
        player = p
    }

    // MARK: - Debug: numbered atlas grid

    private func renderAllTilesNumbered(atlasName: String, tileCount: Int, columns: Int) {
        let atlas = SKTextureAtlas(named: atlasName)
        let originX = tileSize / 2
        let originY = size.height - tileSize / 2

        for id in 0..<tileCount {
            let col = id % columns
            let row = id / columns
            let pos = CGPoint(
                x: originX + CGFloat(col) * tileSize,
                y: originY - CGFloat(row) * tileSize
            )
            let texName = String(format: "tile_%04d", id)
            let tex = atlas.textureNamed(texName)
            tex.filteringMode = .nearest
            let sprite = SKSpriteNode(texture: tex)
            sprite.position = pos
            addChild(sprite)

            let label = SKLabelNode(text: "\(id)")
            label.fontName = "Menlo"
            label.fontSize = 5
            label.fontColor = .white
            label.verticalAlignmentMode = .bottom
            label.position = CGPoint(x: pos.x, y: pos.y - tileSize / 2 + 1)
            label.zPosition = 10
            addChild(label)
        }
    }

    // MARK: - Tile Map

    private func renderTileMap(underlay: [[Int]], overlay: [[Int]]) {
        let townAtlas = SKTextureAtlas(named: "TinyTown")
        let dungeonAtlas = SKTextureAtlas(named: "TinyDungeon")
        var textureCache: [Int: SKTexture] = [:]

        func texture(for id: Int) -> SKTexture {
            if let cached = textureCache[id] { return cached }
            let tex: SKTexture
            if id >= 1000 {
                tex = dungeonAtlas.textureNamed(String(format: "tile_%04d", id - 1000))
            } else {
                tex = townAtlas.textureNamed(String(format: "tile_%04d", id))
            }
            tex.filteringMode = .nearest
            textureCache[id] = tex
            return tex
        }

        let grassTexture = texture(for: TownTile.grass)

        for row in 0..<mapRows {
            for col in 0..<mapColumns {
                let pos = tilePosition(col: col, row: row)

                let grassSprite = SKSpriteNode(texture: grassTexture)
                grassSprite.position = pos
                addChild(grassSprite)

                let underID = underlay[row][col]
                if underID >= 0 {
                    let sprite = SKSpriteNode(texture: texture(for: underID))
                    sprite.position = pos
                    sprite.zPosition = 0.5
                    addChild(sprite)
                }

                let overID = overlay[row][col]
                if overID >= 0 {
                    let sprite = SKSpriteNode(texture: texture(for: overID))
                    sprite.position = pos
                    sprite.zPosition = 1
                    addChild(sprite)
                }
            }
        }
    }

    private func buildOverlayData() -> (underlay: [[Int]], overlay: [[Int]]) {
        let P = TownTile.path
        let T = TownTile.treePine
        let G = TownTile.treeGreen
        let W = TownTile.wheat

        var overlay = Array(repeating: Array(repeating: -1, count: mapColumns), count: mapRows)
        var underlay = Array(repeating: Array(repeating: -1, count: mapColumns), count: mapRows)

        // Forest border (top + bottom rows, plus a few side anchors)
        let treePositions: [(Int, Int, Int)] = [
            (0,0,T), (0,1,G), (0,2,T), (0,3,G), (0,16,T), (0,17,G), (0,18,T), (0,19,G),
            (1,0,G), (1,19,T),
            (13,0,T), (13,19,G),
            (14,0,G), (14,1,T), (14,2,G), (14,3,T),
            (14,16,G), (14,17,T), (14,18,G), (14,19,T),
        ]
        for (r, c, tile) in treePositions {
            overlay[r][c] = tile
        }

        // Main street (vertical, col 9, rows 1-12)
        for row in 1...12 {
            overlay[row][9] = P
        }

        // Cross street (horizontal, row 7, cols 2-18 — extends to the keep)
        for col in 2...18 {
            overlay[7][col] = P
        }

        // Town plaza — 3x3 dirt around the well at the crossroads
        for row in 6...8 {
            for col in 8...10 {
                overlay[row][col] = P
            }
        }

        // Bakery — blue house, NW
        placeBuilding(TownTile.blueHouse, in: &overlay, atRow: 2, col: 3)
        overlay[4][7] = P
        overlay[4][8] = P

        // Tavern — red house, NE
        placeBuilding(TownTile.redHouse, in: &overlay, atRow: 2, col: 12)
        overlay[4][10] = P
        overlay[4][11] = P

        // Farmhouse — blue house, SW
        placeBuilding(TownTile.blueHouse, in: &overlay, atRow: 9, col: 3)
        overlay[11][7] = P
        overlay[11][8] = P

        // The Old Keep — 6 wide × 5 tall, east edge (rows 8-12, cols 13-18)
        placeBuilding(TownTile.castle, in: &overlay, atRow: 8, col: 13)
        // Dirt floor under the keep's bottom row so the gate's transparent
        // tiles (123/124) reveal the floor instead of grass.
        for col in 13...18 {
            underlay[12][col] = TownTile.pathBotMid
        }

        // Wheat field — south, in front of the farmhouse
        for row in 12...13 {
            for col in 4...10 {
                overlay[row][col] = W
            }
        }

        // Town square decorations — two-tile well (top + bottom) centered
        // in the plaza, signpost at the NW corner.
        overlay[6][9] = TownTile.wellTop
        overlay[7][9] = TownTile.well
        overlay[6][8] = TownTile.sign

        // Beehive by the farmhouse, archery target out in the south field
        overlay[12][2] = TownTile.beehive
        overlay[13][12] = TownTile.target

        return (underlay: underlay, overlay: overlay)
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
        npcs = Roster.all.map { sheet in
            NPC(sheet: sheet, tileSize: tileSize, mapRows: mapRows)
        }
        for npc in npcs {
            addChild(npc.sprite)
        }
    }

    // MARK: - Sky overlay

    private func setupSkyOverlay() {
        skyOverlay = SKSpriteNode(color: .black, size: size)
        skyOverlay.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        skyOverlay.position = .zero
        skyOverlay.zPosition = 50
        skyOverlay.alpha = 0
        cameraNode.addChild(skyOverlay)
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
        // Camera-relative coords: top-left of the visible view.
        timeLabel.position = CGPoint(x: -size.width / 2 + 4, y: size.height / 2 - 4)
        timeLabel.zPosition = 100
        cameraNode.addChild(timeLabel)
    }

    // MARK: - Journal UI

    private func setupJournalIcon() {
        let icon = SKShapeNode(rectOf: CGSize(width: 14, height: 14), cornerRadius: 1)
        icon.fillColor = SKColor(red: 0.55, green: 0.4, blue: 0.25, alpha: 1)
        icon.strokeColor = SKColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        icon.lineWidth = 0.6
        icon.name = "journalIcon"
        // Top-right of the camera view.
        icon.position = CGPoint(x: size.width / 2 - 11, y: size.height / 2 - 11)
        icon.zPosition = 250

        let label = SKLabelNode(text: "J")
        label.fontName = "Menlo-Bold"
        label.fontSize = 8
        label.fontColor = SKColor(red: 1, green: 0.95, blue: 0.8, alpha: 1)
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.name = "journalIconText"
        icon.addChild(label)

        // Counter sitting just left of the journal icon — shows N/4 known
        // fragments. Goes gold when full.
        let counter = SKLabelNode(text: "0/4")
        counter.fontName = "Menlo-Bold"
        counter.fontSize = 6
        counter.fontColor = SKColor(white: 0.9, alpha: 1)
        counter.verticalAlignmentMode = .center
        counter.horizontalAlignmentMode = .right
        counter.position = CGPoint(x: -10, y: 0)
        counter.zPosition = 1
        icon.addChild(counter)
        fragmentCounter = counter

        cameraNode.addChild(icon)
        journalIcon = icon
    }

    private func updateFragmentCounter() {
        guard let counter = fragmentCounter else { return }
        let count = journal.entries.count
        counter.text = "\(count)/4"
        counter.fontColor = (count >= 4)
            ? SKColor(red: 1, green: 0.85, blue: 0.4, alpha: 1)
            : SKColor(white: 0.9, alpha: 1)
    }

    private func toggleJournal() {
        if journalOverlay != nil {
            closeJournal()
        } else {
            openJournal()
        }
    }

    private func openJournal() {
        guard journalOverlay == nil else { return }

        let overlay = SKNode()
        overlay.zPosition = 300
        overlay.name = "journalOverlay"

        // Translucent backdrop covering the visible view.
        let backdrop = SKShapeNode(rectOf: size)
        backdrop.fillColor = SKColor(white: 0, alpha: 0.65)
        backdrop.strokeColor = .clear
        backdrop.zPosition = 0
        overlay.addChild(backdrop)

        // Centered panel.
        let panelW: CGFloat = size.width * 0.72
        let panelH: CGFloat = size.height * 0.78
        let panel = SKShapeNode(
            rect: CGRect(x: -panelW / 2, y: -panelH / 2, width: panelW, height: panelH),
            cornerRadius: 3
        )
        panel.fillColor = SKColor(red: 0.09, green: 0.07, blue: 0.16, alpha: 0.97)
        panel.strokeColor = SKColor(red: 0.55, green: 0.4, blue: 0.25, alpha: 1)
        panel.lineWidth = 1
        panel.zPosition = 1
        overlay.addChild(panel)

        let header = SKLabelNode(text: "Journal — Day \(currentDay)")
        header.fontName = "Menlo-Bold"
        header.fontSize = 9
        header.fontColor = SKColor(red: 1, green: 0.85, blue: 0.5, alpha: 1)
        header.verticalAlignmentMode = .top
        header.horizontalAlignmentMode = .center
        header.position = CGPoint(x: 0, y: panelH / 2 - 8)
        header.zPosition = 2
        overlay.addChild(header)

        if journal.entries.isEmpty {
            let empty = SKLabelNode(text: "Nothing learned yet.")
            empty.fontName = "Menlo"
            empty.fontSize = 6
            empty.fontColor = SKColor(white: 0.55, alpha: 1)
            empty.verticalAlignmentMode = .center
            empty.horizontalAlignmentMode = .center
            empty.position = .zero
            empty.zPosition = 2
            overlay.addChild(empty)
        } else {
            var y = panelH / 2 - 24
            for entry in journal.entries {
                let line = SKLabelNode(text: entry.summary)
                line.fontName = "Menlo"
                line.fontSize = 6
                line.fontColor = .white
                line.numberOfLines = 0
                line.preferredMaxLayoutWidth = panelW - 16
                line.horizontalAlignmentMode = .left
                line.verticalAlignmentMode = .top
                line.position = CGPoint(x: -panelW / 2 + 8, y: y)
                line.zPosition = 2
                overlay.addChild(line)
                y -= max(line.frame.height, 8) + 4
            }
        }

        let footer = SKLabelNode(text: "Tap or press J to close")
        footer.fontName = "Menlo"
        footer.fontSize = 5
        footer.fontColor = SKColor(white: 0.5, alpha: 1)
        footer.verticalAlignmentMode = .bottom
        footer.horizontalAlignmentMode = .center
        footer.position = CGPoint(x: 0, y: -panelH / 2 + 5)
        footer.zPosition = 2
        overlay.addChild(footer)

        cameraNode.addChild(overlay)
        journalOverlay = overlay
    }

    private func closeJournal() {
        journalOverlay?.removeFromParent()
        journalOverlay = nil
    }

    // MARK: - Reset shrine

    /// Tap the well's tile to bring up a confirmation panel; tapping inside
    /// the panel rewinds to Day 1, tapping anywhere else cancels.
    private func showResetConfirmation() {
        guard resetOverlay == nil else { return }

        let overlay = SKNode()
        overlay.zPosition = 350
        overlay.name = "resetOverlay"

        let backdrop = SKShapeNode(rectOf: size)
        backdrop.fillColor = SKColor(white: 0, alpha: 0.5)
        backdrop.strokeColor = .clear
        overlay.addChild(backdrop)

        let panelW: CGFloat = size.width * 0.62
        let panelH: CGFloat = 52
        let panel = SKShapeNode(
            rect: CGRect(x: -panelW / 2, y: -panelH / 2, width: panelW, height: panelH),
            cornerRadius: 3
        )
        panel.fillColor = SKColor(red: 0.09, green: 0.07, blue: 0.16, alpha: 0.97)
        panel.strokeColor = SKColor(red: 0.55, green: 0.4, blue: 0.25, alpha: 1)
        panel.lineWidth = 1
        panel.name = "resetPanel"
        overlay.addChild(panel)

        let title = SKLabelNode(text: "Rewind the day?")
        title.fontName = "Menlo-Bold"
        title.fontSize = 8
        title.fontColor = SKColor(red: 1, green: 0.85, blue: 0.5, alpha: 1)
        title.verticalAlignmentMode = .center
        title.horizontalAlignmentMode = .center
        title.position = CGPoint(x: 0, y: 9)
        overlay.addChild(title)

        let body = SKLabelNode(text: "Tap here to confirm — knowledge stays.")
        body.fontName = "Menlo"
        body.fontSize = 5
        body.fontColor = SKColor(white: 0.7, alpha: 1)
        body.verticalAlignmentMode = .center
        body.horizontalAlignmentMode = .center
        body.position = CGPoint(x: 0, y: -3)
        overlay.addChild(body)

        let footer = SKLabelNode(text: "Tap outside to cancel.")
        footer.fontName = "Menlo"
        footer.fontSize = 5
        footer.fontColor = SKColor(white: 0.45, alpha: 1)
        footer.verticalAlignmentMode = .center
        footer.horizontalAlignmentMode = .center
        footer.position = CGPoint(x: 0, y: -14)
        overlay.addChild(footer)

        cameraNode.addChild(overlay)
        resetOverlay = overlay
    }

    private func dismissResetConfirmation() {
        resetOverlay?.removeFromParent()
        resetOverlay = nil
    }

    // MARK: - Intro card + speech bubbles

    /// Day-1 cold-open: black card with arrival text. Tap or wait to
    /// dismiss; after dismissal the Stranger speaks his cryptic line.
    private func showIntroCard() {
        let card = SKNode()
        card.zPosition = 400
        card.name = "introCard"

        let bg = SKShapeNode(rectOf: size)
        bg.fillColor = .black
        bg.strokeColor = .clear
        bg.zPosition = 0
        card.addChild(bg)

        let title = SKLabelNode(text: "Day 1")
        title.fontName = "Menlo-Bold"
        title.fontSize = 14
        title.fontColor = SKColor(red: 1, green: 0.9, blue: 0.6, alpha: 1)
        title.verticalAlignmentMode = .center
        title.horizontalAlignmentMode = .center
        title.position = CGPoint(x: 0, y: 30)
        title.zPosition = 1
        card.addChild(title)

        let body = SKLabelNode(text: "You arrived in the village last night.\nThe old man at the gate said something\nabout the stars.")
        body.fontName = "Menlo"
        body.fontSize = 7
        body.fontColor = SKColor(white: 0.88, alpha: 1)
        body.numberOfLines = 0
        body.preferredMaxLayoutWidth = size.width * 0.7
        body.verticalAlignmentMode = .center
        body.horizontalAlignmentMode = .center
        body.position = .zero
        body.zPosition = 1
        card.addChild(body)

        let footer = SKLabelNode(text: "tap to continue")
        footer.fontName = "Menlo"
        footer.fontSize = 5
        footer.fontColor = SKColor(white: 0.45, alpha: 1)
        footer.verticalAlignmentMode = .bottom
        footer.position = CGPoint(x: 0, y: -size.height / 2 + 8)
        footer.zPosition = 1
        card.addChild(footer)

        cameraNode.addChild(card)
        introCardNode = card

        // Auto-dismiss after a few seconds if the player doesn't tap.
        card.run(SKAction.sequence([
            SKAction.wait(forDuration: 5.0),
            SKAction.run { [weak self] in self?.dismissIntroCard() },
        ]))
    }

    private func dismissIntroCard() {
        guard let card = introCardNode else { return }
        introCardNode = nil
        card.removeAllActions()
        card.run(SKAction.sequence([
            SKAction.fadeOut(withDuration: 0.6),
            SKAction.removeFromParent(),
            SKAction.run { [weak self] in self?.showStrangerWelcome() },
        ]))
    }

    private func showStrangerWelcome() {
        guard let stranger = npcs.first(where: { $0.name == "the Stranger" }) else { return }
        showSpeechBubble(
            over: stranger,
            text: "Listen tonight when the sky goes red. Then come find me.",
            duration: 9.0
        )
    }

    /// Generic speech bubble that floats above an NPC for a fixed duration
    /// then fades. Reusable for sunset omens, Stranger callouts, etc.
    private func showSpeechBubble(over npc: NPC, text: String, duration: TimeInterval) {
        let bubble = SKNode()
        bubble.zPosition = 70

        let textLabel = SKLabelNode(text: text)
        textLabel.fontName = "Menlo"
        textLabel.fontSize = 5
        textLabel.fontColor = SKColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        textLabel.numberOfLines = 0
        textLabel.preferredMaxLayoutWidth = 90
        textLabel.verticalAlignmentMode = .center
        textLabel.horizontalAlignmentMode = .center

        let textW = max(textLabel.frame.width + 8, 30)
        let textH = max(textLabel.frame.height + 6, 12)

        let bg = SKShapeNode(
            rect: CGRect(x: -textW / 2, y: -textH / 2, width: textW, height: textH),
            cornerRadius: 2
        )
        bg.fillColor = SKColor(red: 1, green: 1, blue: 0.96, alpha: 0.95)
        bg.strokeColor = SKColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        bg.lineWidth = 0.5
        bg.zPosition = 0

        let tail = SKShapeNode()
        let tailPath = CGMutablePath()
        tailPath.move(to: CGPoint(x: -2, y: -textH / 2))
        tailPath.addLine(to: CGPoint(x: 2, y: -textH / 2))
        tailPath.addLine(to: CGPoint(x: 0, y: -textH / 2 - 2.5))
        tailPath.closeSubpath()
        tail.path = tailPath
        tail.fillColor = bg.fillColor
        tail.strokeColor = bg.strokeColor
        tail.lineWidth = 0.5
        tail.zPosition = -1

        bubble.addChild(bg)
        bubble.addChild(tail)
        bubble.addChild(textLabel)

        // Anchor the bubble above the NPC's head; reposition each frame so
        // it tracks the NPC if they move during the bubble's lifetime.
        let follow = SKAction.customAction(withDuration: duration) { [weak npc] node, _ in
            guard let npc else { return }
            node.position = CGPoint(
                x: npc.sprite.position.x,
                y: npc.sprite.position.y + 16
            )
        }
        bubble.run(follow)
        addChild(bubble)

        bubble.run(SKAction.sequence([
            SKAction.wait(forDuration: duration),
            SKAction.fadeOut(withDuration: 0.5),
            SKAction.removeFromParent(),
        ]))
    }

    // MARK: - Catastrophe + loop reset

    private func triggerCatastrophe() {
        catastropheActive = true
        print("[Catastrophe] Sunset reached — the seal breaks.")

        // Sky reddens.
        skyOverlay.run(SKAction.group([
            SKAction.colorize(
                with: SKColor(red: 0.45, green: 0.05, blue: 0.05, alpha: 1),
                colorBlendFactor: 1.0,
                duration: 1.5
            ),
            SKAction.fadeAlpha(to: 0.6, duration: 1.5),
        ]))

        // Sequence: monsters emerge from the keep arch, then screen fades
        // to black, then reset.
        let spawnMonsters = SKAction.run { [weak self] in
            self?.spawnCatastropheMonsters()
        }
        let blackOut = SKAction.run { [weak self] in
            guard let self else { return }
            self.skyOverlay.run(SKAction.group([
                SKAction.colorize(with: .black, colorBlendFactor: 1.0, duration: 1.2),
                SKAction.fadeAlpha(to: 1.0, duration: 1.2),
            ]))
        }
        let reset = SKAction.run { [weak self] in
            self?.performLoopReset()
        }

        run(SKAction.sequence([
            SKAction.wait(forDuration: 1.0),
            spawnMonsters,
            SKAction.wait(forDuration: 4.0),
            blackOut,
            SKAction.wait(forDuration: 1.8),
            reset,
        ]))
    }

    private func spawnCatastropheMonsters() {
        let monsterTiles = [
            CharTile.ghostGreen,
            CharTile.cyclops,
            CharTile.crab,
            CharTile.bat,
            CharTile.ghostWhite,
            CharTile.spider,
        ]
        let atlas = SKTextureAtlas(named: "TinyDungeon")
        // Spawn at the keep arch (row 12, col 15) and stream south-west into
        // the village.
        let archPosition = tilePosition(col: 15, row: 12)

        for i in 0..<8 {
            let tileID = monsterTiles.randomElement() ?? CharTile.ghostGreen
            let tex = atlas.textureNamed(String(format: "tile_%04d", tileID))
            tex.filteringMode = .nearest

            let sprite = SKSpriteNode(texture: tex)
            sprite.position = archPosition
            sprite.zPosition = 12
            sprite.alpha = 0
            addChild(sprite)

            // Spread-out target somewhere in the village.
            let target = CGPoint(
                x: CGFloat.random(in: 80...260),
                y: CGFloat.random(in: 60...160)
            )

            sprite.run(SKAction.sequence([
                SKAction.wait(forDuration: Double(i) * 0.25),
                SKAction.fadeAlpha(to: 1.0, duration: 0.3),
                SKAction.move(to: target, duration: 2.8),
                SKAction.fadeOut(withDuration: 0.4),
                SKAction.removeFromParent(),
            ]))
        }
    }

    private func performLoopReset() {
        loopAttempt += 1
        print("[Loop] Resetting → attempt \(loopAttempt)")

        // Tear down any in-flight chats / dialogs / overlays.
        dismissDialog()
        waitingForDialogue = false
        closeJournal()
        #if os(iOS)
        if playerChatActive { endPlayerChat() }
        #endif

        // Drop NPCs.
        for npc in npcs { npc.sprite.removeFromParent() }
        npcs = []

        // Wipe LLM session memory so NPCs don't reference the prior loop.
        Task.detached {
            for sheet in Roster.all {
                await NPCBrain.invalidate(npcName: sheet.name)
            }
        }

        // Reset world clock + day.
        gameClock = GameClock()
        currentDay = 1
        didReflectToday = false

        // Respawn cast.
        spawnNPCs()
        for npc in npcs {
            NPCBrain.warmUp(npcName: npc.name, role: npc.role, personality: npc.personality)
        }

        // Drop the player back at the well.
        player?.teleport(to: MapLocation.townSquare)

        // Snap the camera so it doesn't lerp from wherever it was.
        if let player = player {
            cameraNode.position = clampedCameraPosition(targeting: player.sprite.position)
        }

        // Restore daytime sky and show the loop title card. Refresh the
        // fragment counter — its value is unchanged, but the icon may have
        // been hidden during the catastrophe fade.
        updateSkyOverlay()
        updateFragmentCounter()
        showLoopTitleCard()

        catastropheActive = false
    }

    private func showLoopTitleCard() {
        let card = SKNode()
        card.zPosition = 400
        card.name = "loopTitleCard"

        let bg = SKShapeNode(rectOf: size)
        bg.fillColor = .black
        bg.strokeColor = .clear
        card.addChild(bg)

        let title = SKLabelNode(text: "Day 1")
        title.fontName = "Menlo-Bold"
        title.fontSize = 14
        title.fontColor = SKColor(red: 1, green: 0.9, blue: 0.6, alpha: 1)
        title.verticalAlignmentMode = .center
        title.horizontalAlignmentMode = .center
        title.position = CGPoint(x: 0, y: 6)
        card.addChild(title)

        let attempt = SKLabelNode(text: "Attempt \(loopAttempt)")
        attempt.fontName = "Menlo"
        attempt.fontSize = 6
        attempt.fontColor = SKColor(white: 0.7, alpha: 1)
        attempt.verticalAlignmentMode = .top
        attempt.horizontalAlignmentMode = .center
        attempt.position = CGPoint(x: 0, y: -3)
        card.addChild(attempt)

        cameraNode.addChild(card)

        card.run(SKAction.sequence([
            SKAction.wait(forDuration: 1.5),
            SKAction.fadeOut(withDuration: 0.6),
            SKAction.removeFromParent(),
        ]))
    }

    // MARK: - Victory

    private func triggerVictory() {
        catastropheActive = true   // reuse the flag to freeze the world
        print("[Victory] All four fragments — the seal holds.")

        // Sky clears to a soft golden glow rather than blood-red.
        skyOverlay.removeAllActions()
        skyOverlay.run(SKAction.group([
            SKAction.colorize(
                with: SKColor(red: 1, green: 0.85, blue: 0.55, alpha: 1),
                colorBlendFactor: 1.0,
                duration: 2.5
            ),
            SKAction.fadeAlpha(to: 0.35, duration: 2.5),
        ]))

        run(SKAction.sequence([
            SKAction.wait(forDuration: 3.0),
            SKAction.run { [weak self] in self?.showVictoryCard() },
        ]))
    }

    private func showVictoryCard() {
        let card = SKNode()
        card.zPosition = 400
        card.name = "victoryCard"

        let bg = SKShapeNode(rectOf: size)
        bg.fillColor = SKColor(red: 0.05, green: 0.04, blue: 0.1, alpha: 0.97)
        bg.strokeColor = .clear
        card.addChild(bg)

        let title = SKLabelNode(text: "The seal holds.")
        title.fontName = "Menlo-Bold"
        title.fontSize = 12
        title.fontColor = SKColor(red: 1, green: 0.92, blue: 0.7, alpha: 1)
        title.verticalAlignmentMode = .center
        title.horizontalAlignmentMode = .center
        title.position = CGPoint(x: 0, y: 18)
        card.addChild(title)

        let body = SKLabelNode(text: "The night passes quietly.\nThe village does not know it was saved.")
        body.fontName = "Menlo"
        body.fontSize = 6
        body.fontColor = SKColor(white: 0.88, alpha: 1)
        body.numberOfLines = 0
        body.preferredMaxLayoutWidth = size.width * 0.7
        body.verticalAlignmentMode = .center
        body.horizontalAlignmentMode = .center
        body.position = CGPoint(x: 0, y: -4)
        card.addChild(body)

        let footer = SKLabelNode(text: "Attempt \(loopAttempt) — you carried what was forgotten")
        footer.fontName = "Menlo"
        footer.fontSize = 5
        footer.fontColor = SKColor(white: 0.55, alpha: 1)
        footer.verticalAlignmentMode = .bottom
        footer.horizontalAlignmentMode = .center
        footer.position = CGPoint(x: 0, y: -size.height / 2 + 10)
        card.addChild(footer)

        cameraNode.addChild(card)
        card.alpha = 0
        card.run(SKAction.fadeIn(withDuration: 1.0))
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
        if Self.debugTileSheet != nil { return }

        let dt: TimeInterval
        if lastUpdateTime == 0 {
            dt = 0
        } else {
            dt = currentTime - lastUpdateTime
        }
        lastUpdateTime = currentTime

        // Camera follows the player every frame, even while the world is
        // paused — keeps the view centered on the avatar after a chat ends.
        if let player = player, let cam = cameraNode {
            let target = clampedCameraPosition(targeting: player.sprite.position)
            let lerp: CGFloat = 0.15
            cam.position.x += (target.x - cam.position.x) * lerp
            cam.position.y += (target.y - cam.position.y) * lerp

            // Surface NPC name labels only when the player is within earshot
            // (~2 tiles, Manhattan). Chat bubbles update independently in NPC.
            for npc in npcs {
                let dist = abs(npc.gridPos.col - player.gridPos.col)
                    + abs(npc.gridPos.row - player.gridPos.row)
                npc.setLabelVisible(dist <= 2)
            }
        }

        let isNight = gameClock.hour >= 22 || gameClock.hour < 6
        // Day at 2 game-min/sec gives ~6 real-min from 06:00 to 18:00 —
        // long enough to walk, talk to a couple of NPCs, and reach sunset.
        // Night speeds back up so reflection lands quickly.
        gameClock.minutesPerSecond = isNight ? 20.0 : 2.0

        // While the catastrophe sequence plays, freeze world updates — it's
        // a cutscene the player watches.
        if catastropheActive { return }

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
            npc.tickNeeds(currentMinute: gameClock.totalMinutes)
            npc.checkSchedule(clock: gameClock, navGraph: navGraph)
            npc.considerWander(clock: gameClock, navGraph: navGraph)
        }

        // Sunset on Day 1 — if the player has gathered all four fragments,
        // the ritual succeeds. Otherwise the seal breaks.
        if gameClock.day == 1 && gameClock.hour >= 18 && !catastropheActive {
            if journal.allFour {
                triggerVictory()
            } else {
                triggerCatastrophe()
            }
            return
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
        // Catastrophe is a cutscene — ignore taps while it plays.
        if catastropheActive { return }

        // Intro card swallows the first tap and dismisses early.
        if introCardNode != nil {
            dismissIntroCard()
            return
        }

        // Reset confirmation: tap inside the panel = confirm rewind, tap
        // anywhere else = cancel.
        if resetOverlay != nil {
            let hits = nodes(at: point)
            if hits.contains(where: { $0.name == "resetPanel" }) {
                dismissResetConfirmation()
                performLoopReset()
            } else {
                dismissResetConfirmation()
            }
            return
        }

        // Journal icon: top-right of the camera view. Hit-test first so it
        // works whether or not other overlays are open.
        if let icon = journalIcon {
            let iconLocal = icon.parent?.convert(icon.position, to: self) ?? icon.position
            if abs(point.x - iconLocal.x) <= 8 && abs(point.y - iconLocal.y) <= 8 {
                toggleJournal()
                return
            }
        }

        // Journal open: tap anywhere else closes it.
        if journalOverlay != nil {
            closeJournal()
            return
        }

        // Player-chat: tap outside the chat bubble closes the chat. Taps
        // inside it (or on the text field, which intercepts at the view
        // layer) are ignored here.
        if playerChatActive {
            if !chatBoxContains(point) {
                endPlayerChat()
            }
            return
        }

        // Inspect popup (legacy macOS path) — tap anywhere dismisses it.
        // Live NPC-NPC chats (waitingForDialogue = true) stay open until the
        // chat ends naturally; taps fall through to walking/etc.
        if dialogNode != nil, !waitingForDialogue {
            dismissDialog()
            return
        }

        // Well shrine: tapping the well's two tiles brings up the rewind
        // prompt. Checked before the NPC loop because the well sits on
        // walkable plaza and an NPC nearby could absorb the tap otherwise.
        let tapTile = gridPosition(forScenePoint: point)
        if tapTile.col == 9 && (tapTile.row == 6 || tapTile.row == 7) {
            showResetConfirmation()
            return
        }

        for npc in npcs {
            let dist = hypot(npc.sprite.position.x - point.x, npc.sprite.position.y - point.y)
            if dist < tileSize * 1.2 {
                if npc.isChatting {
                    // Tap on a chatting NPC reveals the live transcript.
                    showChatLog()
                    return
                }

                #if os(iOS)
                startPlayerChat(with: npc)
                #else
                showNPCDialog(for: npc)
                #endif
                return
            }
        }

        // Empty-space tap: hide the chat log if it's visible (the player
        // is "looking away"), then walk the avatar to the tapped tile.
        if waitingForDialogue {
            hideChatLog()
        }
        guard let player = player else { return }
        let target = gridPosition(forScenePoint: point)
        if let walkable = nearestWalkable(to: target) {
            player.walkTo(walkable, navGraph: navGraph)
        }
    }

    private func gridPosition(forScenePoint point: CGPoint) -> GridPosition {
        let col = Int(point.x / tileSize)
        let rowFromBottom = Int(point.y / tileSize)
        let row = mapRows - 1 - rowFromBottom
        return GridPosition(
            col: max(0, min(mapColumns - 1, col)),
            row: max(0, min(mapRows - 1, row))
        )
    }

    private func nearestWalkable(to target: GridPosition) -> GridPosition? {
        if navGraph.node(atGridPosition: vector_int2(Int32(target.col), Int32(target.row))) != nil {
            return target
        }
        // BFS outward from the tapped tile until we find a walkable cell.
        var queue: [GridPosition] = [target]
        var visited: Set<Int> = [target.col * 10_000 + target.row]
        while !queue.isEmpty {
            let pos = queue.removeFirst()
            for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let c = pos.col + dc
                let r = pos.row + dr
                if c < 0 || c >= mapColumns || r < 0 || r >= mapRows { continue }
                let key = c * 10_000 + r
                if visited.contains(key) { continue }
                visited.insert(key)
                if navGraph.node(atGridPosition: vector_int2(Int32(c), Int32(r))) != nil {
                    return GridPosition(col: c, row: r)
                }
                queue.append(GridPosition(col: c, row: r))
            }
        }
        return nil
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
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        handleTap(at: event.location(in: self))
    }

    override func keyDown(with event: NSEvent) {
        // 'J' (without modifiers) toggles the journal overlay. Other keys
        // fall through to default handling.
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "j" {
            toggleJournal()
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard dialogNode != nil else { super.scrollWheel(with: event); return }
        // macOS: positive deltaY = scrolling content downward (revealing
        // content above). In our chat that means showing OLDER lines, so
        // we increase the offset.
        chatScrollAccumulator += event.scrollingDeltaY
        let threshold: CGFloat = 12
        while chatScrollAccumulator >= threshold {
            scrollChatBy(lines: 1)
            chatScrollAccumulator -= threshold
        }
        while chatScrollAccumulator <= -threshold {
            scrollChatBy(lines: -1)
            chatScrollAccumulator += threshold
        }
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
            let personality: String
            let mood: String
            let activity: String
            let activityDuration: String
            let observations: [String]
            let intentions: [String]
        }
        let contexts = participants.map { npc in
            ParticipantContext(
                name: npc.name,
                role: npc.role,
                personality: npc.personality,
                mood: npc.currentMood,
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
        // Capture this chat's dialog container — UI updates only run if it's
        // still the active one (i.e. the player or another chat hasn't
        // replaced it). Comparing identities prevents stale tasks from
        // dismissing dialogs they don't own.
        let myDialog = dialogNode

        Task.detached { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.dialogNode === myDialog {
                        self.dismissDialog()
                        self.waitingForDialogue = false
                    }
                    for npc in participantsRef {
                        npc.endChat(clock: self.gameClock)
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
                    speakerPersonality: opener.personality,
                    speakerMood: opener.mood,
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
                    guard let self, self.dialogNode === myDialog else { return }
                    self.commitCurrentLine(text: openingLine)
                    if turnCount > 1 {
                        let nextIdx = 1 % contexts.count
                        self.prepareNextLine(speaker: contexts[nextIdx].name, color: participantsRef[nextIdx].dialogueColor)
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
                        responderPersonality: current.personality,
                        responderMood: current.mood,
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
                        guard let self, self.dialogNode === myDialog else { return }
                        self.commitCurrentLine(text: line)
                        if !isFinal {
                            let nextIdx = (turnIndex + 1) % contexts.count
                            self.prepareNextLine(speaker: contexts[nextIdx].name, color: participantsRef[nextIdx].dialogueColor)
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
        let speakerPersonality = speaker.personality
        let speakerMood = speaker.currentMood
        let speakerColor = speaker.dialogueColor
        let listenerName = listener.name
        let listenerRole = listener.role
        let listenerPersonality = listener.personality
        let listenerMood = listener.currentMood
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
        let myDialog = dialogNode

        Task.detached { [weak self, weak speaker, weak listener] in
            defer {
                Task { @MainActor [weak self, weak speaker, weak listener] in
                    guard let self else { return }
                    if self.dialogNode === myDialog {
                        self.dismissDialog()
                        self.waitingForDialogue = false
                    }
                    speaker?.endChat(clock: self.gameClock)
                    listener?.endChat(clock: self.gameClock)
                }
            }

            do {
                // Turn 1 — speaker opens.
                let openingLine = await NPCBrain.generateDialogue(
                    speaker: speakerName,
                    speakerRole: speakerRole,
                    speakerPersonality: speakerPersonality,
                    speakerMood: speakerMood,
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
                ) ?? "..."

                var transcript: [(speaker: String, line: String)] = [(speakerName, openingLine)]

                await MainActor.run { [weak self] in
                    guard let self, self.dialogNode === myDialog else { return }
                    self.commitCurrentLine(text: openingLine)
                    if turnCount > 1 {
                        self.prepareNextLine(speaker: listenerName, color: listenerColor)
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
                    let responderPersonality = responderIsListener ? listenerPersonality : speakerPersonality
                    let responderMood = responderIsListener ? listenerMood : speakerMood
                    let nextResponderName = responderIsListener ? speakerName : listenerName
                    let nextResponderColor = responderIsListener ? speakerColor : listenerColor
                    let isFinal = (turnIndex == turnCount - 1)

                    let inSessionHistory = transcript.map { "\($0.speaker): \"\($0.line)\"" }
                    let prevLine = transcript.last!.line

                    let line = await NPCBrain.generateResponse(
                        responder: responderName,
                        responderRole: responderRole,
                        responderPersonality: responderPersonality,
                        responderMood: responderMood,
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
                        guard let self, self.dialogNode === myDialog else { return }
                        self.commitCurrentLine(text: line)
                        if !isFinal {
                            self.prepareNextLine(speaker: nextResponderName, color: nextResponderColor)
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
                        npcName: speakerName, role: speakerRole, personality: speakerPersonality,
                        partner: listenerName, transcript: transcriptStrings
                    )
                    async let listenerRating = NPCBrain.rateExchange(
                        npcName: listenerName, role: listenerRole, personality: listenerPersonality,
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
        container.alpha = 0

        let boxWidth = size.width - chatBoxMargin * 2
        let boxHeight = size.height * chatPanelHeightFraction

        let bg = SKShapeNode(rect: CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight),
                             cornerRadius: 2)
        bg.fillColor = SKColor(red: 0.08, green: 0.08, blue: 0.18, alpha: 0.95)
        bg.strokeColor = SKColor(red: 0.45, green: 0.5, blue: 0.7, alpha: 1)
        bg.lineWidth = 1
        container.addChild(bg)

        // Input bar stripe at the bottom of the panel — the UITextField
        // overlays this rect in view-space.
        let inputBar = SKShapeNode(rect: CGRect(
            x: chatPadding,
            y: chatPadding,
            width: boxWidth - chatPadding * 2,
            height: chatInputBarHeight
        ), cornerRadius: 1)
        inputBar.fillColor = SKColor(red: 0.04, green: 0.04, blue: 0.10, alpha: 1)
        inputBar.strokeColor = SKColor(red: 0.3, green: 0.35, blue: 0.5, alpha: 0.6)
        inputBar.lineWidth = 0.5
        container.addChild(inputBar)

        // Divider above the input bar.
        let dividerY = chatPadding + chatInputBarHeight + chatDividerGap
        let dividerPath = CGMutablePath()
        dividerPath.move(to: CGPoint(x: chatPadding, y: dividerY))
        dividerPath.addLine(to: CGPoint(x: boxWidth - chatPadding, y: dividerY))
        let divider = SKShapeNode(path: dividerPath)
        divider.strokeColor = SKColor(red: 0.3, green: 0.35, blue: 0.5, alpha: 0.45)
        divider.lineWidth = 0.5
        container.addChild(divider)

        container.position = CGPoint(
            x: -size.width / 2 + chatBoxMargin,
            y: -size.height / 2 + chatBoxMargin
        )
        cameraNode.addChild(container)
        dialogNode = container
        chatBackground = bg
        chatLines = []
        currentThinkingLabel = nil
        chatScrollOffset = 0
        chatStickyToBottom = true
        chatScrollAccumulator = 0
    }

    private func showChatLog() {
        dialogNode?.alpha = 1
    }

    private func hideChatLog() {
        dialogNode?.alpha = 0
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

        // If the user has scrolled up to read history, bump the offset so
        // their visible window stays anchored on the same older lines
        // instead of jumping when a new line arrives.
        if !chatStickyToBottom {
            chatScrollOffset += 1
        }

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

    /// Stack visible lines from the bottom of the content area upward,
    /// starting at `chatScrollOffset` from the newest. Lines outside the
    /// visible window are hidden (alpha=0). Panel height is fixed so the
    /// play area never shifts.
    private func relayoutChatLog() {
        guard dialogNode != nil, chatBackground != nil else { return }
        let boxHeight = size.height * chatPanelHeightFraction
        let contentBottomY = chatPadding + chatInputBarHeight + chatDividerGap + chatPadding
        let contentTopY = boxHeight - chatPadding
        let contentMaxHeight = contentTopY - contentBottomY

        var heights: [CGFloat] = []
        for label in chatLines {
            heights.append(max(label.frame.height, chatFontSize))
        }

        // Clamp the offset against the bottom of the list. We can't scroll
        // past having only the oldest line in view, so the cap is count-1.
        let maxOffset = max(0, chatLines.count - 1)
        if chatScrollOffset > maxOffset { chatScrollOffset = maxOffset }
        if chatScrollOffset < 0 { chatScrollOffset = 0 }

        // Walk backwards from (newest - offset), keeping lines until overflow.
        let startIdx = chatLines.count - 1 - chatScrollOffset
        var firstVisibleIdx = startIdx + 1
        var stacked: CGFloat = 0
        if startIdx >= 0 {
            for i in stride(from: startIdx, through: 0, by: -1) {
                let extra = heights[i] + (i < startIdx ? chatLineSpacing : 0)
                if stacked + extra > contentMaxHeight { break }
                stacked += extra
                firstVisibleIdx = i
            }
        }

        // Lay out visible labels from bottom (newest-visible) up; hide the rest.
        var nextBottom = contentBottomY
        for i in stride(from: chatLines.count - 1, through: 0, by: -1) {
            let label = chatLines[i]
            if i >= firstVisibleIdx && i <= startIdx {
                label.alpha = 1
                label.position = CGPoint(x: chatPadding, y: nextBottom + heights[i])
                nextBottom += heights[i] + chatLineSpacing
            } else {
                label.alpha = 0
            }
        }
    }

    /// Move the chat view by `lineDelta` lines. Positive = older, negative =
    /// newer. Flips the sticky flag so future messages know whether to keep
    /// the view pinned to the bottom or hold the user's current position.
    private func scrollChatBy(lines lineDelta: Int) {
        guard !chatLines.isEmpty else { return }
        let maxOffset = max(0, chatLines.count - 1)
        let newOffset = max(0, min(maxOffset, chatScrollOffset + lineDelta))
        if newOffset == chatScrollOffset { return }
        chatScrollOffset = newOffset
        chatStickyToBottom = (newOffset == 0)
        relayoutChatLog()
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
                let npcPersonality = npc.personality
                Task.detached { [weak npc] in
                    let reflection = await NPCBrain.generateReflection(
                        npcName: npcName,
                        role: npcRole,
                        personality: npcPersonality,
                        schedule: schedule,
                        memories: memories
                    )
                    guard let reflection else { return }
                    let intentions = await NPCBrain.generateIntentions(
                        npcName: npcName,
                        role: npcRole,
                        personality: npcPersonality,
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
        guard !playerChatActive else { return }
        // If an NPC-NPC chat was running, end its participants cleanly so
        // they're not stuck in "Chatting" forever; the chat task itself
        // notices `playerChatActive` and skips its UI callbacks.
        if waitingForDialogue {
            for n in npcs where n.isChatting {
                n.endChat(clock: gameClock)
            }
            waitingForDialogue = false
        }
        playerChatActive = true
        playerChatNPC = npc
        playerChatTranscript = []
        // Capture activity context BEFORE beginPlayerChat overrides it to "Talking".
        playerChatNPCActivity = npc.currentActivity
        playerChatNPCActivityDuration = npc.activityDurationDescription(currentMinutes: gameClock.totalMinutes)
        npc.beginPlayerChat(clock: gameClock)
        openChatLog()
        showChatLog()
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

        // Pan gesture for scrolling chat history. Lives on the SKView so
        // drags anywhere over the chat panel scroll the log.
        let panTarget = ChatPanTarget { [weak self] dy, ended in
            self?.handleChatPanDelta(dy: dy, ended: ended)
        }
        let pan = UIPanGestureRecognizer(target: panTarget, action: #selector(ChatPanTarget.onPan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        chatPanTarget = panTarget
        chatPanGesture = pan

        let field = UITextField(frame: .zero)
        field.borderStyle = .none
        field.returnKeyType = .send
        field.autocapitalizationType = .sentences
        field.textColor = .white
        field.tintColor = .white
        field.backgroundColor = .clear
        field.attributedPlaceholder = NSAttributedString(
            string: "Say something…",
            attributes: [.foregroundColor: UIColor(white: 0.55, alpha: 1)]
        )
        let leftPad = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        field.leftView = leftPad
        field.leftViewMode = .always

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
        if let pan = chatPanGesture {
            self.view?.removeGestureRecognizer(pan)
        }
        chatPanGesture = nil
        chatPanTarget = nil
    }

    /// Convert a pan delta (in view points) into discrete chat scroll lines.
    /// Pulls down on the panel = reveal older content above (offset++).
    private func handleChatPanDelta(dy: CGFloat, ended: Bool) {
        chatScrollAccumulator += dy
        let threshold: CGFloat = 18
        while chatScrollAccumulator >= threshold {
            scrollChatBy(lines: 1)
            chatScrollAccumulator -= threshold
        }
        while chatScrollAccumulator <= -threshold {
            scrollChatBy(lines: -1)
            chatScrollAccumulator += threshold
        }
        if ended { chatScrollAccumulator = 0 }
    }

    /// Anchor the UITextField to the input-bar stripe inside the chat panel
    /// (which lives in scene-space). Convert the panel's input-bar rect into
    /// view coords so the text field tracks the panel's screen footprint.
    private func positionPlayerInputField() {
        guard let view = self.view, let field = playerInputField,
              let container = dialogNode else { return }
        let panelWidth = size.width - chatBoxMargin * 2

        let topLeftLocal = CGPoint(
            x: chatPadding,
            y: chatPadding + chatInputBarHeight
        )
        let bottomRightLocal = CGPoint(
            x: panelWidth - chatPadding,
            y: chatPadding
        )
        let topLeftScene = container.convert(topLeftLocal, to: self)
        let bottomRightScene = container.convert(bottomRightLocal, to: self)
        let topLeftView = convertPoint(toView: topLeftScene)
        let bottomRightView = convertPoint(toView: bottomRightScene)

        let frame = CGRect(
            x: topLeftView.x,
            y: min(topLeftView.y, bottomRightView.y),
            width: bottomRightView.x - topLeftView.x,
            height: abs(bottomRightView.y - topLeftView.y)
        )
        field.frame = frame
        let fontPx = max(8, frame.height * 0.35)
        field.font = UIFont(name: "Menlo", size: fontPx) ?? .systemFont(ofSize: fontPx)
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
        let npcPersonality = npc.personality
        let npcMood = npc.currentMood
        let location = MapLocation.nearestName(to: npc.gridPos)
        let timeOfDay = gameClock.timeString
        let activity = playerChatNPCActivity
        let activityDuration = playerChatNPCActivityDuration
        let observations = npc.memory.recentObservations()
        let intentions = npc.intentions
        let history = playerChatTranscript
        let fragment = npc.sheet.fragment
        let unlockConditions = npc.sheet.unlockConditions
        let dodgesTopics = npc.sheet.dodgesTopics
        let alreadyRevealed = journal.unlockedNames.contains(npcName)
        let day = currentDay

        Task.detached { [weak self, weak npc] in
            let response = await NPCBrain.respondToPlayer(
                npcName: npcName,
                role: npcRole,
                personality: npcPersonality,
                mood: npcMood,
                location: location,
                timeOfDay: timeOfDay,
                npcActivity: activity,
                npcActivityDuration: activityDuration,
                npcObservations: observations,
                npcIntentions: intentions,
                fragment: fragment,
                unlockConditions: unlockConditions,
                dodgesTopics: dodgesTopics,
                fragmentAlreadyRevealed: alreadyRevealed,
                playerMessage: trimmed,
                chatHistory: history
            )
            let line = response?.line ?? "..."
            // Trust fragmentRevealed only if the NPC actually holds a
            // fragment and hasn't been logged before.
            let revealed = (response?.fragmentRevealed ?? false) && fragment != nil && !alreadyRevealed

            await MainActor.run { [weak self, weak npc] in
                guard let self else { return }
                self.commitCurrentLine(text: line)
                self.playerChatTranscript.append("\(npcName): \"\(line)\"")
                self.playerChatNPCThinking = false
                if revealed, let fragment {
                    self.journal.record(JournalEntry(
                        npcName: npcName,
                        fragment: fragment,
                        unlockedAtDay: day
                    ))
                    self.updateFragmentCounter()
                }
                if let npc {
                    let timeStr = self.gameClock.timeString
                    npc.memory.logDialogue(speaker: "Visitor", partner: "Visitor", line: trimmed, at: timeStr)
                    npc.memory.logDialogue(speaker: npcName, partner: "Visitor", line: line, at: timeStr)
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

/// Bridges UIPanGestureRecognizer's @objc requirement to a Swift closure on
/// the scene. Reports incremental dy deltas; resets between drags.
private final class ChatPanTarget: NSObject {
    let onDelta: (CGFloat, Bool) -> Void
    private var lastTranslationY: CGFloat = 0

    init(onDelta: @escaping (CGFloat, Bool) -> Void) {
        self.onDelta = onDelta
    }

    @objc func onPan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let t = gesture.translation(in: view).y
        switch gesture.state {
        case .began:
            lastTranslationY = 0
        case .changed:
            let dy = t - lastTranslationY
            lastTranslationY = t
            onDelta(dy, false)
        case .ended, .cancelled, .failed:
            lastTranslationY = 0
            onDelta(0, true)
        default:
            break
        }
    }
}
#endif
