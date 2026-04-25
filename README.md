# NPC Sandbox

A top-down town simulation for testing believability mechanics in a small village. The goal: find out how convincing 3–4 NPCs can feel when their behavior is driven by deterministic schedules and their dialogue by an on-device LLM, before committing to a larger game.

## What's in it

- **2 NPCs** (Elara the baker, Mora the tavern keeper) following hand-authored schedules with intentional crossing points
- **Pathfinding** via `GKGridGraph` A* on a 20×15 tile map (Kenney's Tiny Town)
- **Memory stream** per NPC — observations (cooldown-gated), actions, and dialogue lines, compressed daily into a reflection
- **Utility-based social interrupts** — when two NPCs are close enough and their social score beats the schedule, they pause to chat
- **On-device LLM dialogue** via Apple's `FoundationModels` framework — each NPC has its own `LanguageModelSession` with role baked into `Instructions`
- **Daily reflection** — at 22:00 the model produces a first-person summary of each NPC's day from their bullets
- **Day looper** — clock advances, day rolls over at midnight, NPCs reset, night ticks 12× faster

## Stack

- Swift, SpriteKit, GameplayKit
- Apple `FoundationModels` (requires an Apple Intelligence–enabled device)
- No third-party dependencies

## Running

Open `NPCSandbox.xcodeproj` and pick a scheme:

- `NPCSandbox macOS` — runs as a Mac app. App Sandbox is disabled in Debug/Release so the framework can reach the model XPC service
- `NPCSandbox iOS` — runs on iPhone or iPad. Apple Intelligence must be enabled in Settings

The simulation starts in observer mode at 06:00 of day 1. Tap an NPC to inspect their recent memory.

## Architecture

**Body/Soul separation.** Schedules drive behavior; the LLM is reserved for dialogue and reflection. NPCs are never asked "what would you do next" — they follow their day, and the model only animates the moments they pause to talk.

**Schedule-first, LLM as texture not driver.** Chat *content* is generated; the *decision* to chat is a deterministic utility comparison.

**Per-NPC sessions.** Each NPC owns a `LanguageModelSession` whose `Instructions` carry its role. Per-call prompts then only need situational context, which keeps prefill fast on M1-class NPUs (~3–4s round trip per line).

## Status

Working: M0–M9 plus a perf rework (per-NPC sessions, role-as-instructions, non-streaming dialogue).

Next: restoring a third NPC (Gareth the farmer), multi-turn conversations, structured dialogue via `@Generable`, and eventually player interaction.
