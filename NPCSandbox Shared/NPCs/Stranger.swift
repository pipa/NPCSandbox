import SpriteKit

enum Stranger {
    static let sheet = Lifesheet(
        name: "the Stranger",
        age: 0,            // unknown / refuses to say
        role: "a traveler who arrived with the omens",
        personality: "watchful, quiet, almost gentle; speaks in half-finished sentences; counts things on his fingers when he thinks no one's looking; will not give a name; treats the player like someone he's been waiting for",

        traits: [
            .openness: 0.7,
            .curiosity: 0.8,
            .conscientiousness: 0.7,
            .introversion: 0.6,
            .faith: 0.4,
            .anxiety: 0.5,
        ],
        lifeEvents: [
            "arrived in the village a few days before the player",
            "has watched the seal break in other places — and survived to walk on",
            "carries the look of someone who's been counting days",
        ],
        values: ["warning", "watching", "being there at the moment"],
        fears: [
            "arriving too late",
            "being believed too soon",
            "the moment of the breaking",
        ],

        // No fragment — the Stranger is the meta-narrator. He confirms the
        // catastrophe is real and points the player toward who to ask, but
        // does not himself hold one of the four pieces.
        fragment: nil,
        unlockConditions: [],
        dodgesTopics: [
            "where he came from",
            "his name",
            "how many places he's seen this happen",
        ],
        opensWith: [
            "the cracks in the sky",
            "the dread under the village",
            "asking the player what they've noticed",
        ],

        sociability: 0.6,
        dialogueColor: SKColor(red: 0.7, green: 0.78, blue: 0.85, alpha: 1),
        spawnTileID: CharTile.manHelm,
        startPos: MapLocation.townSquare,
        schedule: [
            ScheduleEntry(hour: 6, minute: 0, location: MapLocation.townSquare, activity: "Waiting at the well"),
            ScheduleEntry(hour: 8, minute: 0, location: MapLocation.keepGate, activity: "Watching the keep"),
            ScheduleEntry(hour: 10, minute: 30, location: MapLocation.strangerCamp, activity: "Tending his fire"),
            ScheduleEntry(hour: 13, minute: 0, location: MapLocation.townSquare, activity: "Listening"),
            ScheduleEntry(hour: 15, minute: 0, location: MapLocation.keepGate, activity: "Watching the keep"),
            ScheduleEntry(hour: 18, minute: 0, location: MapLocation.townSquare, activity: "A last warning"),
            ScheduleEntry(hour: 20, minute: 0, location: MapLocation.strangerCamp, activity: "Counting"),
        ]
    )
}
