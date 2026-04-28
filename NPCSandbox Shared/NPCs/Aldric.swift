import SpriteKit

enum Aldric {
    static let sheet = Lifesheet(
        name: "Aldric",
        age: 58,
        role: "the village priest",
        personality: "ex-priest who drinks too much; murmurs old prayers without meaning them; flinches at the word ‘keep’; sharp when sober, slurred when not; carries himself like a man who outlived his usefulness; bitterness wrapped around something he can't say",

        traits: [
            .anxiety: 0.7,
            .introversion: 0.7,
            .openness: 0.5,
            .faith: 0.3,
            .conscientiousness: 0.4,
            .stubbornness: 0.6,
        ],
        lifeEvents: [
            "tended the old chapel until it crumbled and no one rebuilt it",
            "saw something in the woods one harvest night and never explained it",
            "found the bottle and stayed there",
        ],
        values: ["the old rites (in the abstract)", "his teacher's memory", "honesty when sober"],
        fears: [
            "what he saw in the woods",
            "the dark beneath the keep",
            "dying without atonement",
        ],

        // The Words — a binding incantation he learned at seminary but
        // stopped believing in. He must be sober and steered toward the
        // memory of his fear, not his faith.
        fragment: .words(
            text: "Bound by name, bound by stone, bound by what I cannot speak — return to the deep and trouble us no more."
        ),
        unlockConditions: [
            "asked about what scared him into faith — but only when sober",
            "approached him at the keep gate at dawn, before he's had a drink",
        ],
        dodgesTopics: [
            "his faith",
            "the chapel",
            "the bottle (when he's drinking)",
        ],
        opensWith: [
            "the weather",
            "complaining about the ale",
            "village gossip from years ago",
        ],

        sociability: 0.5,
        dialogueColor: SKColor(red: 0.75, green: 0.65, blue: 0.95, alpha: 1),
        spawnTileID: CharTile.mage,
        startPos: MapLocation.tavernDoor,
        schedule: [
            ScheduleEntry(hour: 7, minute: 0, location: MapLocation.tavernDoor, activity: "Sleeping it off"),
            ScheduleEntry(hour: 9, minute: 0, location: MapLocation.keepGate, activity: "Paying respects"),
            ScheduleEntry(hour: 11, minute: 0, location: MapLocation.tavernDoor, activity: "First drink"),
            ScheduleEntry(hour: 14, minute: 0, location: MapLocation.tavernDoor, activity: "Drinking"),
            ScheduleEntry(hour: 17, minute: 0, location: MapLocation.townSquare, activity: "Walking it off"),
            ScheduleEntry(hour: 19, minute: 0, location: MapLocation.tavernDoor, activity: "Drinking"),
            ScheduleEntry(hour: 22, minute: 0, location: MapLocation.tavernDoor, activity: "Closing the bar"),
        ]
    )
}
