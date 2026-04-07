# Stella — Development Guidelines

## Project

Godot AVG / Galgame framework. Architecture docs in `docs/ARCHITECTURE.md`, DSL design in `docs/DSL.md`, competitive research in `docs/RESEARCH.md`.

## Tech Stack

- Godot 4.6+, GDScript (primary)
- Rust via gdext (for performance-critical extensions, when needed)
- Custom DSL (.stla) for scenario scripting
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

Launch CR sub-agent(s) in background to review the PR. Choose the right shape based on PR size and risk:

**Small / mechanical PR** (rename, single-file UI tweak, doc update):
- 1× sonnet code-review agent. Authorized to merge if clean.

**Medium / non-trivial PR** (new feature, refactor touching multiple files, anything user-visible):
- 2× agents in **parallel**:
  - **sonnet code-review agent** — line-level correctness, edge cases, GDScript idioms, test gaps, end-to-end wiring trace
  - **opus architect agent** — design-level concerns: layering, scalability of patterns, API stability, alternatives that may have been overlooked, status of any prior-round concerns
- Both agents are explicitly told NOT to merge in their first round; they only report. The main agent synthesizes both reports and decides what to fix vs follow-up.

**After fixes** (round 2, 3, ...): re-launch BOTH agents (parallel) on the updated state. Tell each one explicitly that this is a re-review of the fixed state; reference the previous round's concerns by number/topic so they can update status (RESOLVED / PARTIAL / STILL OPEN).

**Final merge**: once both agents reach "ready / mergeable" verdict (or only minor non-blocking concerns remain), launch a separate **merger CR agent** with explicit user authorization quoted in the prompt. This agent runs the same sanity checks once more, then `gh pr merge --squash --delete-branch`.

**Merge policy:**
- **Planned tasks** (sprint-driven, pre-defined; or implementing a tracked GitHub issue): CR agent can auto-merge if no critical issues found in the FIRST round. No need for the multi-round dance unless complexity warrants it.
- **Unplanned tasks** (ad-hoc features, user requests, bug fixes initiated mid-conversation): create PR but do NOT auto-merge — leave open for user to review. CR agents must be told explicitly "do NOT merge" in the prompt. Only after the user explicitly authorizes ("可以合并了" or similar) does the main agent launch a merger CR agent with that authorization quoted.

**重要：只有 CR sub-agent 有权合并 PR。** 主 agent 不得自行执行 `gh pr merge`。如果 CR agent 未能合并（超时、报错等），应重新启动 CR agent 而不是手动合并。这确保所有合并到 main 的代码都经过了独立 review。

**CR prompt construction tips** (battle-tested on PR #87 / #92-#95):
- Provide the agent with FULL context of what to verify — list specific concerns by file:line, especially anything that previous CR rounds flagged. Don't make the agent rediscover everything from scratch.
- For re-review rounds, include a "v1 concerns status check" section asking the agent to mark each prior concern as RESOLVED / PARTIAL / STILL OPEN. This forces explicit verification rather than vague reassurance.
- Tell the agent to run tests itself (not just trust the PR description). The exact commands:
  ```
  godot --headless --import 2>&1 | tail -3
  godot -s addons/gut/gut_cmdln.gd --headless -gdir=res://tests/unit,res://tests/integration -gexit 2>&1 | tail -10
  ```
- Word limit reports: "under 600 words" for code-review, "600-1200 words" for architect. Without this they tend to over-report.
- For merger agents: include the user's exact authorization quote in the prompt so the agent can satisfy CLAUDE.md's "user is the reviewer" gate for unplanned tasks.

### 7. Fix CR Feedback

If the CR agent (or any previous CR) found issues:
- **直接在原 PR 分支上修复**，不要另开 fix/ 分支
- Write tests that expose the bugs first (TDD)
- Fix the bugs
- Run tests, commit, push 更新原 PR
- Re-launch BOTH agents (parallel) for another round

Between rounds, synthesize the two reports yourself before deciding what to fix:
- **Must-fix** (shipping blockers, correctness bugs): fix in the current PR, no exceptions. If the same issue is flagged by both sonnet and opus it's almost certainly a blocker.
- **Should-fix** (low-cost improvements, small test gaps): fix in current PR if cheap, otherwise file a follow-up issue.
- **Follow-up only** (architectural debt, invasive refactors, polish): file GitHub issues via `gh issue create` and link them in the PR body. Don't scope-creep the current PR.

When an architect agent proposes an alternative design (like "Alternative D: skip the replay infrastructure entirely"), **pause and check with the user before wholesale refactors**. Don't silently adopt a major redesign just because one agent suggested it — but don't dismiss it either. Present the tradeoff concisely and let the user pick.

#### Case study: PR #87 (backlog jump)

The CR strategy above was forged on PR #87 (`feat: backlog 跳转`) and its 4 follow-ups (#92–#95). The numbers:

| Round | State | CR outcome |
|---|---|---|
| v1 | Sparse anchor snapshots + engine replay mode + 16-handler `if is_replay` branches | architect flagged 10 concerns (major: replay pattern doesn't scale, `ScenarioContext.presentation_state: Variant` layering leak, command identity instability, new-game-doesn't-clear-backlog bug) |
| v2 | Adopted architect's **Alternative D**: per-entry full snapshot + `max_entries=200`. Net –516 lines. | Concerns #1 / #2 auto-RESOLVED by deletion. But sonnet + opus each independently flagged ChoiceHandler permanent park and clear-on-fresh-state missed paths. |
| v3 | Fixed 5 blockers (choice unblock, clear chokepoint, autosave race, fade reset, vacuous test) | Both agents "ready to merge" — user manually playtested demo and authorized merge |
| follow-up | 4 issues (#88–#91) turned into separate PRs #92–#95, each 1× sonnet auto-merge | All clean first try |

**Key lessons this codified into the policy above**:

1. **Trust parallel dual agents for medium+ PRs** — they catch independent concerns. The choice-handler bug in v2 was found by both; that coincidence raised confidence it was real, not opinion.
2. **Don't let agents skip test runs** — early CR rounds reported "LGTM" before actually running GUT. Prompt must demand test execution.
3. **Major redesigns need user confirmation** — Alternative D was the architect's suggestion; presenting the tradeoff ("~200KB memory vs. removing 516 lines + entire class of bugs") let the user make an informed call within 2 messages.
4. **Follow-up issues are a release valve** — don't let CR rounds scope-creep. When architect raised 10 concerns, 4 became follow-up issues instead of being shoved into the same PR.
5. **Squash merge keeps history clean** — 4 iterative commits on PR #87 became 1 commit on main. The iteration history lives in the PR description, not main's log.
6. **Workspace fragility is real** — during the #91 work, a commit landed on the wrong branch (`docs/post-combine` instead of `feat/backlog-ui-cursor-highlight`) due to a detached-HEAD chain from earlier operations. **Always verify `git branch --show-current` immediately before `git commit`** when switching branches frequently.

Full narrative is in PR #87's description on GitHub (the iteration across 3 commits is annotated inline).

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
