# Natsume — Development Guidelines

## Project

Unity AVG / Galgame framework. Architecture docs in `docs/PLAN.md`, usage guide in `docs/USAGE.md`, DSL design in `docs/DSL.md`.

## Development Rules

### TDD (Test-Driven Development)

- **Write tests first, then implementation.** For every new feature or module:
  1. Write failing tests that define the expected behavior
  2. Write the minimum code to make tests pass
  3. Refactor while keeping tests green
- Do not skip the red-green-refactor cycle. Tests are not an afterthought.

### Test Coverage

- **Minimum 80% coverage** for all modules.
- Core layer (pure C#): target ≥ 90%.
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

## Tech Stack

- Unity 6 LTS, C#
- YamlDotNet, UniTask, DOTween
- Pure C# core layer (no Unity dependency), presentation layer uses Unity APIs

## Repo Conventions

- Namespace: `Natsume.*`
- Code under `Assets/Natsume/` (UPM package structure)
- Tests: `Assets/Natsume/Tests/EditMode/` and `Assets/Natsume/Tests/PlayMode/`
- Docs: `docs/`
- CI: GitHub Actions with game-ci
