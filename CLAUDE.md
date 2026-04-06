# Stella — Development Guidelines

## Project

Godot AVG / Galgame framework. Architecture docs in `docs/PLAN.md`, DSL design in `docs/DSL.md`, competitive research in `docs/RESEARCH.md`.

## Tech Stack

- Godot 4.6+, GDScript (primary)
- Rust via gdext (for performance-critical extensions, when needed)
- Custom DSL (.stl) for scenario scripting
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

**重要：只有 CR sub-agent 有权合并 PR。** 主 agent 不得自行执行 `gh pr merge`。如果 CR agent 未能合并（超时、报错等），应重新启动 CR agent 而不是手动合并。这确保所有合并到 main 的代码都经过了独立 review。

### 7. Fix CR Feedback

If the CR agent (or any previous CR) found issues:
- **直接在原 PR 分支上修复**，不要另开 fix/ 分支
- Write tests that expose the bugs first (TDD)
- Fix the bugs
- Run tests, commit, push 更新原 PR
- CR agent 重新 review

### 8. Next Task

```
git checkout main && git pull
```

Repeat from step 1.

---

## Development Rules

### No Delays to Fix Race Conditions

**永远不要用加延时（await create_timer、sleep、process_frame）的方法解决竞态问题。** 延时只是把 bug 藏起来，换个时序就会复现。竞态问题必须用状态机、信号守卫、或同步取消（kill tween）等确定性方案解决。

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
- **End-to-end wiring**: Does the feature actually work? Trace from UI button → signal → handler → presenter → visual feedback. A toggle that only sets a flag but never drives behavior is a critical bug.
- **Godot API correctness**: Property assignment vs method call (e.g. `anchors_preset` vs `set_anchors_and_offsets_preset()`). Verify the API is used correctly per Godot docs.
- **Signal bridging**: If Core layer emits signals, are they connected to SignalBus for Presentation layer to receive?
- **State management**: When entering/leaving UI states, is the previous state preserved? Can overlays return to the correct origin (TITLE vs PLAYING)?

## Repo Conventions

- Code organized as a Godot project under `addons/stella/`
- Core layer: `addons/stella/core/` (engine-independent logic)
- Presentation layer: `addons/stella/presentation/` (Godot UI/rendering)
- Autoloads: `addons/stella/autoload/` (SignalBus, StellaRuntime)
- Tests: `tests/unit/` and `tests/integration/` (GUT framework)
- Game content: `game/` (scenarios, art, audio, scenes)
- Docs: `docs/`
