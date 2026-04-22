# apfel-run Config Reference

Complete reference for every key in `~/.config/apfel/config.toml` (or `apfel.toml` / `apfel.json`). Each key maps to a specific apfel CLI flag or env var.

## Top-level

```toml
[profile.NAME]
```

One or more profile blocks. `[profile.default]` is used when no `--profile NAME` / `-p NAME` / `APFEL_RUN_PROFILE=NAME` is set. Additional profiles are independent - no inheritance.

## `[profile.NAME]` - top-level settings

| Key | Type | Maps to | Default | Notes |
|---|---|---|---|---|
| `mode` | enum | `--serve`, `--chat`, `--stream`, `--benchmark`, `--model-info` | unset → single | `"single"`, `"stream"`, `"chat"`, `"serve"`, `"benchmark"`, `"model-info"` |
| `system_prompt` | string | `-s <value>` | nil | Mutually exclusive with `system_prompt_file` |
| `system_prompt_file` | string (path) | `--system-file <path>` | nil | Mutually exclusive with `system_prompt` |
| `files` | string[] | `--file <path>` (repeated) | `[]` | Prepends each file to the prompt, preserving order |
| `output_format` | enum | `--output <value>` | unset | `"plain"` or `"json"` |
| `quiet` | bool | `-q` | false | Suppresses tool info and chat header |
| `no_color` | bool | `--no-color` | false | Also respected: `NO_COLOR` env |
| `debug` | bool | `--debug` | false | Debug logs to stderr |
| `permissive` | bool | `--permissive` | false | Relaxed guardrails |

## `[profile.NAME.generation]`

| Key | Type | Maps to | Default | Notes |
|---|---|---|---|---|
| `temperature` | float ≥ 0 | `--temperature` | nil (apfel default) | |
| `seed` | int ≥ 0 | `--seed` | nil | Reproducibility seed |
| `max_tokens` | int ≥ 1 | `--max-tokens` | nil | Response cap |
| `retry` | int ≥ 0 | `--retry <N>` | 0 (disabled) | 0 omits the flag; N > 0 enables |

## `[profile.NAME.context]`

Mostly applies to `chat` mode.

| Key | Type | Maps to | Default | Notes |
|---|---|---|---|---|
| `strategy` | enum | `--context-strategy` | nil | `"newest-first"`, `"oldest-first"`, `"sliding-window"`, `"summarize"`, `"strict"` |
| `max_turns` | int ≥ 1 | `--context-max-turns` | nil | Only used with `sliding-window` |
| `output_reserve` | int ≥ 1 | `--context-output-reserve` | 512 (apfel default) | Tokens reserved for model output |

## `[profile.NAME.server]` - only applied when `mode = "serve"`

| Key | Type | Maps to | Default | Notes |
|---|---|---|---|---|
| `port` | int 1-65535 | `--port` | 11434 | |
| `host` | string | `--host` | `127.0.0.1` | Use `0.0.0.0` for network exposure |
| `cors` | bool | `--cors` | false | Enables CORS headers |
| `max_concurrent` | int ≥ 1 | `--max-concurrent` | 5 | Concurrent request cap |
| `allowed_origins` | string[] | `--allowed-origins` (repeated) | `[]` | |
| `token_auto` | bool | `--token-auto` | false | Generates a fresh UUID token per boot |
| `token_env` | string | sets `APFEL_TOKEN` env | nil | Reads the named env var at apfel-run startup. Never put the raw token in the config |
| `public_health` | bool | `--public-health` | false | Keep `/health` unauthenticated |
| `origin_check` | bool | `--no-origin-check` (when false) | true | |
| `footgun` | bool | `--footgun` | false | Disables CORS origin check AND enables CORS. Dev-only |

Precedence for token:
1. `token_auto = true` → apfel generates a fresh UUID. `token_env` ignored.
2. `token_env = "VAR"` → reads `$VAR` at runtime, sets `APFEL_TOKEN` env for apfel.
3. Neither → no token (unauthenticated server).

## `[profile.NAME.mcp]`

| Key | Type | Maps to | Default | Notes |
|---|---|---|---|---|
| `timeout_seconds` | int 1-300 | `APFEL_MCP_TIMEOUT` env | 5 (apfel default) | |
| `token_env` | string | `APFEL_MCP_TOKEN` env | nil | Fallback bearer token for remote MCPs |

## `[[profile.NAME.mcp.server]]` - array of tables

