# OAuth 2.1 for remote MCP servers - `apfel-run auth`

Remote MCP servers like Evernote (`https://mcp.evernote.com/mcp`) answer
unauthenticated requests with `HTTP 401 {"error":"missing_token"}`
([apfel#384](https://github.com/Arthur-Ficial/apfel/issues/384)). `apfel-run auth`
does the OAuth 2.1 dance once, stores the credential in the macOS Keychain, and
resolves (and refreshes) the token automatically on every launch. Log in once,
then `apfel-run` just works.

## Commands

```
apfel-run auth login <https-mcp-url> [--scope SCOPE] [--timeout SECONDS] [--no-browser]
apfel-run auth list
apfel-run auth status <https-mcp-url>
apfel-run auth logout <https-mcp-url>
```

### `auth login`

```bash
apfel-run auth login https://mcp.evernote.com/mcp
```

What happens:

1. apfel-run discovers the server's OAuth metadata (see "Discovery ladder" below).
2. It registers itself as a public client (RFC 7591 dynamic client registration,
   PKCE S256, `token_endpoint_auth_method: none`).
3. Your browser opens the authorization page. With `--no-browser` (for SSH
   sessions) the URL is printed to stderr for manual opening.
4. A loopback listener on `127.0.0.1:<ephemeral-port>` catches the redirect
   (RFC 8252). Default wait is 300 s; tune with `--timeout`.
5. The authorization code is exchanged for tokens and stored in the Keychain.

Scope defaults to the server's advertised `scopes_supported`; override with
`--scope "a b c"`.

Progress lines go to stderr; stdout carries only the final result, so the
command stays pipeable.

### Wiring the profile

```toml
[[profile.default.mcp.server]]
path = "https://mcp.evernote.com/mcp"
enabled = true
auth = "oauth"
```

`auth = "oauth"` is opt-in and explicit: `config validate` can enforce the
rules statically and `config show` stays deterministic without Keychain reads
(it prints an informational `# mcp.server[i]: auth=oauth ...` marker instead).

On every launch apfel-run resolves the token before exec'ing apfel:
valid Keychain token -> used as `APFEL_MCP_TOKEN`; expired + refresh token ->
refreshed (rotation persisted) and used; nothing usable -> loud abort, never a
silent 401. Full precedence table:
[docs/config-reference.md](config-reference.md).

## Exit codes

| Command | Exit | Meaning |
|---|---|---|
| `auth login` | 0 | authenticated, credential stored |
| `auth login` | 2 | usage error (non-https URL, unknown flag) |
| `auth login` | 1 | flow failure (discovery/registration/exchange/timeout/state) |
| `auth list` | 0 | always |
| `auth status` | 0 | valid |
| `auth status` | 1 | expired (stderr says whether launch will auto-refresh) |
| `auth status` | 4 | nothing stored for that URL |
| `auth logout` | 0 | removed |
| `auth logout` | 4 | nothing stored for that URL |
| launch path | 2 | more than one enabled `auth = "oauth"` server in the profile |
| launch path | 1 | refresh failed / no credential (with an `auth login` hint) |

Exit 4 ("nothing stored") is distinct from 1 ("expired") so scripts can tell
"never logged in" from "needs refresh/re-login".

## Discovery ladder (MCP auth spec rev 2025-06-18)

apfel-run pins the 2025-06-18 MCP authorization spec
(RFC 9728 + RFC 8414 + RFC 8707):

1. Unauthenticated `initialize` POST -> `401` with
   `WWW-Authenticate: Bearer resource_metadata="<url>"` -> fetch that
   protected-resource metadata.
2. Fallback: path-aware `/.well-known/oauth-protected-resource/<mcp-path>`,
   then origin-level `/.well-known/oauth-protected-resource`.
3. The AS from `authorization_servers[0]` is resolved via RFC 8414
   `/.well-known/oauth-authorization-server` (path-aware), falling back to OIDC
   `/.well-known/openid-configuration` for Auth0/Okta-style servers.

The legacy 2025-03-26 "MCP origin IS the authorization server" rung is
deliberately not probed. If a server needs it, file an issue with the error
message - it names the failing rung, which is exactly the field report needed.

Security properties (each locked by a named unit test): PKCE S256 mandatory
(`plain` refused), CSRF `state` with constant-time compare, https required on
the MCP URL and on every advertised AS endpoint (only loopback
`127.0.0.1`/`::1`/`localhost` may use http - same rule as apfel core), RFC 8414
issuer mix-up defense, RFC 8707 `resource` sent on authorize + token requests,
loopback-only redirect listener that closes after the first valid callback,
tokens only ever in env + Keychain (never argv, never logs, never iCloud-synced).

## Keychain notes

- The credential is a generic-password item, service
  `com.arthur-ficial.apfel-run.oauth`, account = normalized server URL,
  `kSecAttrAccessibleWhenUnlocked`, never synchronizable.
- **First read prompts once**: macOS asks to allow `apfel-run` to use the item.
  Click "Always Allow".
- **Dev-loop friction**: every rebuild of an ad-hoc-signed `apfel-run` changes
  its code signature, so the next Keychain read prompts again. Release binaries
  with a stable Developer ID signature prompt once.

## Honest limitations

1. **One OAuth MCP server per profile.** apfel core has a single
   `APFEL_MCP_TOKEN`. Two enabled OAuth servers in one profile is a hard config
   error, not a silent wrong-token send. Lifted when
   [apfel#386](https://github.com/Arthur-Ficial/apfel/issues/386) lands
   per-server routing.
2. **`--serve` mid-session expiry.** apfel-run refreshes before execve and then
   ceases to exist (it is not a process supervisor). A long-running
   `apfel --serve` will start 401-ing on the MCP when the access token expires;
   remedy is a restart (`apfel-run -p serve` refreshes again). Serve-mode
   launches print `token for <url> expires at <time>; restart apfel-run to
   refresh` to stderr so the cliff is visible up front.
3. **DCR-less servers.** If the authorization server publishes no
   `registration_endpoint`, login fails with an actionable error. A
   pre-provisioned `client_id` escape hatch is future work.
4. **Refresh rotation is serialized per machine only.** A file lock
   (`~/.config/apfel/.auth-refresh.lock`) prevents concurrent local launches
   from replaying a rotated refresh token; two different Macs sharing the same
   grant have no shared lock and can still trip an AS's reuse detection (grant
   revoked). Remedy: `apfel-run auth login` again.

## Testing

All protocol branches are unit-tested against fakes (no network, no Keychain):
`swift test`. The interactive glue (real transport, loopback listener, flock
refresh race) is covered by the smoke script against a local fake AS - it
touches the real Keychain (creates and removes one item):

```bash
make smoke-auth
```
