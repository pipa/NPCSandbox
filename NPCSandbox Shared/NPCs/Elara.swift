import SpriteKit

enum Elara {
    static let sheet = Lifesheet(
        name: "Elara",
        age: 34,
        role: "the village baker",
        personality: "anxious perfectionist; second-guesses every loaf; mutters when distracted; warm but quietly worried about the oven; proud of her sourdough; suspicious of any morning that goes too smoothly",

        traits: [
            .anxiety: 0.85,
            .conscientiousness: 0.9,
            .introversion: 0.6,
            .openness: 0.4,
            .kindness: 0.7,
            .faith: 0.3,
        ],
        lifeEvents: [
            "her grandmother taught her old songs while kneading dough",
            "lost her mother to fever at sixteen",
            "took over the bakery before she felt ready",
        ],
        values: ["the work", "family", "doing right by the village"],
        fears: ["the oven going out", "ruining a batch", "being thought lazy"],

        fragment: .song(
            text: "Stones beneath, stones below, sing the old wind to and fro; tongue of earth, hold the bound, ‘til the morning light is found."
        ),
        unlockConditions: [
            "asked about her grandmother on a calm morning before the bread is in",
            "shared a quiet moment in the bakery without pressing her about the work",
        ],
        dodgesTopics: [
            "why deliveries are late",
            "her father's drinking",
        ],
        opensWith: [
            "how the morning's bread is going",
            "the weather",
            "a kind word about the smell of the bakery",
        ],

        sociability: 0.7,
        dialogueColor: SKColor(red: 0.6, green: 0.9, blue: 1.0, alpha: 1),
        spawnTileID: CharTile.knightVisor,
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
        ]
    )
}
