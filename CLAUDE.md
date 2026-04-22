# apfel-run - Project Instructions

`apfel-run` is a tiny UNIX wrapper that gives [apfel](https://github.com/Arthur-Ficial/apfel) a persistent MCP registry with enable/disable semantics, via a plain text config file at `~/.config/apfel/mcps.conf`. It `execve`s apfel so it is invisible at runtime - signals and exit codes pass through cleanly.

## The Golden Goal

> **Make apfel usable with many MCPs at once without bloating apfel itself.**
>
> You should be able to `alias apfel=apfel-run` and forget apfel-run exists - until you want to add, disable, or review an MCP, at which point you `$EDITOR ~/.config/apfel/mcps.conf` or run `apfel-run --list`.

## Non-negotiable principles

1. **Drop-in for apfel.** Every apfel flag forwards unchanged. apfel-run's own flags (`--list`, `--config-path`, `--help`, `--version`) are intercepted ONLY as the first argument. `--help` / `-h` / `--version` / `-v` collide with apfel; user escapes with `-- --help`. Everything else forwards.
2. **Line-based config.** One MCP per line. Prefix `-` to disable. `#` comments. No TOML, no YAML, no JSON. Zero dependencies, grep-friendly, $EDITOR-friendly.
3. **`execve` not `Process`.** apfel-run becomes apfel. No parent in `ps aux`, no signal translation.
4. **Missing config = empty registry, not an error.** UNIX convention.
5. **Shell `APFEL_MCP` prepends to config.** Ad-hoc overrides beat registry, registry beats nothing.
6. **TDD with collision coverage.** Any new apfel flag must be added to the parameterised test list (`ApfelFlagCollisionTests.apfelFlags`). Tests fail the day apfel ships a flag we shadow by accident.
7. **KISS.** No `add`/`remove`/`toggle` sub-commands. No profiles. No package manager. No process supervisor. No GUI. Just: read file, set env, exec.

## Architecture

```
Sources/
├── ApfelRunCore/           ← pure library, unit-testable
│   ├── Config.swift        ← MCPEntry, Config, ConfigParser, ConfigPath
│   └── Runner.swift        ← RunPlan, Planner (positional flag interception), Formatter
└── apfel-run/
    └── main.swift          ← thin glue: read file, call Planner, execve

Tests/
└── ApfelRunCoreTests/
    └── ConfigTests.swift   ← 47 tests: parser, planner, formatter, apfel flag collision
```

## Build & Test

```bash
swift test                      # 47 tests (102 parameterised cases)
swift build -c release
make install                    # /usr/local/bin/apfel-run
make uninstall
```

## When adding / touching features

Flow for any change, no exceptions:

1. Write the failing test in `Tests/ApfelRunCoreTests/ConfigTests.swift` using swift-testing `@Test`.
2. Watch it fail for the right reason.
3. Minimal change in `Sources/ApfelRunCore/` to make it pass.
4. `swift test` green.
5. If the change affects semantics users see (flag meaning, merge order, config format), update `README.md`, `Sources/ApfelRunCore/Runner.swift`'s `Formatter.helpText`, and `docs/DESIGN.md`.

**Parser rules**: when you add a new parse rule (trailing comment, dash prefix, etc.), add a test per rule AND per interaction with other rules (dash + trailing comment, blank + comment, etc.).

**Collision coverage**: every new apfel flag observed in `apfel/Sources/CLI/CLIArguments.swift` must be added to `ApfelFlagCollisionTests.apfelFlags`. This is the contract that keeps apfel-run a true drop-in.

## Release

Single source of truth: `.version`. Local `make build` does NOT bump the version. Only the release workflow does (to be wired once homebrew-tap formula lands).

## What NOT to do

- Do NOT add sub-commands (`apfel-run add /path`, `apfel-run toggle ...`). `$EDITOR ~/.config/apfel/mcps.conf` is the management surface.
- Do NOT add per-profile config. apfel's `--mcp` flag is the per-call override.
- Do NOT parse `APFEL_MCP`'s colon-separated legacy form. apfel-run emits the comma form; apfel handles both.
- Do NOT manually edit `.version`.
- Do NOT add warnings for unknown apfel flags - that's apfel's job.

## Relationship to the family

- [apfel](https://github.com/Arthur-Ficial/apfel) - the engine. apfel-run never reimplements any of its logic.
- [apfel-mcp](https://github.com/Arthur-Ficial/apfel-mcp) - token-budget-optimized MCP servers. Natural content for `mcps.conf`.
- [apfel-quick](https://github.com/Arthur-Ficial/apfel-quick), [apfel-chat](https://github.com/Arthur-Ficial/apfel-chat), [apfel-clip](https://github.com/Arthur-Ficial/apfel-clip) - GUI surfaces. They talk to apfel's HTTP server; apfel-run is orthogonal to them.
