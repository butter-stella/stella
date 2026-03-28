# Natsume — Development Guidelines

## Project

Godot AVG / Galgame framework. Architecture docs in `docs/PLAN.md`, DSL design in `docs/DSL.md`, competitive research in `docs/RESEARCH.md`.

## Tech Stack

- Godot 4.6+, GDScript (primary)
- Rust via gdext (for performance-critical extensions, when needed)
- Custom DSL (.ntm) for scenario scripting
- GUT 9.6+ for testing

## Development Workflow

Every task follows this standard loop. Do not skip any step.

### 1. Branch

```
git checkout main && git pull
git checkout -b <type>/<short-description>
```

Branch naming: `feat/`, `fix/`, `chore/`, `docs/`.

### 2. TDD — Red / Green / Refactor

1. **Red**: Write failing tests first. Run tests to confirm they fail (preload errors or assertion failures count as red).
2. **Green**: Write the minimum implementation to make all tests pass.
3. **Refactor**: Clean up while keeping tests green.

Never write implementation before tests. Never skip the red phase.

### 3. Run Tests Locally

```bash
godot --headless --import 2>&1 | tail -1
godot -s addons/gut/gut_cmdln.gd --headless 2>&1
```

All tests must pass (exit code 0) before proceeding.

### 4. Commit & Push

- Stage only relevant files (avoid `git add -A` if possible, but acceptable for new features with many new files).
- Commit message format: `<type>: <concise description>`
- Always include `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>` in the commit body.

### 5. Create PR

PR must include the Work Summary section (see PR Requirements below). Use `gh pr create`.

### 6. Code Review + Merge Policy

Launch a sub-agent (sonnet model, background) to review the PR:
- Read all changed files
- Check for correctness, edge cases, GDScript idioms, test coverage
- If critical issues found: list them, do NOT merge

**Merge policy:**
- **Planned tasks** (from PLAN.md sprints): CR agent can auto-merge if no critical issues
- **Unplanned tasks** (ad-hoc features, user requests, bug fixes): create PR but do NOT merge — leave open for user to review

### 7. Fix CR Feedback

If the CR agent (or any previous CR) found issues:
- Create a dedicated `fix/` branch
- Write tests that expose the bugs first (TDD)
- Fix the bugs
- Run tests, commit, PR, merge

### 8. Next Task

```
git checkout main && git pull
```

Repeat from step 1.

---

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

### Code Review Checklist

CR sub-agents should check:
- Correctness of logic and edge cases
- GDScript idioms and best practices
- Test coverage (are there missing cases?)
- Signal emission timing and async/await correctness
- API design (will it work for downstream consumers?)
- No silent failures (push_warning for unexpected states)

## Repo Conventions

- Code organized as a Godot project under `addons/natsume/`
- Core layer: `addons/natsume/core/` (engine-independent logic)
- Presentation layer: `addons/natsume/presentation/` (Godot UI/rendering)
- Autoloads: `addons/natsume/autoload/` (SignalBus, NatsumeRuntime)
- Tests: `tests/unit/` and `tests/integration/` (GUT framework)
- Game content: `game/` (scenarios, art, audio, scenes)
- Docs: `docs/`
