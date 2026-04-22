# apfel-run

**A tiny UNIX wrapper that gives [apfel](https://github.com/Arthur-Ficial/apfel) a persistent MCP registry with enable/disable semantics.**

apfel already reads an `APFEL_MCP` environment variable - colon/comma-separated list of MCP server paths. That covers the "set once, forget" case perfectly. `apfel-run` sits one layer up: a plain text config file where you list all your MCPs and flip them on or off by commenting/uncommenting a line, the same way `~/.ssh/config` and `~/.gitconfig` work.

No new flags in apfel. No bespoke config format. apfel stays small, apfel-run stays <300 lines, your MCPs live in a file you can `grep` and `$EDITOR`.

## Use it exactly like you use apfel

`apfel-run` is a drop-in for the `apfel` binary. Every apfel flag and every apfel prompt forwards through unchanged - the only things it adds are `--list`, `--config-path`, its own `--help`/`--version`, and the registry behaviour. You can `alias apfel=apfel-run` in your shell config and nothing else changes.

```bash
apfel-run "what is 42 * 137?"                     # prompt
apfel-run --serve --port 11434 --token-auto       # server mode
apfel-run --chat --stream                         # streaming chat
apfel-run --mcp ./extra.py "..."                  # ad-hoc MCP stacks on registry
apfel-run --model-info                            # diagnostics
apfel-run -- --help                               # apfel's own --help (when you need it)
```

47 unit tests cover the passthrough surface, including a parameterised collision test across **every flag apfel defines** (102 cases), so we catch any new apfel flag the day it ships.

## Install

```bash
make install                      # /usr/local/bin/apfel-run
```

Homebrew tap: coming once the first tagged release is cut.

## Quick start

```bash
# 1. Create the config
mkdir -p ~/.config/apfel
$EDITOR ~/.config/apfel/mcps.conf

# 2. Add one MCP per line
cat > ~/.config/apfel/mcps.conf <<'EOF'
# my apfel MCP registry
/Users/me/mcp/calc.py
/Users/me/mcp/web.py
-/Users/me/mcp/filesystem.py   # disabled for now
https://tools.example.com/mcp
EOF

# 3. Run apfel through the wrapper
apfel-run "what is 42 * 137?"
apfel-run --stream "summarise ~/Downloads"

# 4. See what's enabled
apfel-run --list
```

## The config format

One MCP per line. Four rules:

1. Blank lines ignored.
2. `#` starts a comment (whole line or trailing).
3. A line starting with `-` is a **disabled** MCP - prefix removes the entry from `APFEL_MCP` without deleting your copy of the path.
4. Everything else is an **enabled** MCP.

That's it. You edit the file, run `apfel-run`.

### Example

```
# Personal registry - last edited 2026-04-22

# Always on
/Users/me/mcp/calc.py
/Users/me/mcp/web-fetch.py

# Work-only - kept here for convenience, disabled by default
-/Users/me/mcp/corp-search.py    # needs VPN

# Remote MCPs
https://tools.example.com/mcp
```

## What apfel-run does

1. Reads the config (default: `~/.config/apfel/mcps.conf`, respects `$XDG_CONFIG_HOME`, overridable with `$APFEL_RUN_CONFIG`).
2. Builds `APFEL_MCP=<enabled,paths,comma-separated>`.
3. If you already set `APFEL_MCP` in your shell, the shell value is *prepended* so ad-hoc overrides still work.
4. `execve`s `apfel` with your arguments. apfel-run leaves no parent process - signals and exit codes pass straight through.

## Subcommands / flags

| Flag | Behaviour |
|---|---|
| *(no flag)* | Run apfel with enabled MCPs + any args you pass |
| `--list` | Print the registry with `[x]` / `[ ]` markers and counts |
| `--config-path` | Print the effective config file path and exit |
| `--version`, `-v` | Print version |
| `--help`, `-h` | Print help |
| `--` | Forward everything after `--` to apfel verbatim (use when your apfel args would collide with apfel-run flags, e.g. `apfel-run -- --help`) |

## How this composes with apfel

| You want... | Use |
|---|---|
| One-off prompt with all registered MCPs | `apfel-run "..."` |
| One-off prompt with just one MCP, ignoring config | `env APFEL_MCP=/just-one.py apfel "..."` |
| Registered MCPs + an extra one-off | `APFEL_MCP=/extra.py apfel-run "..."` (apfel-run merges them) |
| Disable everything for a single call | `APFEL_RUN_CONFIG=/dev/null apfel-run "..."` |
| Just use apfel directly, no wrapper | `apfel "..."` (apfel-run changes nothing about raw apfel) |

## Why a separate tool instead of baking this into apfel?

Because **apfel is a UNIX tool first**, and the UNIX way is env vars + flags (like `git`, `ssh`, `kubectl`). Adding a config file inside apfel itself would create apfel-specific state that other tools would have to learn about, and would drag apfel toward being a "framework" rather than a "program".

apfel-run is the right shape for "I want a small registry I can edit": it's a 50-line `execve` wrapper, it's MIT, it reads a text file, and if you don't like it you can replace it with a 10-line shell alias.

See [docs/DESIGN.md](docs/DESIGN.md) for the longer design rationale.

## Development

```bash
swift build           # debug build
swift test            # run tests
make install          # install release binary to /usr/local/bin
```

## License

MIT - see [LICENSE](LICENSE).

## Related

- [apfel](https://github.com/Arthur-Ficial/apfel) - the on-device AI engine
- [apfel-mcp](https://github.com/Arthur-Ficial/apfel-mcp) - token-budget-optimized MCP servers for apfel
- [apfel-chat](https://github.com/Arthur-Ficial/apfel-chat), [apfel-quick](https://github.com/Arthur-Ficial/apfel-quick), [apfel-clip](https://github.com/Arthur-Ficial/apfel-clip) - family tools built on apfel
