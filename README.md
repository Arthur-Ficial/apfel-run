# apfel-run

> **Wrangler for [apfel](https://github.com/Arthur-Ficial/apfel).** One TOML file manages every apfel setting - MCPs, system prompts, server flags, context strategy, tokens. Multiple profiles, schema validation, drop-in for `apfel`.

[![Latest Release](https://img.shields.io/github/v/release/Arthur-Ficial/apfel-run?label=latest&color=0066cc)](https://github.com/Arthur-Ficial/apfel-run/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![288 tests](https://img.shields.io/badge/tests-288%20green-brightgreen.svg)](Tests/ApfelRunCoreTests)

---

## Contents

- [TL;DR](#tldr)
- [Install](#install)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Where the config file lives (XDG cascade)](#where-the-config-file-lives)
- [Profiles](#profiles)
- [Subcommands reference](#subcommands-reference)
- [Config schema (short)](#config-schema-short)
- [Secrets posture](#secrets-posture)
- [Using apfel-run as a drop-in for apfel](#using-apfel-run-as-a-drop-in-for-apfel)
- [Precedence](#precedence)
- [Migration from v0.1](#migration-from-v01)
- [Testing story](#testing-story)
- [Development](#development)
- [Related](#related)
- [License](#license)

---

## TL;DR

```bash
brew install Arthur-Ficial/tap/apfel-run
apfel-run config init
$EDITOR ~/.config/apfel/config.toml
apfel-run                                      # apfel, configured from your TOML
apfel-run config path --all                    # see the full cascade
```

## Install

### Homebrew (recommended)

```bash
brew install Arthur-Ficial/tap/apfel Arthur-Ficial/tap/apfel-run
```

### From source

```bash
git clone https://github.com/Arthur-Ficial/apfel-run.git
cd apfel-run
make install        # builds release, installs to /usr/local/bin
```

**Requires:** macOS 13+, Swift 6 toolchain (Xcode Command Line Tools). `apfel` itself must be installed separately (it's what apfel-run wraps).

## Quick start

### 1. Generate a starter config

```bash
apfel-run config init
# wrote starter config to ~/.config/apfel/config.toml
# next: $EDITOR ~/.config/apfel/config.toml
```

### 2. Edit it

```toml
# ~/.config/apfel/config.toml
[profile.default]
system_prompt = "You are concise."

[profile.default.generation]
temperature = 0.3
max_tokens = 500

[[profile.default.mcp.server]]
path = "/opt/homebrew/bin/apfel-mcp-url-fetch"
```

### 3. Run apfel through the wrapper

```bash
apfel-run "what is 42 * 137?"
apfel-run --serve --port 11500                 # any apfel flag still works
apfel-run config show --format flags           # see exact argv apfel-run will produce
```

## How it works

```
$EDITOR config.toml          ─┐
                              ├─→ apfel-run                 ─┐
$APFEL_* env vars            ─┤       │                       │
                              │       ▼                       ▼
CLI flags you pass           ─┘   build argv + env        execve apfel
                                                              │
                                                              ▼
                                                     apfel runs as usual
```

- apfel-run reads your config file (XDG cascade, first hit wins)
- Resolves the active profile (`--profile`, `APFEL_RUN_PROFILE`, or `default`)
- Translates every profile field into the equivalent apfel CLI flag or `APFEL_*` env var
- Appends any CLI args you passed (so your flags always override the profile)
- `execve`s apfel - no parent process remains; signals + exit codes pass straight through

apfel itself stays a pure UNIX CLI with zero config file of its own. apfel-run is the (optional) stateful layer on top.

## Where the config file lives

**Fully configurable.** apfel-run follows the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/) - the same cascade used by `git`, `ssh`, `kubectl`, Vim, Neovim, and most modern CLIs on Linux and macOS.

### The cascade (first hit wins, no merging)

| # | Location | Selected via | Typical use |
|---|---|---|---|
| 1 | Any file path | `$APFEL_RUN_CONFIG=/path/to/file.toml` | One-off runs, CI, tests. Bypasses discovery entirely. |
| 2 | `./apfel.toml` or `./apfel.json` | current directory | **Project-local** - commit to git for team-shared configs. |
| 3 | `$XDG_CONFIG_HOME/apfel/config.{toml,json}` | `$XDG_CONFIG_HOME` env | **User config (XDG-explicit).** This is where `apfel-run config init` writes when `XDG_CONFIG_HOME` is set. |
| 4 | `~/.config/apfel/config.{toml,json}` | (XDG default when `$XDG_CONFIG_HOME` unset) | **User config (default).** The normal place. |
| 5 | `$XDG_CONFIG_DIRS/apfel/config.{toml,json}` | `$XDG_CONFIG_DIRS=/a:/b:/c` env | **System config.** Colon-separated list (first entry wins within this tier). Default `/etc/xdg`. For multi-user machines or packaged defaults. |
| 6 | `~/.config/apfel/mcps.conf` | (legacy v0.1) | Read automatically if nothing above exists. Removed in v0.3. Use `apfel-run migrate-config` to convert. |

If `.toml` and `.json` both exist in the same tier, **`.toml` wins**.

### Inspecting the cascade on your machine

```bash
apfel-run config path            # prints the ACTIVE config file path (empty if none)
apfel-run config path --all      # prints EVERY path the loader tries, with markers
```

Example `config path --all` output:

```
apfel-run config search path (first hit wins):
  [ ] /proj/apfel.toml
  [ ] /proj/apfel.json
  [x] /Users/me/.config/apfel/config.toml
  [ ] /Users/me/.config/apfel/config.json
  [ ] /etc/xdg/apfel/config.toml
  [ ] /etc/xdg/apfel/config.json
  [ ] /Users/me/.config/apfel/mcps.conf

Legend: [x] loaded, [-] exists but not loaded, [ ] does not exist
Active: /Users/me/.config/apfel/config.toml  (source: globalHome)
```

### Common questions

| Question | Answer |
|---|---|
| Where does `config init` write by default? | `$XDG_CONFIG_HOME/apfel/config.toml` (falls back to `~/.config/apfel/config.toml`) |
| Can I put the file anywhere? | Yes - `APFEL_RUN_CONFIG=/anywhere/file.toml apfel-run ...` |
| Can I commit it to git? | Yes - drop `./apfel.toml` in the project root |
| Can I use JSON instead of TOML? | Yes - same schema, `.json` extension. If both exist in the same tier, `.toml` wins. |
| Where do I put a machine-wide default? | `/etc/xdg/apfel/config.toml` (default `XDG_CONFIG_DIRS`) |
| Disable the config entirely for one call? | `APFEL_RUN_CONFIG=/dev/null apfel-run ...` |
| Legacy `mcps.conf` still works? | Yes (v0.2). Run `apfel-run migrate-config` when you have time. |

## Profiles

`[profile.NAME]` blocks are **fully independent** - no inheritance between profiles (we adopt the AWS CLI pattern, not Wrangler's selective cascade). Pick one at runtime:

- `apfel-run --profile NAME ...`
- `apfel-run -p NAME ...`
- `APFEL_RUN_PROFILE=NAME apfel-run ...`

If none given, `[profile.default]` is used.

```toml
[profile.default]
mode = "single"

[profile.chat]
mode = "chat"
system_prompt = "You are a friendly assistant."
[profile.chat.context]
strategy = "sliding-window"
max_turns = 12

[profile.serve]
mode = "serve"
[profile.serve.server]
port = 11434
token_auto = true
allowed_origins = ["https://myapp.example.com"]

[profile.research]
system_prompt = "Ground every answer in real sources."
[[profile.research.mcp.server]]
path = "/opt/homebrew/bin/apfel-mcp-ddg-search"
[[profile.research.mcp.server]]
path = "/opt/homebrew/bin/apfel-mcp-url-fetch"
[[profile.research.mcp.server]]
path = "/opt/homebrew/bin/apfel-mcp-search-and-fetch"
```

```bash
apfel-run "default profile run"
apfel-run -p chat                              # enter interactive chat
apfel-run -p serve &                           # background HTTP server
apfel-run -p research "summarise apfel.franzai.com"
```

## Subcommands reference

| Command | What it does |
|---|---|
| `apfel-run config show [--format toml\|json\|flags] [--profile NAME]` | Print current config. `flags` shows the exact argv+env apfel-run will produce - invaluable for debugging. |
| `apfel-run config path` | Print the currently-active config file path (empty if none). |
| `apfel-run config path --all` | Print the full cascade with `[x] / [-] / [ ]` markers. |
| `apfel-run config validate` | Schema + range + cross-field checks. Exit 1 with profile-scoped errors if broken. CI-ready. |
| `apfel-run config profiles` | List profile names, one per line. Sorted alphabetically. |
| `apfel-run config init [PATH]` | Write a commented starter config. Default: `~/.config/apfel/config.toml`. Refuses to overwrite. |
| `apfel-run config edit` | Open the active config in `$EDITOR` (defaults to `vi`). |
| `apfel-run migrate-config` | v0.1 → v0.2: read legacy `~/.config/apfel/mcps.conf`, write `config.toml`, rename legacy to `.v0.1.bak`. |

## Config schema (short)

Full reference: [docs/config-reference.md](docs/config-reference.md).

| Section | Fields |
|---|---|
| `[profile.NAME]` | `mode`, `system_prompt`, `system_prompt_file`, `files`, `output_format`, `quiet`, `no_color`, `debug`, `permissive` |
| `[profile.NAME.generation]` | `temperature`, `seed`, `max_tokens`, `retry` |
| `[profile.NAME.context]` | `strategy`, `max_turns`, `output_reserve` |
| `[profile.NAME.server]` | `port`, `host`, `cors`, `max_concurrent`, `allowed_origins`, `token_auto`, `token_env`, `public_health`, `origin_check`, `footgun` |
| `[profile.NAME.mcp]` | `timeout_seconds`, `token_env` |
| `[[profile.NAME.mcp.server]]` | `path`, `enabled`, `token_env` |

Every key maps to an apfel CLI flag or `APFEL_*` env var. `apfel-run config show --format flags` prints the exact mapping for a given profile.

### JSON alternate

Same schema, JSON extension. Exchangeable.

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

## Secrets posture

**Never put raw tokens in the file.** Use `token_env` to name an environment variable that is read at runtime:

```toml
[profile.default.server]
token_env = "MY_APFEL_SERVER_TOKEN"        # reads $MY_APFEL_SERVER_TOKEN at startup

[profile.default.mcp]
token_env = "MY_MCP_BEARER"                # shared fallback for remote MCPs

[[profile.default.mcp.server]]
path = "https://tools.example.com/mcp"
token_env = "MY_TOOLS_TOKEN"               # per-server override
```

Safety rails:

- `apfel-run config validate` refuses files that contain a raw `token = "..."` field and points at `token_env` instead.
- `apfel-run config show --format flags` redacts any env var whose name contains "token" (case-insensitive).
- Tokens never appear in `ps aux` - they are set in the child process's environment, not passed as CLI args.

## Using apfel-run as a drop-in for apfel

Every apfel flag forwards verbatim, at every position. You can replace your `apfel` alias entirely:

```bash
alias apfel=apfel-run
```

Now every `apfel` invocation picks up your `config.toml`. A few specifics:

- `apfel-run --serve --port 11434` → profile's server settings + your CLI `--port` wins
- `apfel-run -p dev` → switch profile
- `apfel-run -- --help` → escape hatch: show apfel's own `--help` (not apfel-run's)
- `apfel-run config show` → first positional is `config`, so apfel-run intercepts - use `apfel-run -- config` to forward the literal word to apfel

apfel-run's own flags (`--help`, `-h`, `--version`, `-v`, `--profile`, `-p`, plus `config` / `migrate-config` subcommands) are the **only** tokens it ever intercepts. Everything else goes to apfel untouched. A parameterised test suite (`ApfelFlagCollisionTests`) covers every apfel flag to guard this contract.

## Precedence

Lowest to highest:

1. apfel's built-in defaults
2. `APFEL_*` environment variables (apfel reads these directly)
3. The active profile from `config.toml`
4. CLI flags you pass to apfel-run **(always win)**

Example: profile sets `port = 11434`, you run `apfel-run -p serve --port 11500`, apfel ends up with `--port 11434 --port 11500` and picks the last (11500).

## Migration from v0.1

v0.1 used a line-based `mcps.conf`. v0.2 uses TOML (or JSON). One command converts:

```bash
apfel-run migrate-config
```

Reads `~/.config/apfel/mcps.conf`, writes `~/.config/apfel/config.toml`, renames the legacy file to `.v0.1.bak`. Idempotent - re-running it just reports no legacy file.

The legacy `mcps.conf` is still read as a fallback in v0.2 if no TOML/JSON exists. **v0.3 removes the fallback** - migrate at your convenience before then.

## Testing story

**288 tests, all green** - hardcore:

| Layer | Count | What it covers |
|---|---|---|
| Schema | 15 | Codable round-trips, enum membership, snake_case keys |
| Validator | 18 + 6 | Every range check, mutual-exclusion rule, HTTPS+token combo |
| Loader | 9 + 9 XDG | Full XDG cascade including `XDG_CONFIG_DIRS`, permission errors, legacy fallback |
| Profile resolver | 8 + 7 | Typo suggestions (Levenshtein), case sensitivity, empty env |
| Flag builder | 35 + 7 | Every config field → apfel flag mapping, determinism, user-arg override |
| TOML/JSON coders | 10 | Round-trip in both formats, cross-format (TOML → JSON → TOML) |
| Planner v2 | 16 + 6 | Subcommand detection, profile extraction, collision-safe passthrough |
| Subcommands | 16 + 4 | Every subcommand path, including `config path --all` |
| Collision coverage | 4 suites | Every apfel v1.0.5 flag forwards cleanly |
| Integration (real binary) | 16 + 12 | Runs the release binary as a subprocess, asserts output |
| Real MCP matrix | 8 + 4 | Real apfel + real MCP servers (calculator, url-fetch, ddg-search, search-and-fetch). Gated on `APFEL_RUN_MCP_MATRIX=1`. |
| Stress + large configs | 3 | 50 profiles × 20 MCPs, 100 MCPs in one env var |
| Determinism | 3 | Same inputs → byte-identical output |

Run the lot:

```bash
swift test                                 # 280 unit + integration (no model required)
APFEL_RUN_MCP_MATRIX=1 swift test          # + 8 real-MCP tests (needs Apple Intelligence)
```

## Development

```bash
swift build -c release
swift test                                 # fast, model-free
APFEL_RUN_MCP_MATRIX=1 swift test          # full, with real apfel + MCPs
make install                               # /usr/local/bin/apfel-run
make uninstall
```

### Adding a feature

Flow, no exceptions:

1. Write the failing test in `Tests/ApfelRunCoreTests/` using `@Test`
2. Watch it fail for the right reason
3. Minimum code in `Sources/ApfelRunCore/` to make it pass
4. `swift test` green
5. If user-visible, update `README.md`, `--help` in `Runner.swift`'s `Formatter.helpText` (or `main.swift`'s `helpText()`), and `docs/config-reference.md`

### Adding a new apfel flag

If apfel ships a new CLI flag, you have two touch points:

1. Add it to `ApfelFlagCollisionTests.apfelFlags` so the collision-safety test suite knows about it
2. If it should be configurable via `config.toml`, wire it into `FlagBuilder.build` + add a Codable field + add a validator check + update docs

## Related

- [apfel](https://github.com/Arthur-Ficial/apfel) - the on-device AI engine (100% local, no API keys, Apple Intelligence)
- [apfel-mcp](https://github.com/Arthur-Ficial/apfel-mcp) - ready-to-use MCPs: `url-fetch`, `ddg-search`, `search-and-fetch`. Drop them into a `[[profile.X.mcp.server]]` entry and go.
- [apfel-chat](https://github.com/Arthur-Ficial/apfel-chat), [apfel-quick](https://github.com/Arthur-Ficial/apfel-quick), [apfel-clip](https://github.com/Arthur-Ficial/apfel-clip) - GUI surfaces that speak HTTP to apfel
- [ohr](https://github.com/Arthur-Ficial/ohr) - on-device speech-to-text companion

## License

MIT. See [LICENSE](LICENSE).
