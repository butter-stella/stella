# Stella Agent Guidelines

## Scope and precedence

This file applies to the whole repository. It is the current agent-facing guide;
`CLAUDE.md` is legacy context and must not override this file when the two differ.
User and system instructions always take precedence.

Before changing a subsystem, read its implementation and the relevant document:

- `docs/ARCHITECTURE.md` for layering and runtime data flow
- `docs/DSL.md` for `.stla` syntax and semantics
- `docs/USAGE.md` for the public integration surface
- `docs/INPUT_DESIGN.md` for input routing and UI interaction

Do not repeat fixed handler counts, test counts, or capability claims without
measuring them from the current checkout.

## Project and repository map

Stella is a Godot visual-novel framework. The project declares Godot 4.6
compatibility and CI currently uses 4.6.1; the implementation is primarily
GDScript. Rust/gdext is not part of the current build and must not be introduced
without an explicit design decision.

- `addons/stella/core/`: domain logic and runtime orchestration
- `addons/stella/presentation/`: UI, rendering, animation, and audio nodes
- `addons/stella/autoload/`: `SignalBus` and the `StellaRuntime` composition root
- `addons/stella/editor/`: Godot editor integration
- `addons/stella/scenes/`: default framework scenes
- `examples/demo/`: redistributable example content
- `tests/unit/`: focused GUT tests
- `tests/integration/`: cross-layer and DSL-to-runtime tests
- `docs/`: user-facing and architectural documentation

`addons/gut/` is vendored test infrastructure. Do not edit it except for an
intentional dependency upgrade. Never edit generated `.godot/` state by hand.

## Architecture invariants

- Keep non-visual logic in `core/` and scene/UI/audio behavior in
  `presentation/`. Core may use Godot primitives, but it must not depend on a
  particular scene layout or concrete UI node.
- Cross-layer runtime communication goes through `SignalBus`. When Core emits a
  new presentation event, wire the corresponding signal and presenter consumer.
- `StellaRuntime` owns subsystem construction and handler registration. Avoid
  hidden parallel composition roots or direct presenter construction in Core.
- Trace behavior end to end: `.stla` source -> lexer/parser -> data model ->
  command handler -> `SignalBus` -> presenter -> user-visible result or input
  acknowledgement.
- A DSL or command change normally requires synchronized updates to parsing,
  command data, handler registration, signals/presenters, tests, and
  `docs/DSL.md`. Do not implement only one link in that chain.
- Treat public DSL, configuration, save data, and extension APIs as compatibility
  surfaces. Document intentional changes and add migration or compatibility
  handling when persisted data is affected.

## Implementation rules

- Follow nearby GDScript style: tabs for indentation, `snake_case` for files,
  functions, and variables, `PascalCase` for `class_name`, and explicit types at
  public boundaries where practical.
- Do not hide race conditions with arbitrary sleeps, timers, or frame waits.
  Synchronize with signals, explicit state/generation guards, cancellation, or
  tween termination. Timers and frame waits remain valid when they express real
  gameplay timing or scene lifecycle semantics.
- Blocking command handlers must remain abortable. Prefer
  `CommandHandler.await_with_abort(...)` so `engine_abort_requested` can cancel
  outstanding work; avoid naked waits that can strand the scenario engine.
- Do not silently discard unexpected commands, invalid state, missing resources,
  or I/O failures. Use the error mechanism appropriate to the API contract and
  retain enough source/runtime context to diagnose the failure.
- For behavior changes, prefer a test that demonstrates the missing behavior
  before or alongside the implementation. A valid regression test must fail for
  the intended reason, not because of unrelated import or preload errors.
  Documentation-only, configuration-only, and mechanical changes do not require
  artificial tests.
- New tracked `.gd` files should keep their Godot-generated `.gd.uid` companions;
  do not invent or hand-edit UID values.

## Testing

Run commands from the repository root. During iteration, run the narrowest
relevant test; before handoff, run the full applicable suite when practical.

```bash
# Import assets and surface script/resource errors.
godot --headless --import

# Full GUT suite; .gutconfig.json includes unit and integration directories.
STELLA_DISABLE_LOCAL_CONFIG=1 \
  godot -s addons/gut/gut_cmdln.gd --headless

# Example targeted file.
STELLA_DISABLE_LOCAL_CONFIG=1 \
  godot -s addons/gut/gut_cmdln.gd --headless \
  -gtest=res://tests/unit/test_scenario_engine.gd

# Godot 4.6.1 export-pack smoke (binary tokens, compressed binary tokens,
# selected-scenes fallback), run with no project export_presets.cfg present.
GODOT_BIN=godot tests/pck_smoke/run_export_smoke.sh
```

Do not pipe these commands through `tail` or another command that masks Godot's
exit status. Tests must not depend on `stella.local.cfg`, `user://` leftovers,
machine-specific paths, or private imported assets. For visual, audio, timing, or
input changes, supplement automated tests with the relevant demo/manual path and
state clearly what was not manually verified.

If the checkout already has unrelated failures, distinguish them from new
regressions and report both; never claim a suite is green unless it was run and
passed in the current environment.

## Git and private-content safety

- Start by checking `git status --short` and `git branch --show-current`. Preserve
  all pre-existing changes and work around a dirty worktree.
- Never reset, discard, overwrite, or stash someone else's changes without an
  explicit request. Stage only files belonging to the requested task.
- Re-check the current branch immediately before committing. When a new branch is
  requested, use the existing `feat/`, `fix/`, `docs/`, `refactor/`, or `chore/`
  naming style.
- Do not commit, push, open or update a PR, create issues, or merge unless the user
  has authorized that external action.
- LLLJ and other proprietary game packages are local validation inputs only.
  Never commit or publish extracted assets, music, scripts, generated scenarios,
  private paths, or derivative fixtures. Public tests and examples must use
  synthetic or explicitly redistributable content.
- Keep local overrides such as `stella.local.cfg` and generated private content
  out of commits.

## Review and pull requests

Review changes proportionately to risk. Check correctness and edge cases, Godot
API usage, signal/async timing, cancellation, state restoration, downstream API
compatibility, test gaps, and the complete end-to-end wiring. Re-run relevant
tests after review fixes.

Avoid broad redesigns or unrelated cleanup inside a focused fix. If a better
architecture materially changes scope, present the tradeoff and get user
direction before adopting it.

When asked to create a PR, include a concise Work Summary covering:

- what changed
- issues, risks, or deliberate tradeoffs
- tests and manual verification performed

Do not merge a PR without explicit user authorization.
