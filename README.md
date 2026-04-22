# apfel-run

**Wrangler for [apfel](https://github.com/Arthur-Ficial/apfel).** One TOML file manages every apfel setting - MCPs, system prompts, server flags, context strategy, tokens. Edit once, forget.

[![Latest Release](https://img.shields.io/github/v/release/Arthur-Ficial/apfel-run?label=latest&color=0066cc)](https://github.com/Arthur-Ficial/apfel-run/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)

---

```bash
brew install Arthur-Ficial/tap/apfel-run
apfel-run config init
$EDITOR ~/.config/apfel/config.toml
apfel-run                    # apfel, but with your whole config applied
```

## Install

```bash
brew install Arthur-Ficial/tap/apfel Arthur-Ficial/tap/apfel-run
```

Or from source:

```bash
git clone https://github.com/Arthur-Ficial/apfel-run.git
cd apfel-run
make install              # builds release, installs to /usr/local/bin
```

## Drop-in for apfel

Every apfel flag forwards verbatim. Add `alias apfel=apfel-run` to your shell config and nothing changes - until you edit `config.toml`, at which point every `apfel` invocation picks up your settings:

```bash
alias apfel=apfel-run

apfel "what is 42 * 137?"                     # prompt
apfel --serve --port 11434                    # server mode
apfel --chat --stream                         # streaming chat
apfel -p research "summarise this page"       # switch profile
apfel -- --help                               # apfel's own help (escape hatch)
```

198 tests cover the behaviour: 174 unit + 16 CLI integration + 8 real-MCP matrix against calculator, url-fetch, ddg-search, search-and-fetch.

## Quick start

### 1. Generate a starter config

```bash
apfel-run config init
# wrote starter config to ~/.config/apfel/config.toml
```

### 2. Edit it

```bash
apfel-run config edit        # opens $EDITOR
```

Or directly:

```toml
# ~/.config/apfel/config.toml
[profile.default]
system_prompt = "You are concise."

[profile.default.generation]
temperature = 0.3
max_tokens = 500

[[profile.default.mcp.server]]
path = "/Users/me/mcp/calc.py"

[[profile.default.mcp.server]]
path = "https://tools.example.com/mcp"
enabled = false                # comment out easily
```

### 3. Run apfel

```bash
apfel-run "what is 42 * 137?"
# apfel-run passes system_prompt, temperature, max_tokens, MCPs into apfel for you
```

### 4. Inspect

```bash
apfel-run config show           # canonical TOML output
apfel-run config show --format flags   # see the exact apfel argv produced
apfel-run config validate       # schema + range checks
apfel-run config profiles       # list profiles
```

## Profiles

`[profile.NAME]` blocks are fully independent. Pick one with `-p NAME` or `--profile NAME` or the `APFEL_RUN_PROFILE` env var. No inheritance between profiles - each is a complete, boring, predictable config.

```toml
[profile.default]
mode = "single"

[profile.chat]
mode = "chat"
system_prompt = "You are a friendly helpful assistant."
[profile.chat.context]
strategy = "sliding-window"
max_turns = 12

[profile.serve]
mode = "serve"
[profile.serve.server]
port = 11434
token_auto = true
[[profile.serve.mcp.server]]
path = "/opt/homebrew/bin/apfel-mcp-url-fetch"

[profile.research]
system_prompt = "You are a research assistant."
[[profile.research.mcp.server]]
path = "/opt/homebrew/bin/apfel-mcp-ddg-search"
[[profile.research.mcp.server]]
path = "/opt/homebrew/bin/apfel-mcp-url-fetch"
[[profile.research.mcp.server]]
path = "/opt/homebrew/bin/apfel-mcp-search-and-fetch"
```

```bash
apfel-run "default profile"
apfel-run -p chat              # interactive chat
apfel-run -p serve &           # start server
apfel-run -p research "find and summarise the apfel README"
```

## Subcommands

| Command | What it does |
|---|---|
| `apfel-run config show [--format toml\|json\|flags] [-p NAME]` | Print current config in the chosen format. `flags` shows the exact apfel argv+env apfel-run would produce - great for debugging. |
| `apfel-run config path` | Print the discovered config file path (empty if none). |
| `apfel-run config validate` | Schema + range + cross-field validation. Exit 1 if broken, with profile-scoped error messages. CI-ready. |
| `apfel-run config profiles` | List profile names, one per line. |
| `apfel-run config init [PATH]` | Write a commented starter config. Refuses to overwrite. |
| `apfel-run config edit` | Open the config in `$EDITOR` (vi by default). |
| `apfel-run migrate-config` | v0.1 → v0.2: read legacy `~/.config/apfel/mcps.conf`, write `config.toml`, rename legacy to `.v0.1.bak`. |

## File discovery (first hit wins)

1. `$APFEL_RUN_CONFIG` - explicit override, full path
2. `./apfel.toml` or `./apfel.json` - project-local (committable, team-shareable)
3. `$XDG_CONFIG_HOME/apfel/config.{toml,json}`
4. `~/.config/apfel/config.{toml,json}`
5. `~/.config/apfel/mcps.conf` - legacy v0.1 fallback (run `apfel-run migrate-config`)

## JSON mirror

Every TOML key has a JSON equivalent. Same schema, same names, exchangeable:

```json
{
  "profile": {
    "default": {
      "system_prompt": "be terse",
      "generation": { "temperature": 0.3, "max_tokens": 500 },
      "mcp": {
        "server": [
          { "path": "/Users/me/mcp/calc.py", "enabled": true }
        ]
      }
    }
  }
}
```

`apfel-run config show --format json` round-trips losslessly. If both `apfel.toml` and `apfel.json` exist in the same directory, TOML wins.

## Precedence (lowest to highest)

1. apfel built-in defaults
2. `APFEL_*` env vars (apfel itself reads these)
3. `[profile.ACTIVE]` values from your config
4. CLI flags you pass to apfel-run (always win)

So `apfel-run -p serve --port 11500` uses the `serve` profile but overrides the port.

## Secrets

Never put raw tokens in the file. Use `token_env`:

```toml
[profile.default.server]
token_env = "MY_APFEL_SERVER_TOKEN"        # reads env at runtime

[profile.default.mcp]
token_env = "MY_MCP_BEARER"

[[profile.default.mcp.server]]
path = "https://tools.example.com/mcp"
token_env = "MY_TOOLS_TOKEN"               # per-server override
```

`apfel-run config validate` refuses files that contain a raw `token = "..."` and `apfel-run config show --format flags` redacts any env var whose name contains `token`.

## How apfel-run composes with apfel

```
$EDITOR config.toml          ─┐
                              ├─→ apfel-run                 ─┐
$APFEL_* env vars            ─┤       │                       │
                              │       ▼                       ▼
CLI flags to apfel-run       ─┘   build argv+env         execve apfel
                                                              │
                                                              ▼
                                                     apfel runs as usual
```

apfel-run uses `execve`, not `Process` - so there's no parent in `ps aux`, signals and exit codes pass straight through, and `apfel-run` is invisible at runtime.

## Migration from v0.1

v0.1 used a line-based `mcps.conf`. v0.2 uses TOML/JSON. Run:

```bash
apfel-run migrate-config
# migrated:
#   from: ~/.config/apfel/mcps.conf   (renamed to .v0.1.bak)
#   to:   ~/.config/apfel/config.toml
```

The legacy `mcps.conf` is still read automatically as a fallback if no `config.toml` exists. That fallback will be removed in v0.3.

## Complete schema

See [docs/config-reference.md](docs/config-reference.md) for every field, type, and its apfel equivalent. The short version:

| Section | Fields |
|---|---|
| `[profile.NAME]` | `mode`, `system_prompt`, `system_prompt_file`, `files`, `output_format`, `quiet`, `no_color`, `debug`, `permissive` |
| `[profile.NAME.generation]` | `temperature`, `seed`, `max_tokens`, `retry` |
| `[profile.NAME.context]` | `strategy`, `max_turns`, `output_reserve` |
| `[profile.NAME.server]` | `port`, `host`, `cors`, `max_concurrent`, `allowed_origins`, `token_auto`, `token_env`, `public_health`, `origin_check`, `footgun` |
| `[profile.NAME.mcp]` | `timeout_seconds`, `token_env` |
| `[[profile.NAME.mcp.server]]` | `path`, `enabled`, `token_env` |

## Design

apfel stays a pure UNIX CLI - no config files of its own. apfel-run is the stateful layer: it reads config, builds apfel's argv+env, and `execve`s apfel. This keeps apfel small (easy to test, easy to reason about) and puts all configuration concerns in one place.

See [docs/DESIGN.md](docs/DESIGN.md) for the deeper "why line-based? why execve? why no inheritance?" rationale.

## Development

```bash
swift test                              # 174 unit + 16 integration = 190 tests
APFEL_RUN_MCP_MATRIX=1 swift test       # + 8 real MCP tests (needs Apple Intelligence)
swift build -c release
make install                            # /usr/local/bin/apfel-run
make uninstall
```

When adding features, write the failing test first in `Tests/ApfelRunCoreTests/`, make it green with minimal code in `Sources/ApfelRunCore/`, update `--help` text and this README.

If apfel ships a new CLI flag, add it to `ApfelFlagCollisionTests.apfelFlags` in the test file AND wire it into `FlagBuilder.build` if it's configurable via `config.toml`.

## License

MIT. See [LICENSE](LICENSE).

## Related

- [apfel](https://github.com/Arthur-Ficial/apfel) - the on-device AI engine (100% local, no API keys)
- [apfel-mcp](https://github.com/Arthur-Ficial/apfel-mcp) - url-fetch, ddg-search, search-and-fetch - token-budget-optimised MCPs ready to drop into a `[[profile.X.mcp.server]]` entry
- [apfel-chat](https://github.com/Arthur-Ficial/apfel-chat), [apfel-quick](https://github.com/Arthur-Ficial/apfel-quick), [apfel-clip](https://github.com/Arthur-Ficial/apfel-clip) - GUI tools built on apfel
