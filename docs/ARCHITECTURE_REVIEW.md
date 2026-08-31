# Stella architecture review

Status: decision document, not a runtime contract.

Review baseline: `main` at `060580712553f4ab419bd7d84bdf723a8b7d4d2d`.
Open pull requests are intentionally excluded until merged. Re-run the evidence
commands below when judging a later revision.

## Executive assessment

Stella's **architectural direction is sound** for a visual-novel framework:
scenario execution is separated from scene rendering, blocking presentation has
typed ownership and cancellation, and persisted state is value-oriented. The
project should continue on this architecture rather than rewrite it.

The main concern is **concentration, not the underlying model**. Feature work has
accumulated in three central files (`StellaRuntime`, `SignalBus` and
`DslParser`) and in the transactional `PresentationDirector`. Their individual
rules are generally defensive, but the combined state space is increasingly
difficult to understand, extend and verify. New product features should continue
only with a parallel effort to make those ownership boundaries smaller and
mechanically enforceable.

## Scorecard

| Area | Assessment | Why |
|---|---|---|
| Scenario vs rendering separation | good | Core handlers do not search concrete scene trees; Presenters own Nodes |
| Runtime ownership | good direction, overloaded implementation | one composition root and generation model, but Runtime coordinates too many domains |
| Presentation transactions | strong but complex | single Director, sealed participants, typed receipts and selective rollback |
| DSL correctness | strong validation, weak modularity | fail-close diagnostics and canonical lowering; one parser owns too many grammars |
| Save/restore | good direction, medium risk | canonical value projection; schemas remain spread across dynamic Dictionaries |
| Input | strong ownership model | stable action IDs and one-edge/one-owner semantics |
| Extensibility | mixed | useful registries exist, but several built-in paths require exact scripts/private capabilities |
| Public API stability | insufficiently explicit | docs describe surfaces, but there is no versioned API inventory or compatibility gate |
| Testability | strong behavioral suite | unit/integration/export tests exist; Autoload state and large owners make isolation expensive |
| Operational complexity | high | the central protocols require extensive same-process and lifecycle regression matrices |

## Evidence snapshot

These numbers are observations, not targets:

| File/domain | Lines at review baseline |
|---|---:|
| `StellaRuntime` | 5,376 |
| `SignalBus` | 5,350 |
| `DslParser` | 4,451 |
| `PresentationDirector` | 2,824 |
| `SaveManager` + `PresentationState` | 1,350 |

Reproduce from the repository root:

```bash
wc -l \
  addons/stella/autoload/stella_runtime.gd \
  addons/stella/autoload/signal_bus.gd \
  addons/stella/core/script_parser/dsl_parser.gd \
  addons/stella/core/presentation/presentation_director.gd \
  addons/stella/core/save_system/save_manager.gd \
  addons/stella/core/save_system/presentation_state.gd
```

File size alone is not a defect. Here it correlates with multiple independent
state machines, registries, compatibility adapters and lifecycle protocols in
the same owner, which raises review and regression cost.

## What should be preserved

### One composition root

Keeping a single Runtime, ScenarioEngine and PresentationDirector prevents
subsystems from racing over the same story cursor or presentation channel. Do
not split these by introducing parallel schedulers or game-specific managers.

### Typed transactional presentation

The reserve → validate → snapshot → seal → apply → receipt → settle model is a
good answer to mixed visual/audio composition. It gives JOIN a real completion
barrier and gives reset/navigation a stale-callback boundary. Preserve the
model while extracting per-channel policy from the Director.

### Canonical value snapshots

Saving logical resources and channel state instead of serializing Nodes/Tweens
is the correct boundary. Restore preflight and generation retirement should
remain mandatory.

### Closed authoring contracts

Unknown DSL/config fields fail rather than silently degrade. That is essential
for Stella's role as an engine validation target: unsupported behavior must be
visible and fixed in Stella, not interpreted through remake compatibility.

## Primary risks

### R1 — Autoload concentration (high)

`StellaRuntime` is simultaneously composition root, Facade, navigation
coordinator, scene validator, action catalog owner, save/load coordinator,
choice policy owner and lifecycle bridge. `SignalBus` combines public events,
typed transport, participant registries, queues and dispatch-scoped metadata.

Consequences:

- unrelated features share mutable global lifetime;
- same-process test order matters more than it should;
- changes require understanding thousands of lines of reentrancy rules;
- ownership is documented in comments rather than expressed by smaller types.

