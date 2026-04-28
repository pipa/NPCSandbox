import Foundation

/// Encode a TinyDungeon tile ID for use in mixed-atlas overlays. The
/// renderer routes IDs >= 1000 to the TinyDungeon atlas (id - 1000).
func d(_ id: Int) -> Int { 1000 + id }

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
        [72, 84, 85, 75],
    ]

    // Red roof house (4 wide × 3 tall) — tile 89 is the door
    static let redHouse: [[Int]] = [
        [52, 53, 54, 55],
        [64, 65, 66, 67],
        [76, 88, 89, 79],
    ]

    // Castle / keep (6 wide × 5 tall). Mixes TinyTown and TinyDungeon
    // (d-prefixed) tiles to form two towers flanking a central gate.
    // Bottom row (123, 124) has transparent regions — the renderer paints
    // dirt (pathBotMid) underneath those cells so the gate floor shows.
    // -1 cells are intentionally open (sky/grass between tower tops).
    static let castle: [[Int]] = [
        [-1,    102,    -1,  -1,    102,    -1   ],
        [-1,    d(58),  103, 97,    d(58),  -1   ],
        [96,    d(58),  121, 121,   d(58),  98   ],
        [120,   d(57),  111, 112,   d(59),  122  ],
        [d(57), d(57),  123, 124,   d(59),  d(59)],
    ]

    // MARK: - Props & items

    static let sign = 83
    static let coin = 93
    static let beehive = 94
    static let target = 95          // archery bullseye
    static let stairsDown = 103     // stairs to underfloor
    // Two-tile composite: place wellTop one row above well in the grid.
    static let wellTop = 92         // upper half (well's roof/ceiling)
    static let well = 104           // lower half (basin)
    static let bomb = 106
    static let chestClosed = 107
    static let pickaxe = 115
    static let pitchfork = 116
    static let key = 117            // grey
    static let bow = 118
    static let arrow = 119
    static let mug = 127
    static let shovel = 128
    static let scythe = 129
    static let bucket = 130
    static let bucketFilled = 131
}

// Character & monster tile IDs from the TinyDungeon atlas.
enum CharTile {

    // MARK: - Townsfolk (humans)

    static let mage = 84
    static let manPlain = 85
    static let manBald = 86
    static let manHelm = 87
    static let manHair = 88
    static let knightArmored = 96       // full plate, helmet closed
    static let knightVisor = 97         // armor, helmet open (eyes visible)
    static let manArmor = 98            // armor, no helmet
    static let womanPlain = 99
    static let womanGray = 100          // gray hair, elder

    // MARK: - Outsiders / mysterious

    static let darkMage = 111
    static let manGreen = 112           // bearded, green clothes

    // MARK: - Monsters (humanoid)

    static let ghostGreen = 108
    static let cyclops = 109
    static let crab = 110

    // MARK: - Small creatures

    static let bat = 120
    static let ghostWhite = 121         // larger white ghost
    static let spider = 122
    static let mouseBrown = 123
    static let mouseGray = 124
}

// Dungeon / interior tile IDs from the TinyDungeon atlas.
enum DungTile {

    // MARK: - Selection / highlight markers (use as overlays)

    static let markerFrame = 60
    static let markerCheckered = 61
    static let markerHatched = 62

    // MARK: - Tombstones

    static let tombstoneCross = 64
    static let tombstonePlain = 65

    // MARK: - Chest progression (use sequentially to animate opening)

    static let chestClosed = 89
    static let chestCracked = 90
    static let chestOpen = 91
    static let chestOpenTreasure = 92

    // MARK: - Castle architecture

    static let column = 6                  // also 18, 30
    static let tapestry = 29               // hanging fabric decoration
    static let groundSpikes = 41
    static let castleWalls: [Int] = [36, 37, 38, 39, 40, 57, 58, 59]

    // MARK: - Doors (4-stage open/close animation; 0 = open, 3 = closed)

    static let doorSingle: [Int] = [9, 21, 33, 45]
    static let doorLeft:   [Int] = [10, 22, 34, 46]
    static let doorRight:  [Int] = [11, 23, 35, 47]

    // MARK: - Castle water flow (decoration for stone walls — works
    // both inside a keep and on the outer face of an outdoor compound)

    static let pipeDry = 7                  // wall pipe, no flow
    static let pipeWater = 8                // wall pipe, flowing
    static let fountainFaceDry = 19         // wall sculpture spout, no flow
    static let fountainFaceWater = 20       // wall sculpture spout, flowing
    static let basinDry = 31                // floor basin, empty
    static let basinWater = 32              // floor basin, filled
    static let sewerDry = 43                // floor drain, dry
    static let sewerWater = 44              // floor drain, wet

    // MARK: - Floors / dirt path textures (interchangeable variants)

    static let dirtPath: [Int] = [42, 48, 49, 50, 51, 52, 53]

    // MARK: - Furniture

    static let table = 72
    static let chair = 73
    static let anvil = 74
    static let cabinet = 75

    // MARK: - Minecart tracks

    static let trackVertical: [Int] = [81, 83]
    static let trackVerticalCenter = 82     // unconfirmed — possibly junction
    static let trackHorizontal: [Int] = [70, 94]
    static let trackJunctions: [Int] = [69, 71, 93, 95]

    // MARK: - Minecart sprite (animation frames)

    static let cartHoriz = 54
    static let cartVert = 55
    static let cartDiag = 56
}
