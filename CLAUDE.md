# Natsume — Development Guidelines

## Project

Godot AVG / Galgame framework. Architecture docs in `docs/PLAN.md`, DSL design in `docs/DSL.md`, competitive research in `docs/RESEARCH.md`.

## Tech Stack

- Godot 4, GDScript (primary)
- Rust via gdext (for performance-critical extensions, when needed)
- Custom DSL (.ntm) for scenario scripting

## Development Rules

### TDD (Test-Driven Development)

- **Write tests first, then implementation.** For every new feature or module:
  1. Write failing tests that define the expected behavior
  2. Write the minimum code to make tests pass
  3. Refactor while keeping tests green
- Do not skip the red-green-refactor cycle. Tests are not an afterthought.

### Test Coverage

- **Minimum 80% coverage** for all modules.
- Core layer: target ≥ 90%.
- Presentation layer: target ≥ 70%.
- Every PR must include tests for the code it introduces or modifies.

### PR Requirements

Every PR description must include a **Work Summary** section:

```
## Work Summary

### What was implemented
- (bullet list of features/changes)

### Issues encountered
- (pitfalls, unexpected behaviors, workarounds applied)
- (if none, write "None")

### Testing
- (what tests were added, coverage notes)
```

## Repo Conventions

- Code organized as a Godot project
- Tests use GUT (Godot Unit Test) framework
- Docs: `docs/`
