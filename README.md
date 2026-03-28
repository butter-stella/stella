# Natsume

Godot AVG / Galgame framework — the first open-source Godot framework with commercial-grade Japanese visual novel features.

## Features

- **Custom DSL** (`.ntm`) — writer-friendly scripting with smart defaults
- **Scenario Engine** — command-pattern architecture, fully extensible
- **Dialogue System** — typewriter effect, ADV/NVL/overlay modes, inline expression switching
- **Character System** — show/hide/move/animate, expression switching, position presets
- **Background System** — double-buffered with fade transitions
- **Audio System** — BGM/SE/voice with per-character volume control
- **CG System** — fullscreen/SD/animated/differential CG
- **Choice System** — abstract presenter, supports custom UI styles
- **Variable System** — 3 scopes (global/scenario/temp), expression evaluator
- **Save System** — snapshot-based save/load with multiple slots
- **Settings System** — text speed, auto-play, skip, volume, per-character voice
- **Playback Control** — auto-play, skip (read-only), read flag tracking, backlog
- **Game State Machine** — title/playing/paused/save-load/backlog/settings
- **Expression Timeline** — voice/text-driven expression switching
- **Voice Bookmarks** — collect and replay voice lines
- **Gallery System** — CG/BGM/scene unlock tracking
- **Localization** — multi-locale key-value translation

## Tech Stack

- Godot 4.6+, GDScript
- GUT for testing (232+ tests)
- Rust via gdext (for performance extensions, when needed)

## Quick Start

1. Clone this repository
2. Open `project.godot` in Godot 4.6+
3. Press F5 to run the POC demo

## Docs

- [Architecture & Plan](docs/PLAN.md) — architecture, tech stack, sprint roadmap, testing strategy
- [DSL Design](docs/DSL.md) — DSL syntax spec, smart defaults, examples
- [POC Plan](docs/POC.md) — proof of concept implementation details
- [Research](docs/RESEARCH.md) — competitive analysis, syntax comparison

## License

MIT
