import SpriteKit
import GameplayKit

@MainActor
class Player {
    let name: String
    let sprite: SKSpriteNode
    let label: SKLabelNode
    private(set) var gridPos: GridPosition
    private(set) var isWalking: Bool = false

    private let tileSize: CGFloat
    private let mapRows: Int

    init(
        name: String,
        tileID: Int,
        startPos: GridPosition,
        dialogueColor: SKColor,
        tileSize: CGFloat,
        mapRows: Int
    ) {
        self.name = name
        self.gridPos = startPos
        self.tileSize = tileSize
        self.mapRows = mapRows

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
        sprite.zPosition = 11

        label = SKLabelNode(text: name)
        label.fontSize = 5
        label.fontColor = dialogueColor
        label.fontName = "Menlo-Bold"
        label.verticalAlignmentMode = .bottom
        label.position = CGPoint(x: 0, y: tileSize * 0.65)
        label.zPosition = 60
        sprite.addChild(label)
    }

    func walkTo(_ target: GridPosition, navGraph: GKGridGraph<GKGridGraphNode>) {
        // If a walk is already in progress, cancel it and re-anchor gridPos to
        // whichever tile the sprite is closest to right now. Otherwise the new
        // path would be computed from the stale starting cell, snapping the
        // sprite back to where the previous walk began.
        if isWalking {
            sprite.removeAllActions()
            isWalking = false
            let nearestCol = Int(round((sprite.position.x - tileSize / 2) / tileSize))
            let nearestRowFromBottom = Int(round((sprite.position.y - tileSize / 2) / tileSize))
            gridPos = GridPosition(col: nearestCol, row: mapRows - 1 - nearestRowFromBottom)
            sprite.position = tilePosition(gridPos)
        }

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
            let stepPos = GridPosition(col: col, row: row)
            actions.append(SKAction.move(to: tilePosition(stepPos), duration: 0.18))
            actions.append(SKAction.run { [weak self] in
                self?.gridPos = stepPos
            })
        }

        actions.append(SKAction.run { [weak self] in
            self?.isWalking = false
        })

        sprite.run(SKAction.sequence(actions))
    }

    /// Cancel any walk and snap to a specific tile. Used by loop reset to
    /// drop the player back at their start position cleanly.
    func teleport(to pos: GridPosition) {
        sprite.removeAllActions()
        isWalking = false
        gridPos = pos
        sprite.position = tilePosition(pos)
    }

    private func tilePosition(_ pos: GridPosition) -> CGPoint {
        CGPoint(
            x: CGFloat(pos.col) * tileSize + tileSize / 2,
            y: CGFloat(mapRows - 1 - pos.row) * tileSize + tileSize / 2
        )
    }
}
