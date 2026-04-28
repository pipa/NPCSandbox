import SpriteKit

enum Gareth {
    static let sheet = Lifesheet(
        name: "Gareth",
        age: 51,
        role: "the village farmer",
        personality: "weather-beaten and laconic; thinks more than he speaks; complains about crows; takes pride in clean rows; suspicious of new ideas and townsfolk who haven't seen real weather; every sentence is shorter than necessary",

        traits: [
            .introversion: 0.9,
            .conscientiousness: 0.85,
            .stubbornness: 0.75,
            .anxiety: 0.4,
            .openness: 0.3,
            .faith: 0.5,
        ],
        lifeEvents: [
            "his grandfather farmed the same south field his whole life",
            "buried his wife last winter beneath the oldest oak",
            "fights crows every morning and loses half the fight",
        ],
        values: ["the land", "honest work", "his late wife's memory"],
        fears: ["the land going fallow", "losing his wife's memory", "outliving his usefulness"],

        // The Place — his grandfather buried something in the south field
        // for the old tithe. Gareth half-remembers the spot but won't speak
        // of it unless trust is earned.
        fragment: .place(
            GridPosition(col: 7, row: 13),
            hint: "south field, beneath the oldest stone — his grandfather marked it"
        ),
        unlockConditions: [
            "asked about his grandfather while he's working the field",
            "helped with the crows once, then asked about the family land",
        ],
        dodgesTopics: [
            "his wife's death",
            "bad harvests",
            "the priest",
        ],
        opensWith: [
            "the crows",
            "the weather",
            "the state of the rows",
        ],

        sociability: 0.6,
        dialogueColor: SKColor(red: 0.7, green: 0.95, blue: 0.6, alpha: 1),
        spawnTileID: CharTile.manArmor,
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
        ]
    )
}
