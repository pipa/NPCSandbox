import SpriteKit

enum Mora {
    static let sheet = Lifesheet(
        name: "Mora",
        age: 47,
        role: "the tavern keeper",
        personality: "dry and sharp-tongued; runs the tavern with no nonsense; collects every rumor in town and pretends she doesn't; teases Elara about her bread, gripes about Gareth's slow grain delivery; has opinions on everyone",

        traits: [
            .extraversion: 0.8,
            .openness: 0.7,
            .stubbornness: 0.7,
            .kindness: 0.5,
            .conscientiousness: 0.6,
            .anxiety: 0.3,
        ],
        lifeEvents: [
            "her father ran the tavern before her — drank himself to death behind the bar",
            "married once, briefly, to a sailor who never came back",
            "remembers the village before half the houses fell down",
        ],
        values: ["the truth", "her ledger", "good ale"],
        fears: ["losing the tavern", "being made a fool", "the quiet of the place at closing"],

        // No fragment — Mora is the connector. She hears every rumor; the
        // dialogue layer surfaces hints from her about who knows what.
        fragment: nil,
        unlockConditions: [],
        dodgesTopics: [
            "her ex-husband",
            "her father's drinking",
            "what's owed on the ledger",
        ],
        opensWith: [
            "rumors",
            "asking about other villagers",
            "complimenting the ale",
        ],

        sociability: 0.8,
        dialogueColor: SKColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 1),
        spawnTileID: CharTile.womanPlain,
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
        ]
    )
}
