import SpriteKit

enum Hilda {
    static let sheet = Lifesheet(
        name: "Hilda",
        age: 73,
        role: "the old crone of the woods",
        personality: "wary and sharp-tongued; stopped speaking to most of the village a decade ago; remembers everything; keeps her dead husband's pipe by the door; will close on you if you come empty-handed; trusts only what is brought, not what is said",

        traits: [
            .introversion: 0.95,
            .stubbornness: 0.85,
            .openness: 0.4,
            .anxiety: 0.3,
            .faith: 0.6,
            .kindness: 0.4,
        ],
        lifeEvents: [
            "buried her husband Tobias forty years ago and never moved his pipe",
            "remembers when the village paid the tithe and what it was paid with",
            "watched neighbors stop speaking of it, one by one, and stopped speaking herself",
        ],
        values: ["her husband's memory", "the old ways", "being left alone"],
        fears: [
            "being alone in the dark",
            "forgetting Tobias's voice",
            "the keep at night",
        ],

        // The Offering — knows what kind, but won't say unless brought
        // something her late husband owned. Gareth has the pipe (took it
        // for safekeeping after the wake) and won't part with it easily.
        fragment: .offering(
            itemNeeded: "Tobias's pipe — Gareth has been keeping it since the wake"
        ),
        unlockConditions: [
            "brought her something that belonged to her husband",
            "named Tobias unprompted (after learning it from someone else)",
        ],
        dodgesTopics: [
            "her health",
            "the village",
            "what is coming at sunset",
        ],
        opensWith: [
            "the weather (briefly)",
            "an offering at her door",
            "her husband's name, if you know it",
        ],

        sociability: 0.3,
        dialogueColor: SKColor(red: 0.85, green: 0.7, blue: 0.85, alpha: 1),
        spawnTileID: CharTile.womanGray,
        startPos: MapLocation.cronesCottage,
        schedule: [
            ScheduleEntry(hour: 6, minute: 30, location: MapLocation.cronesCottage, activity: "Tending the garden"),
            ScheduleEntry(hour: 9, minute: 0, location: MapLocation.cronesCottage, activity: "Gathering herbs"),
            ScheduleEntry(hour: 11, minute: 30, location: MapLocation.townSquare, activity: "A rare visit"),
            ScheduleEntry(hour: 12, minute: 30, location: MapLocation.cronesCottage, activity: "Returning home"),
            ScheduleEntry(hour: 14, minute: 0, location: MapLocation.cronesCottage, activity: "Watching the path"),
            ScheduleEntry(hour: 18, minute: 0, location: MapLocation.cronesCottage, activity: "Sitting by the door"),
            ScheduleEntry(hour: 21, minute: 0, location: MapLocation.cronesCottage, activity: "Sleeping"),
        ]
    )
}
