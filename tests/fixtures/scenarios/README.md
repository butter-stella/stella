# Scenario E2E fixtures

This directory contains synthetic, redistributable `.stla` scenarios used by
the integration tests. Each fixture exercises a public DSL feature through the
same parser, command handler, signal, and presenter path used by a game.

Fixtures may use `@wait click` as a deterministic inspection checkpoint. This
also keeps them runnable by hand in a debug build: advance once to continue to
the cleanup command, then advance again to finish the scenario.

Keep fixtures focused on one feature and free of private game content, assets,
or machine-specific paths.
