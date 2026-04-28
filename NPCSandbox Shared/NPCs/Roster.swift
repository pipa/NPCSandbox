/// Master list of every NPC sheet in the game. The scene reads this on
/// spawn to instantiate the cast. Add new NPCs by creating a sheet file
/// (one per villager) and appending its `sheet` constant here.
enum Roster {
    static let all: [Lifesheet] = [
        Elara.sheet,
        Mora.sheet,
        Gareth.sheet,
        Aldric.sheet,
        Hilda.sheet,
        Stranger.sheet,
    ]
}