One entry per MCP server. Enabled entries are joined into `APFEL_MCP` env var (comma-separated); disabled entries are excluded but kept on disk for easy re-enabling.

| Key | Type | Maps to | Default | Notes |
|---|---|---|---|---|
| `path` | string | `APFEL_MCP` (joined) | **required** | Local path or URL (http/https). Paths must exist at runtime; URLs validated by apfel. |
| `enabled` | bool | (skipped if false) | true | Set false to disable without deleting |
| `token_env` | string | per-server auth override | nil | Reserved for future per-MCP auth |

## Precedence (lowest to highest)

1. Hardcoded apfel defaults
2. `APFEL_*` environment variables (apfel reads these directly)
3. Active profile from `config.toml`
4. CLI flags you pass to apfel-run

Example: profile says `port = 11434`, you run `apfel-run -p serve --port 11500` - apfel gets `--port 11434 --port 11500` and picks the last one (11500).

## File discovery (XDG Base Directory Spec)

First hit wins. No merging. Follows https://specifications.freedesktop.org/basedir-spec/latest/.

| # | Location | Source label |
|---|---|---|
| 1 | `$APFEL_RUN_CONFIG` (explicit full path) | `envOverride` |
| 2 | `./apfel.toml` or `./apfel.json` (project-local) | `projectLocal` |
| 3 | `$XDG_CONFIG_HOME/apfel/config.{toml,json}` | `globalXDG` |
| 4 | `~/.config/apfel/config.{toml,json}` (XDG default when `XDG_CONFIG_HOME` unset) | `globalHome` |
| 5 | `$XDG_CONFIG_DIRS/apfel/config.{toml,json}` (system config, default `/etc/xdg`) | `systemXDG` |
| 6 | `~/.config/apfel/mcps.conf` (legacy v0.1 grace; v0.3 removes) | `legacyMCPConf` |

### Details

- `$XDG_CONFIG_DIRS` is **colon-separated** - left-most directory wins within that layer. Example: `XDG_CONFIG_DIRS=/etc/apfel-overrides:/etc/xdg` searches `/etc/apfel-overrides/apfel/config.{toml,json}` first.
- When both `.toml` and `.json` exist in the same directory, `.toml` wins (documented in `LoaderTests`).
- An unreadable file in an early tier does NOT silently fall through - `apfel-run config validate` fails loud with the path. The execve path (`apfel-run --serve ...`) treats unreadable files as empty and proceeds, matching UNIX-convention "missing config is not an error" semantics.

### Inspecting the cascade

```bash
apfel-run config path           # active config file path, or empty if none loaded
apfel-run config path --all     # every path the loader tries, with status markers
```

`config path --all` marks each candidate:
- `[x]` - the file that got loaded
- `[-]` - the file exists on disk but was skipped (a higher-priority file won)
- `[ ]` - the file does not exist

### Why this layout

apfel-run uses the same cascade that `git`, `ssh`, `kubectl`, and every other modern UNIX CLI uses. You get:
- **Predictable overrides** - env var > project-local > user > system
- **Zero surprise** - the XDG spec is ~20 years old and documented everywhere
- **Composability** - per-user configs in `$HOME`, per-machine defaults in `/etc/xdg`, per-project overrides in the project root, per-run overrides via env

Raw "where does it write?" question: `apfel-run config init` writes to `$XDG_CONFIG_HOME/apfel/config.toml` (default `~/.config/apfel/config.toml`). You can override with `apfel-run config init /any/path.toml`.

## Validation errors

`apfel-run config validate` runs a schema check on the discovered config. Each error includes the profile name:

```
error [default]: server.port must be 1-65535 (got -1)
error [bad]: system_prompt and system_prompt_file are mutually exclusive
warning [default]: server.footgun is set but origin_check is also on
```

Exit 0 if only warnings; exit 1 if any errors.

## Env vars apfel-run itself reads

| Var | Purpose |
|---|---|
| `APFEL_RUN_CONFIG` | Explicit path to config file (overrides discovery) |
| `APFEL_RUN_PROFILE` | Profile name (overridden by `-p`/`--profile` CLI) |
| `APFEL_RUN_APFEL_BINARY` | Custom path to the `apfel` binary (default: `$PATH` lookup) |

apfel-run also inherits and passes through every `APFEL_*` env var to apfel, prepending any shell-set `APFEL_MCP` to the config-derived one so ad-hoc shell overrides still work.