### R2 — Parser concentration (high)

`DslParser` handles structural blocks, every command grammar, canonical
lowering, diagnostics and some semantic validation. New commands add more state
variables and branches to one parse loop. Quote/token behavior is easy to
implement inconsistently between commands.

### R3 — Two presentation communication styles (medium-high)

Simple SignalBus notifications and typed Director transactions coexist. This is
reasonable during migration, but the classification is not mechanically
enforced. A future handler can accidentally wait on a compatibility signal or
let two paths mutate the same domain.

### R4 — Extension claims exceed actual seams (medium-high)

Registering a Handler does not extend the closed `.stla` parser. Some built-in
Presenter admission checks exact script identity. Raw SignalBus signals remain
observable but are not canonical completion paths. Without explicit stability
levels, host projects can depend on internals that later need to change.

### R5 — Persisted schema dispersion (medium)

Typed value classes exist for several domains, but the JSON/save boundary still
uses nested Dictionaries whose validators and defaults live in different
providers. Every new field risks inconsistent in-memory, JSON and restore
behavior.

### R6 — Architecture is protected mainly by behavioral tests (medium)

The suite proves many scenarios, but there are few static fitness checks for
dependency direction, public API inventory, one-Director composition or DSL
documentation completeness. Architectural drift is found late in CR.

## Recommended evolution

### Phase A — make boundaries explicit without changing behavior

1. Add a versioned public API inventory covering DSL, config, Facade, documented
   signals, resource schemas and save schema versions.
2. Add Architecture Decision Records for the single Director, typed receipts,
   SignalBus compatibility role, save projection and native-extension policy.
3. Add static fitness tests:
   - Core cannot import concrete Presenter scripts/scenes;
   - only Runtime constructs/configures the Director and registrar authorities;
   - every registered handler has parser/contract documentation coverage;
   - compatibility signals cannot settle built-in typed requests.
4. Extract shared tokenizer, option and source-diagnostic helpers from the
   parser before adding more command-specific quoting rules.

### Phase B — extract coordinators behind the existing Facade

Keep `StellaRuntime` as the public Autoload, but delegate cohesive state to
Runtime-owned services:

- `RuntimeComposition` — construction and registration only;
- `NavigationCoordinator` — scenario/scene handoff and generation ownership;
- `ActionCoordinator` — action catalog, confirmation and Presenter bindings;
- `SaveLoadCoordinator` — preflight and provider transaction ordering;
- `ChoiceSessionCoordinator` — choice/Auto suspension lifecycle.

Extraction must be mechanical: no new Autoload, scheduler, signal bus or public
API. Each service is created by Runtime and receives explicit dependencies.

### Phase C — split protocols by channel

Move per-channel validation/rollback/apply policy out of the Director's central
type switch into typed channel adapters. The Director should retain only batch
ownership, ordering, receipt accounting and cancellation. Likewise, move
SignalBus participant/queue mechanics into internal typed ports while keeping
documented public signals as adapters.

### Phase D — modularize grammar

Keep one public `DslParser.parse()` entry, but delegate command parsing to
closed command grammar modules that share one tokenizer/diagnostic API. Block
parsing (`@if`, `@combine`, presentation batch) remains in the structural
parser. A grammar module returns typed canonical data; it never mutates runtime
state or registers handlers.

## Explicit non-goals

- no rewrite of ScenarioEngine or conversion to ECS;
- no second Runtime/Director for audio, movies or project-specific content;
- no legacy/KAG compatibility grammar unless accepted as a Stella public DSL;
- no encoding character/stage state into background operations;
- no arbitrary sleeps, polling or wall-clock coordination;
- no native layer that owns a separate story or presentation scheduler;
- no mass API break while extracting internal services.

## Decision checklist

The current architecture is reasonable to continue if the project agrees to:

- preserve single-owner typed lifecycle semantics;
- stop adding large feature state machines directly to the Autoloads/parser;
- distinguish public, compatibility and internal APIs;
- treat save schema and DSL as versioned products;
- require engine fixes for remake gaps instead of compatibility workarounds.

If these constraints are rejected, feature delivery may remain fast in the
short term but CR, same-process testing and lifecycle debugging costs will keep
growing. The recommended choice is **evolutionary modularization, not a rewrite**.
