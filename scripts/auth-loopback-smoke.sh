#!/bin/bash
# auth-loopback-smoke.sh - end-to-end OAuth 2.1 login smoke test against a
# local fake AS+MCP (Python stdlib, no browser, no network beyond loopback).
#
# Covers the glue that unit tests cannot reach:
#   - full discovery -> DCR -> authorize -> loopback callback -> exchange chain
#     over the real URLSessionTransport + LoopbackListener
#   - F3: the accept loop survives junk connections (bare TCP connect,
#     GET /favicon.ico) without consuming the login
#   - F13: no insecure-override knob needed - the loopback exception carries it
#   - loopback listener binds 127.0.0.1 only (lsof check)
#   - F4: two concurrent apfel-run launches with an expired token produce
#     EXACTLY ONE refresh grant (flock winner refreshes; loser re-loads the
#     rotated credential). Rotation persistence itself is unit-tested
#     (LaunchTokenResolverTests "persists rotated credential").
#
# Touches the REAL user Keychain (item is created and removed by the script).
# Run manually or via `make smoke-auth`. Requires .build/release/apfel-run.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/.build/release/apfel-run"
[ -x "$BIN" ] || { echo "FAIL: build first: swift build -c release" >&2; exit 1; }

WORK="$(mktemp -d /tmp/apfel-run-auth-smoke.XXXXXX)"
SERVER_PY="$WORK/fake_as.py"
SERVER_LOG="$WORK/server.log"
cleanup() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "${MCP_URL:-}" ] && "$BIN" auth logout "$MCP_URL" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- fake AS+MCP
cat > "$SERVER_PY" <<'PYEOF'
import base64, hashlib, json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "challenge": None,
    "current_refresh": None,
    "refresh_count": 0,
    "exchange_expires_in": 3600,
    "refresh_expires_in": 3600,
    "errors": [],
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, code, obj, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def base(self):
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        base = self.base()
        if parsed.path == "/.well-known/oauth-protected-resource/mcp":
            self._json(200, {"resource": base + "/mcp",
                             "authorization_servers": [base]})
        elif parsed.path == "/.well-known/oauth-authorization-server":
            self._json(200, {"issuer": base,
                             "authorization_endpoint": base + "/authorize",
                             "token_endpoint": base + "/token",
                             "registration_endpoint": base + "/register",
                             "code_challenge_methods_supported": ["S256"]})
        elif parsed.path == "/authorize":
            q = urllib.parse.parse_qs(parsed.query)
            if q.get("code_challenge_method", [None])[0] != "S256":
                STATE["errors"].append("authorize: code_challenge_method != S256")
            if "resource" not in q:
                STATE["errors"].append("authorize: missing RFC 8707 resource")
            STATE["challenge"] = q["code_challenge"][0]
            redirect = (q["redirect_uri"][0] + "?code=smoke-code"
                        + "&state=" + urllib.parse.quote(q["state"][0]))
            self.send_response(302)
            self.send_header("Location", redirect)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif parsed.path == "/_debug":
            self._json(200, {"refresh_count": STATE["refresh_count"],
                             "current_refresh": STATE["current_refresh"],
                             "errors": STATE["errors"]})
        elif parsed.path == "/_config":
            q = urllib.parse.parse_qs(parsed.query)
            for key in ("exchange_expires_in", "refresh_expires_in"):
                if key in q:
                    STATE[key] = int(q[key][0])
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not_found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        base = self.base()
        if self.path == "/mcp":
            self.send_response(401)
            self.send_header(
                "WWW-Authenticate",
                f'Bearer resource_metadata="{base}/.well-known/oauth-protected-resource/mcp"')
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/register":
            req = json.loads(body)
            if req.get("token_endpoint_auth_method") != "none":
                STATE["errors"].append("register: auth method not none")
            self._json(201, {"client_id": "smoke-client"})
        elif self.path == "/token":
            form = urllib.parse.parse_qs(body)
            grant = form.get("grant_type", [None])[0]
            if grant == "authorization_code":
                verifier = form.get("code_verifier", [""])[0]
                expected = base64.urlsafe_b64encode(
                    hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
                if expected != STATE["challenge"]:
                    STATE["errors"].append("token: PKCE verifier does not match challenge")
                    self._json(400, {"error": "invalid_grant"})
                    return
                if "resource" not in form:
                    STATE["errors"].append("token: missing RFC 8707 resource")
                STATE["current_refresh"] = "rt-1"
                self._json(200, {"access_token": "at-1", "token_type": "Bearer",
                                 "expires_in": STATE["exchange_expires_in"],
                                 "refresh_token": "rt-1"})
            elif grant == "refresh_token":
                sent = form.get("refresh_token", [""])[0]
                if sent != STATE["current_refresh"]:
                    STATE["errors"].append(
                        f"REFRESH REPLAY: got {sent}, current {STATE['current_refresh']}")
                    self._json(400, {"error": "invalid_grant"})
                    return
                STATE["refresh_count"] += 1
                n = STATE["refresh_count"]
                STATE["current_refresh"] = f"rt-{n + 1}"
                self._json(200, {"access_token": f"at-{n + 1}", "token_type": "Bearer",
                                 "expires_in": STATE["refresh_expires_in"],
                                 "refresh_token": STATE["current_refresh"]})
            else:
                self._json(400, {"error": "unsupported_grant_type"})
        else:
            self._json(404, {"error": "not_found"})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PYEOF

python3 "$SERVER_PY" > "$WORK/port.txt" 2> "$SERVER_LOG" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port.txt" ] && break; sleep 0.1; done
AS_PORT="$(cat "$WORK/port.txt")"
MCP_URL="http://127.0.0.1:$AS_PORT/mcp"
echo "fake AS+MCP on 127.0.0.1:$AS_PORT"

pass_count=0
check() {  # check <description> <command...>
    local desc="$1"; shift
    if "$@"; then
        pass_count=$((pass_count + 1))
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        exit 1
    fi
}

debug_field() {
    curl -s "http://127.0.0.1:$AS_PORT/_debug" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"
}

# --------------------------------------------------- phase 1: login round-trip
LOGIN_ERR="$WORK/login.err"
LOGIN_OUT="$WORK/login.out"
"$BIN" auth login "$MCP_URL" --no-browser --timeout 20 \
    > "$LOGIN_OUT" 2> "$LOGIN_ERR" &
LOGIN_PID=$!

# Wait until the listener is up and the authorization URL is printed.
for _ in $(seq 1 100); do
    grep -q "waiting for callback" "$LOGIN_ERR" 2>/dev/null && break
    sleep 0.1
done
AUTH_URL="$(grep -o 'http://127.0.0.1:[0-9]*/authorize?[^ ]*' "$LOGIN_ERR" | head -1)"
CB_PORT="$(grep -o 'waiting for callback on 127.0.0.1:[0-9]*' "$LOGIN_ERR" | grep -o '[0-9]*$')"
check "authorization URL printed to stderr" test -n "$AUTH_URL"
check "callback port printed to stderr" test -n "$CB_PORT"

# Loopback-only binding (RFC 8252 section 7.3)
check "listener bound to 127.0.0.1 only" \
    bash -c "lsof -nP -iTCP:$CB_PORT -sTCP:LISTEN | grep -q '127.0.0.1' && ! lsof -nP -iTCP:$CB_PORT -sTCP:LISTEN | grep -q '\*:'"

# F3: junk connections must not consume the login.
bash -c "exec 3<>/dev/tcp/127.0.0.1/$CB_PORT && exec 3<&-" || true   # bare preconnect
curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$CB_PORT/favicon.ico" || true

# Complete the flow: the fake AS 302s straight to the loopback redirect.
curl -sL -o /dev/null --max-time 10 "$AUTH_URL"
wait "$LOGIN_PID" && LOGIN_EXIT=0 || LOGIN_EXIT=$?
check "auth login exits 0 (survived junk connections)" test "$LOGIN_EXIT" -eq 0
check "success line on stdout" grep -q "authenticated" "$LOGIN_OUT"
check "auth status exits 0 while valid" "$BIN" auth status "$MCP_URL" > /dev/null
check "auth list shows the server" bash -c "'$BIN' auth list | grep -q '127.0.0.1:$AS_PORT'"

# ------------------------------------- phase 2: F4 two-process refresh race
# Re-login with a 1-second access token so the next launches must refresh.
"$BIN" auth logout "$MCP_URL" > /dev/null
curl -s "http://127.0.0.1:$AS_PORT/_config?exchange_expires_in=1&refresh_expires_in=3600" > /dev/null

"$BIN" auth login "$MCP_URL" --no-browser --timeout 20 \
    > "$LOGIN_OUT" 2> "$LOGIN_ERR" &
LOGIN_PID=$!
for _ in $(seq 1 100); do
    grep -q "waiting for callback" "$LOGIN_ERR" 2>/dev/null && break
    sleep 0.1
done
AUTH_URL="$(grep -o 'http://127.0.0.1:[0-9]*/authorize?[^ ]*' "$LOGIN_ERR" | head -1)"
curl -sL -o /dev/null --max-time 10 "$AUTH_URL"
wait "$LOGIN_PID"
check "second login (short-lived token) exits 0" true

sleep 2  # let the 1 s access token expire

# Stub apfel binary that just prints the token it received.
STUB="$WORK/apfel-stub"
printf '#!/bin/bash\necho "$APFEL_MCP_TOKEN"\n' > "$STUB"
chmod +x "$STUB"

RUN_DIR="$WORK/rundir"
mkdir -p "$RUN_DIR"
cat > "$RUN_DIR/apfel.toml" <<TOMLEOF
[[profile.default.mcp.server]]
path = "$MCP_URL"
enabled = true
auth = "oauth"
TOMLEOF

(cd "$RUN_DIR" && APFEL_RUN_APFEL_BINARY="$STUB" "$BIN" "hi" > "$WORK/stub1.out" 2> "$WORK/stub1.err") &
P1=$!
(cd "$RUN_DIR" && APFEL_RUN_APFEL_BINARY="$STUB" "$BIN" "hi" > "$WORK/stub2.out" 2> "$WORK/stub2.err") &
P2=$!
wait "$P1"; wait "$P2"

TOKEN1="$(head -1 "$WORK/stub1.out")"
TOKEN2="$(head -1 "$WORK/stub2.out")"
check "both launches got a non-empty token" bash -c "test -n '$TOKEN1' && test -n '$TOKEN2'"
check "both launches got the SAME rotated token" test "$TOKEN1" = "$TOKEN2"
check "fake AS counted EXACTLY ONE refresh grant" test "$(debug_field refresh_count)" = "1"
check "no protocol errors recorded by the fake AS" test "$(debug_field errors)" = "[]"

# ------------------------------------------------------------ phase 3: logout
check "auth logout exits 0" bash -c "'$BIN' auth logout '$MCP_URL' > /dev/null"
"$BIN" auth status "$MCP_URL" > /dev/null 2>&1 && STATUS_EXIT=0 || STATUS_EXIT=$?
check "auth status after logout exits 4 (keychain entry cleaned up)" test "$STATUS_EXIT" -eq 4

echo ""
echo "auth-loopback-smoke: all $pass_count checks passed"
