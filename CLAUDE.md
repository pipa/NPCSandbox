# NPC Sandbox

Goal: Top-down town simulation with 3-4 NPCs to test 
believability mechanics before committing to a larger game.

## Architecture
- SpriteKit + GameplayKit (Apple-native, no third-party engines)
- Body/Soul separation: deterministic schedules drive actions, 
  LLM reserved for dialogue and memory reflection
- Utility-based interrupt system for agenda priorities
- Memory stream per NPC, compressed daily into bullet points

## Conventions
- Swift idioms, no Objective-C
- Schedule-first, LLM as texture not driver
- Instrumentation/logging built in from day one

## Current scope
- 3-4 NPCs with hand-authored agendas
- Single day, no looper yet
- Observer mode only, no player interaction
- Placeholder art (Kenney's Tiny Town)
