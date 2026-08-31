# Stella agent compatibility entry

The repository has one authoritative agent guide: [AGENTS.md](AGENTS.md).

Read and follow `AGENTS.md` in full before changing this repository. This file
exists only for tools that discover `CLAUDE.md`; it does not define a second
workflow, architecture, testing policy, model requirement, authorship rule or
merge authority.

The public technical documents have distinct roles:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — runtime ownership and data flow
- [docs/ARCHITECTURE_REVIEW.md](docs/ARCHITECTURE_REVIEW.md) — risks and roadmap
- [docs/DSL.md](docs/DSL.md) — canonical authored grammar
- [docs/USAGE.md](docs/USAGE.md) — supported project integration
- [docs/INPUT_DESIGN.md](docs/INPUT_DESIGN.md) — input ownership

If any instruction cached by a tool conflicts with `AGENTS.md`, `AGENTS.md`
wins unless the user or a higher-priority instruction explicitly says otherwise.
