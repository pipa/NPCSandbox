import SpriteKit

/// Structured profile for a single NPC. Combines numeric weights, prose
/// personality (LLM fodder), the fragment they hold in the doom puzzle, and
/// behavioral config (schedule, sociability, sprite). One per villager,
/// stored in `NPCs/<Name>.swift`.
struct Lifesheet {

    // MARK: - Identity

    let name: String
    let age: Int
    let role: String                 // e.g. "the village baker"
    let personality: String          // prose blurb baked into LLM Instructions

    // MARK: - Inner life (drives behavior + dialogue tone)

    let traits: [Trait: Double]      // 0.0…1.0
    let lifeEvents: [String]         // formative experiences the LLM can pull on
    let values: [String]             // what they care about
    let fears: [String]              // what closes them off

    // MARK: - Doom puzzle role

    /// What this NPC contributes to the ritual. `nil` for non-puzzle NPCs.
    let fragment: Fragment?
    /// Human-readable conditions; the dialogue layer checks player input
    /// against these to decide whether to surface the fragment.
    let unlockConditions: [String]
    /// Topics this NPC pivots away from — strengthens prompts.
    let dodgesTopics: [String]
    /// Small-talk hooks that warm them up before harder questions.
    let opensWith: [String]

    // MARK: - Behavior config

    let sociability: Double
    let dialogueColor: SKColor
    let spawnTileID: Int             // CharTile.X
    let startPos: GridPosition
    let schedule: [ScheduleEntry]
}

/// Numeric personality dimensions. Use as weights in utility AI and as
/// hints in dialogue prompts ("she's anxious, lean cautious").
enum Trait: String, Hashable, Sendable {
    case introversion
    case extraversion
    case anxiety
    case openness
    case faith
    case stubbornness
    case kindness
    case ambition
    case curiosity
    case conscientiousness
}

/// The four pieces the player must gather to perform the ritual at sunset.
enum Fragment: Sendable {
    /// A verse passed down through family. Only emerges in calm moments.
    case song(text: String)
    /// A specific spot in the world the offering must be placed.
    case place(GridPosition, hint: String)
    /// A binding incantation, half-forgotten. Held by a broken believer.
    case words(text: String)
    /// What to give — Hilda knows the kind. Often gated on a personal item.
    case offering(itemNeeded: String)

    /// Embedded into the LLM prompt for fragment-holding NPCs. Tells the
    /// model what the NPC would actually say if the player has earned it.
    var promptDescription: String {
        switch self {
        case .song(let text):
            return "an old verse your grandmother sang. When revealed, recite it as your line: \"\(text)\""
        case .place(_, let hint):
            return "the location of a buried marker. When revealed, describe it as: \(hint)"
        case .words(let text):
            return "a binding incantation, half-forgotten. When revealed, speak it as your line: \"\(text)\""
        case .offering(let item):
            return "the kind of offering needed. When revealed, name it: \(item)"
        }
    }

    /// Short human-readable line for the player's journal.
    var journalSummary: String {
        switch self {
        case .song(let text): return "Song: \"\(text)\""
        case .place(_, let hint): return "Place: \(hint)"
        case .words(let text): return "Words: \"\(text)\""
        case .offering(let item): return "Offering: \(item)"
        }
    }
}
