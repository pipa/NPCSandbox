import Foundation

// Tile ID mappings for Kenney's Tiny Town tileset.
// All IDs reference the TinyTown atlas unless noted otherwise.

enum TownTile {

    // MARK: - Terrain

    static let grass = 0
    static let wheat = 3

    // MARK: - Path (single tile, 1-wide)

    static let path = 43

    // MARK: - Path (2-wide, 3-column layout: left edge / center / right edge)
    // Top cap (rounded)
    static let pathTopLeft = 12
    static let pathTopMid = 13
    static let pathTopRight = 14
    // Middle sections
    static let pathMidLeft = 24
    static let pathMidCenter = 25
    static let pathMidRight = 26
    // Bottom cap (rounded)
    static let pathBotLeft = 36
    static let pathBotMid = 37
    static let pathBotRight = 38

    // MARK: - Trees (TinyTown)
    // TODO: verify full set — 15-23 range likely has more variants
    static let treePine = 17
    static let treeGreen = 16

    // MARK: - Buildings

    // Blue roof house (4 wide × 3 tall) — tile 85 is the door
    static let blueHouse: [[Int]] = [
        [48, 49, 50, 51],
        [60, 61, 62, 63],
        [72, 73, 85, 75],
    ]

    // Red roof house (4 wide × 3 tall) — tile 89 is the door
    static let redHouse: [[Int]] = [
        [52, 53, 54, 55],
        [64, 65, 66, 67],
        [76, 77, 89, 79],
    ]
}

// Character tile IDs from the TinyDungeon atlas.
enum CharTile {
    static let villager1 = 97
    static let villager2 = 98
    static let villager3 = 99
    static let villager4 = 100
    static let villager5 = 112
    static let mage = 84
    static let knight1 = 85
    static let knight2 = 86
    static let knight3 = 87
    static let knight4 = 88
}
