# apfel-run Design Notes

## The problem

apfel users with more than two MCPs repeat themselves on every invocation:

```bash
apfel --mcp ~/mcp/calc.py --mcp ~/mcp/web.py --mcp ~/mcp/fs.py "question"
```

apfel already accepts `APFEL_MCP=path,path,path` as an env var (documented in [apfel/STABILITY.md](https://github.com/Arthur-Ficial/apfel/blob/main/STABILITY.md#environment-variables)) so you can put `export APFEL_MCP=...` in `~/.zshrc` and be done. That covers the "set once, forget" case.

What it doesn't cover:

- **Temporarily disable one MCP** without losing the path (you'd have to hand-edit the env var).
- **Share a registry with colleagues** (comment-line form of shell state is not portable).
- **Introspect state** ("which MCPs are live right now?").

## The non-solution: a config file inside apfel

A config file inside apfel (`~/.config/apfel/config.toml`) would solve the above *and* couple apfel to TOML/YAML parsing, invent a new precedence system (config < env < flag), and create apfel-specific state that every downstream tool has to understand.

It also flunks the golden goal - apfel is a UNIX tool first. Adding a settings file is the "framework vs program" fork.

## The chosen shape

A separate 200-line wrapper that:

1. Reads a plain text file.
2. Builds `APFEL_MCP=...` from enabled lines.
3. `execve`s apfel.

That's it. apfel-run has no magic. It's a shell alias written in Swift.

### Why Swift, not Bash?

- **Testability** - parsing rules (line comments, trailing `#`, `-` prefix, whitespace handling) earn real unit tests. A 10-line bash alias can't express them cleanly.
- **Ecosystem fit** - the apfel family is all Swift + SwiftPM. One `swift build` pattern.
- **Same-shape distribution** - Homebrew formula, `.version` file, Makefile - reuses the rest of the family's release story.

The cost is a ~1MB binary vs a shell one-liner. Acceptable for what we get.

### Why `execve`, not `Process`?

So that apfel-run becomes apfel. No parent in `ps`, no signal translation, no extra exit-code handling. Your shell sees apfel exit. apfel-run is invisible at runtime.

### Why a line-based config, not TOML/YAML?

Three reasons:

1. **Zero dependency.** Swift stdlib has no TOML parser. Rolling one costs lines; importing one costs a dependency. `split("\n")` costs neither.
2. **Comment-to-disable semantics are idiomatic.** `/etc/hosts`, `~/.ssh/config`, `.gitignore`, `~/.netrc` - every battle-tested UNIX config file lets you comment a line to disable it. Users already know this pattern. A TOML `enabled = false` keystone would be less familiar.
3. **grep-friendly.** `grep -v '^-' ~/.config/apfel/mcps.conf` lists enabled MCPs. That property is worth keeping.

### Why `-` for disabled?

Alternatives considered:

- `#` - collides with comments. Ambiguous ("is `#/path.py` a disabled MCP or a shell-style comment about `/path.py`?").
- `!` - already used by some shells for history, could be surprising in a path context.
- `; off` trailing flag - requires more parsing rules.
- `-` - unambiguous. Paths don't start with `-`. `remove/disable` reads naturally.

### Why one MCP per line, not comma-separated?

URLs contain commas sometimes. Paths (rarely) contain spaces. Lines are the only separator that never collides.

## What apfel-run is explicitly *not*

- Not a package manager. It doesn't download MCPs.
- Not a process supervisor. It doesn't keep MCPs running. (apfel handles MCP lifecycle itself per-invocation.)
- Not a GUI. `$EDITOR ~/.config/apfel/mcps.conf` is the management surface.
- Not a config framework for apfel's other env vars. `APFEL_MCP` is the only one it touches. `APFEL_PORT`, `APFEL_MAX_TOKENS`, etc. remain shell-level concerns.

## Merge behaviour with existing `APFEL_MCP`

If the user already has `APFEL_MCP=/shell-override.py` in their environment, apfel-run *prepends* the shell value to the config-derived value:

```
Final APFEL_MCP = shell-value + "," + config-enabled-paths
```

This preserves the ad-hoc override case: `APFEL_MCP=/one-off.py apfel-run "..."` adds `/one-off.py` to your registry for that one call.

Prepend (not append) so shell-set entries get first-listed priority in the MCP chain - matches user expectation that "I explicitly asked for this one".

## Failure modes

| Situation | Behaviour |
|---|---|
| Config file missing | Treated as empty. `apfel-run` runs plain apfel. |
| Config file unreadable | Treated as empty. Silent. (Matches UNIX convention - missing config is not an error.) |
| `apfel` not on `$PATH` | Error message to stderr, exit 127, pointer to install docs. |
| `execve` fails for any other reason | Error message + errno to stderr, exit 126. |
| All MCPs disabled | `APFEL_MCP` is not set (preserves any user-supplied value). |

## Testing posture

- `ApfelRunCore` is a pure library: `ConfigParser`, `Planner`, `Formatter`, `ConfigPath`. All pure functions, 100% unit-testable.
- The exec path lives in `Sources/apfel-run/main.swift`. It's 30 lines of glue - tested manually and via integration shell-scripts, not unit tests.
- The Swift Testing suite covers the parser edge cases (comments, whitespace, URL fragments, standalone dash, empty config, all-disabled, merge semantics).

## Future tempting changes to say no to

- **`apfel-run add /path`** - just edit the file. Don't add a CLI that doubles the surface.
- **Per-prompt profiles** - that's apfel's `--mcp` flag's job, not this wrapper's.
- **Supporting the old colon-separated `APFEL_MCP`** - apfel supports both, apfel-run emits the canonical comma form. No need to reverse-engineer.
- **JSON output from `--list`** - users can parse the text; machine consumers should read the config file directly.
