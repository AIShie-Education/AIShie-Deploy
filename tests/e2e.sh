#!/usr/bin/env bash
# The whole stack, for real: setup-server.sh on this machine with the images
# the channels name, then what a person, the operator and the runtime see,
# through Caddy. It sets the machine up as an AIshie server, as root, and
# leaves it so: run it only where that can be thrown away, as CI's end to
# end does (.github/workflows/ci.yml, which runs it on a fresh runner):
#
#   sudo tests/e2e.sh
#
# The server is named E2E_HOST, aishie.internal by default: a name that can
# have no public certificate, so Caddy serves it from its own local
# authority, as it would localhost. Unlike localhost, it means the same
# thing inside a container as outside, so the runtime's way to Core, through
# Caddy's alias on the stack's network, can be checked too. This machine
# reaches it on 127.0.0.1 (curl --resolve), as a browser would reach the
# server's public address.
#
# The images are the channels' :edge from ghcr.io, which the machine must be
# logged in to (docker login ghcr.io). AISHIE_REGISTRY and the AISHIE_ paths
# move things as they do for setup-server.sh, for a run against a registry
# of one's own.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
name=${E2E_HOST:-aishie.internal}
REGISTRY=${AISHIE_REGISTRY:-ghcr.io/aishie-education}
ETC=${AISHIE_ETC:-/etc/aishie}
STATE=${AISHIE_STATE:-/var/lib/aishie}
BIN=${AISHIE_BIN:-/usr/local/bin}
BACKUPS=${AISHIE_BACKUPS:-/var/backups/aishie}
LOG_FILE=${AISHIE_LOG_FILE:-/var/log/aishie-update.log}
# The curl that asks from inside the runtime's network namespace.
CURL_IMAGE=curlimages/curl:8.16.0@sha256:463eaf6072688fe96ac64fa623fe73e1dbe25d8ad6c34404a669ad3ce1f104b6

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
ok() { echo "ok - $*"; }
fail() { echo "FAIL - $*" >&2; failed=1; }
check() { # check DESCRIPTION COMMAND...: ok when the command succeeds
  local what=$1
  shift
  if "$@"; then ok "$what"; else fail "$what"; fi
}
is() { [ "$1" = "$2" ] || { echo "  got: ${1:-(nothing)}; want: $2" >&2; return 1; }; }
# shellcheck disable=SC2053 # $2 is a pattern
like() { [[ $1 == $2 ]] || { echo "  got: ${1:-(nothing)}; want: $2" >&2; return 1; }; }
die() { echo "e2e: $*" >&2; exit 1; }
in_actions() { [ "${GITHUB_ACTIONS:-}" = true ]; }
aishie() { "$BIN/aishie" "$@"; }

# What happened, when something did not go as it should.
diagnose() {
  echo "# aishie-update --status" >&2
  "$BIN/aishie-update" --status >&2 2>&1 || true
  echo "# $LOG_FILE" >&2
  cat "$LOG_FILE" >&2 2>/dev/null || true
  echo "# aishie ps" >&2
  aishie ps -a >&2 2>&1 || true
  echo "# the stack's logs" >&2
  aishie compose logs --no-color --tail 60 >&2 2>&1 || true
}

[ "$(id -u)" = 0 ] || die "run it as root (sudo tests/e2e.sh), on a machine that can be thrown away: it sets it up as a server"

# The images, first: a private package this repository's workflows cannot
# read is the one failure that needs a person, once, so it is said plainly.
echo "# the images of $REGISTRY"
denied=
for pkg in aishie-core aishie-agent-runtime aishie-frontend; do
  img=$REGISTRY/$pkg:edge
  if docker pull -q "$img" >/dev/null 2>"$work/pull.err"; then
    ok "can pull $img"
    continue
  fi
  cat "$work/pull.err" >&2
  denied=1
  if in_actions && [ "${REGISTRY%%/*}" = ghcr.io ]; then
    echo "::error::Could not pull $img. The package is private, and this repository's workflows can read it only once an owner of the AIShie-Education organization (or an admin of the package) grants it, once: https://github.com/orgs/AIShie-Education/packages/container/$pkg/settings → Manage Actions access → Add Repository → AIShie-Deploy, role Read. (If the error above is not denied, unauthorized or not found, GHCR may be having trouble: re-run the job.)"
  else
    echo "e2e: could not pull $img: docker login ${REGISTRY%%/*} with a token that can read the package (classic, read:packages)" >&2
  fi
done
[ -z "$denied" ] || exit 1

# The server, set up as a person would set it up, with Core's files on its
# disk: said, so that a run at a terminal is not asked.
echo "# setup-server.sh $name edge --storage fs"
if ! sh "$root/setup-server.sh" "$name" edge --storage fs; then
  diagnose
  die "setup-server.sh failed (above)"
fi

echo "# what runs"
refs=$(grep -E '^[A-Z]+_REF=' "$STATE/images.env" || true)
for pair in CORE_REF=aishie-core RUNTIME_REF=aishie-agent-runtime WEB_REF=aishie-frontend; do
  check "${pair%%=*} is an image of $REGISTRY/${pair#*=}, by digest" \
    like "$(sed -n "s/^${pair%%=*}=//p" <<< "$refs")" "$REGISTRY/${pair#*=}@sha256:????????????????????????????????????????????????????????????????"
done
check "the log has the three deploys" is "$(grep -c ': deployed ' "$LOG_FILE" || true)" 3
has() { ls "$@" > /dev/null 2>&1; }
check "a backup of each database was taken before its deploy" has "$BACKUPS"/core-deploy-*.dump "$BACKUPS"/runtime-deploy-*.dump
"$BIN/aishie-update" --status > "$work/status"
check "aishie-update --status names what each runs" is "$(grep -c '  running:     .*@sha256:' "$work/status")" 3

# Caddy's local authority, which signed the certificate for the name: the
# one a browser here would be told to trust.
echo "# through Caddy, https://$name"
for _ in $(seq 1 60); do
  if aishie compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > "$work/root.crt" 2>/dev/null &&
    [ -s "$work/root.crt" ] &&
    curl -fsS --noproxy '*' --max-time 5 -o /dev/null --resolve "$name:443:127.0.0.1" --cacert "$work/root.crt" "https://$name/healthz" 2>/dev/null; then
    break
  fi
  sleep 1
done
chmod 644 "$work/root.crt"

# get NAME URL [CURL ARGS...]: the status in $status, the headers in
# $work/NAME.headers, the body in $work/NAME.body; NAME.body is also $body.
status='' body=''
get() {
  local n=$1 url=$2
  shift 2
  status=$(curl -sS --noproxy '*' --max-time 10 --resolve "$name:443:127.0.0.1" --resolve "$name:80:127.0.0.1" \
    --cacert "$work/root.crt" -D "$work/$n.headers" -o "$work/$n.body" -w '%{http_code}' "$@" "$url") || status=000
  body=$(cat "$work/$n.body" 2>/dev/null || true)
}
header() {
  tr -d '\r' < "$work/$1.headers" | awk -v f="$2" 'BEGIN { f = tolower(f) } { i = index($0, ":") } i && tolower(substr($0, 1, i - 1)) == f { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); v2 = v } END { print v2 }'
}
json() { jq -r "$1" <<< "$body" 2>/dev/null || true; }

get core-own http://127.0.0.1:8080/healthz
core_commit=$(json .commit)
get runtime-own http://127.0.0.1:9090/healthz
runtime_health=$body
get web-own-index http://127.0.0.1:8081/
web_index=$body
get web-own-version http://127.0.0.1:8081/version.json
web_version=$body

get healthz "https://$name/healthz"
check "/healthz answers 200 over HTTPS, with the certificate of Caddy's authority for $name" is "$status" 200
check "/healthz is Core's: status ok, its schema, and the commit Core reports on 127.0.0.1:8080" \
  is "$(json '[.status, (.schema_version | type), .commit] | join(" ")')" "ok number $core_commit"

get index "https://$name/"
check "/ answers 200" is "$status" 200
check "/ is the web's index.html" is "$body" "$web_index"
check "/ is the app" grep -q '<div id="app"' "$work/index.body"
check "/ may be framed by the app's own pages alone (FRAME_ANCESTORS unset)" \
  is "$(header index Content-Security-Policy)" "frame-ancestors 'self'"
check "/ is Cache-Control: no-cache" is "$(header index Cache-Control)" no-cache
get deep "https://$name/courses/0f1e2d3c/assignments?tab=rubric"
check "an app route is index.html too" is "$body" "$web_index"
get version "https://$name/version.json"
check "/version.json is the web's" is "$body" "$web_version"

get tools "https://$name/v1/tools"
check "/v1/tools answers 200 as Core, in JSON" is "$status $(header tools Content-Type | cut -d';' -f1) $(json 'type')" "200 application/json object"
get methods "https://$name/v1/auth/methods"
case $status in
  200) check "/v1/auth/methods says: password, no single sign-on" is "$(jq -c '{password, sso}' <<< "$body" 2>&1)" '{"password":true,"sso":null}' ;;
  404) check "/v1/auth/methods is Core's 404 (a Core from before the route), not the app" \
    like "$(header methods Content-Type)" 'application/json*' ;;
  *) fail "/v1/auth/methods answers $status: $body" ;;
esac
get mcp "https://$name/mcp" -X POST -H 'Content-Type: application/json' -d '{}'
check "/mcp is Core's: it wants a token" is "$status" 401
# An MCP client asks these before it signs in with OAuth; Core has none, and
# says so, where the web's page would pass for an authorization server.
for p in /.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/mcp /.well-known/oauth-authorization-server; do
  get wellknown "https://$name$p"
  check "$p is Core's 404, not the app" is "$status $(header wellknown Content-Type | cut -d';' -f1)" "404 application/json"
done

# The first administrator, with the password on standard input, who then
# signs in with it through Caddy (POST /v1/auth/login), as the web's sign-in
# page does, and calls the API with the session Core gives: people hold no
# API tokens, only agents do. Bootstrap's standard output goes nowhere: a
# Core from before that prints one for root there, which is never read. The
# password and the session stay in this shell, and reach curl on its
# standard input.
password=$(openssl rand -hex 16)
if in_actions; then echo "::add-mask::$password"; fi
if printf '%s\n' "$password" | aishie core bootstrap --name Root --email root@e2e.test --password-stdin >/dev/null 2>"$work/bootstrap.err"; then
  ok "aishie core bootstrap makes the first administrator"
else
  cat "$work/bootstrap.err" >&2
  fail "aishie core bootstrap makes the first administrator"
fi
get anonymous "https://$name/v1/actors"
check "/v1/actors refuses a call with no token" is "$status" 401
get signin "https://$name/v1/auth/login" -H 'Content-Type: application/json' --data-binary @- \
  <<< "$(printf '{"email":"root@e2e.test","password":"%s"}' "$password")"
unset password
session=$(header signin Set-Cookie | sed -n 's/^ais_session=\([^;]*\).*/\1/p')
rm -f "$work/signin.headers"
if in_actions && [ -n "$session" ]; then echo "::add-mask::$session"; fi
check "the administrator signs in with the email and password given to bootstrap, and is given a session" \
  is "$status $(json .password_change_required) $([ -n "$session" ] && echo session)" "200 false session"
# with_session KIND SESSION PATH: the status of GET PATH through Caddy,
# with the session as a bearer token (bearer) or as the cookie a browser
# sends (cookie).
with_session() {
  local config code
  case $1 in
    bearer) config='header = "Authorization: Bearer %s"' ;;
    cookie) config='cookie = "ais_session=%s"' ;;
  esac
  # shellcheck disable=SC2059 # the format is one of the two above
  code=$(printf "$config\n" "$2" |
    curl -sS --noproxy '*' --max-time 10 --config - --resolve "$name:443:127.0.0.1" --cacert "$work/root.crt" \
      -o "$work/session.body" -w '%{http_code}' "https://$name$3") || code=000
  echo "$code"
}
check "/v1/actors answers the administrator, with the session as a bearer token" is "$(with_session bearer "$session" /v1/actors)" 200
check "/v1/me answers the administrator, with the session's cookie, as the web asks" is "$(with_session cookie "$session" /v1/me)" 200
unset session

# The runtime's own endpoints are never routed: /runtime/api/* goes to its
# API on 9091 (nothing listens there until M2: 502), and its 9090 is not
# reachable by any path. Each is asked, and answered by something.
get runtime-api "https://$name/runtime/api/healthz"
check "/runtime/api/healthz is answered, and not by the runtime's 9090 (answers $status)" \
  test "$status" != 000 -a "$body" != "$runtime_health"
if [ "$status" = 502 ]; then
  ok "/runtime/api/ answers 502: nothing listens on the runtime's 9091 yet (its API comes with M2)"
else
  ok "/runtime/api/ answers $status: the runtime serves its API on 9091"
fi
for path in /runtime/api/metrics /runtime/api/status /metrics /status /runtime/healthz; do
  get leak "https://$name$path"
  if [ "$status" = 000 ]; then
    fail "$path is not answered at all"
  elif grep -q -e '^# HELP' -e '"worker"' -e '"agents"' "$work/leak.body" || [ "$body" = "$runtime_health" ]; then
    fail "$path reaches the runtime's 9090"
  else
    ok "$path does not reach the runtime's 9090 (answers $status)"
  fi
done
get plain "http://$name/healthz"
check "plain HTTP is sent to HTTPS" is "$status $(header plain Location)" "308 https://$name/healthz"

echo "# the stack"
ports=$(docker ps -q --filter label=com.docker.compose.project=aishie | xargs docker inspect |
  jq -r '.[] | (.Name | ltrimstr("/")) as $n | (.NetworkSettings.Ports // {}) | to_entries[] | .key as $p | (.value // [])[] | "\($n) \(.HostIp) \($p)"')
check "only Caddy is published beyond 127.0.0.1" is "$(awk '$1 !~ /caddy/ && $2 != "127.0.0.1"' <<< "$ports")" ""
check "Caddy is published on 80, 443 and 443/udp" is "$(awk '$1 ~ /caddy/ && $2 != "127.0.0.1" { print $3 }' <<< "$ports" | sort -u | tr '\n' ' ')" "443/tcp 443/udp 80/tcp "
check "PostgreSQL is not published" is "$(awk '$1 ~ /postgres/' <<< "$ports")" ""
web=$(aishie ps -q web)
check "the web runs as 65532, read-only, with no capability and no new privileges" \
  is "$(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$web")" \
  "65532:65532 true [ALL] [no-new-privileges:true]"
check "the web is given FRAME_ANCESTORS='self'" \
  is "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$web" | sed -n 's/^FRAME_ANCESTORS=//p')" "'self'"
check "the web's own health check passes" is "$(docker inspect -f '{{.State.Health.Status}}' "$web")" healthy
# core.env reaches Core whole, with the SECRETS_KEY setup-server.sh wrote in
# it: compared by digest, so that the key is printed nowhere, even when the
# check fails.
core=$(aishie ps -q core)
check "setup-server.sh wrote a SECRETS_KEY of 32 bytes in base64" \
  is "$(sed -n 's/^SECRETS_KEY=//p' "$ETC/core.env" | base64 -d | wc -c)" 32
check "Core is given core.env's SECRETS_KEY" \
  is "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$core" | grep '^SECRETS_KEY=' | sha256sum)" \
  "$(grep '^SECRETS_KEY=' "$ETC/core.env" | sha256sum)"

# Inside the stack's network, the name is Caddy (its alias there), with the
# certificate a browser gets: the runtime reaches Core at https://NAME
# without going out and back in. Asked from the runtime's own network
# namespace, with its /etc/hosts and Docker's DNS.
runtime=$(aishie ps -q runtime)
caddy_ip=$(sed -n 's/^AISHIE_CADDY_IP=//p' "$ETC/aishie.env" | tail -n 1)
# curl's image is pulled first, and the check's container never pulls: what
# it prints is curl's alone, not Docker's progress on a machine without it.
docker pull -q "$CURL_IMAGE" > /dev/null || fail "could not pull $CURL_IMAGE"
seen=$(docker run --rm --pull never --network "container:$runtime" -v "$work/root.crt:/ca.crt:ro" "$CURL_IMAGE" \
  -sS --noproxy '*' --max-time 10 --cacert /ca.crt -o /dev/null -w '%{http_code} %{remote_ip}' "https://$name/healthz" 2>&1) || true
check "from the runtime, https://$name is Caddy ($caddy_ip), with a valid certificate, and Core answers" is "$seen" "200 $caddy_ip"

check "the runtime's role cannot connect to Core's database, nor Core's to the runtime's" \
  is "$(aishie compose exec -T postgres psql -X -U postgres -d postgres -Atc \
    "SELECT has_database_privilege('aishie_runtime', 'aishie_core', 'CONNECT') OR has_database_privilege('aishie_core', 'aishie_runtime', 'CONNECT')")" f

echo "# the operator's commands"
check "aishie core migrate version" aishie core migrate version
check "aishie runtime check (no agent yet)" aishie runtime check
check "aishie runtime migrate version" aishie runtime migrate version
check "aishie backup" aishie backup
day=$(date +%u)
# restorable FILE: root's alone, and a dump pg_restore can read.
restorable() { [ "$(stat -c %a "$1")" = 600 ] && aishie compose exec -T postgres pg_restore --list < "$1" > /dev/null; }
for s in core runtime; do
  check "$BACKUPS/$s-daily-$day.dump is a dump PostgreSQL can read, root's alone" restorable "$BACKUPS/$s-daily-$day.dump"
done

# Nothing new on the channels: a second run does nothing, and neither does
# `docker compose up -d`, as after a reboot: what runs is pinned by digest.
echo "# again"
before=$(docker ps -q --no-trunc --filter label=com.docker.compose.project=aishie | sort)
log_before=$(cat "$LOG_FILE")
"$BIN/aishie-update" > "$work/again" 2>&1 || { cat "$work/again" >&2; fail "the second aishie-update failed"; }
check "a second aishie-update finds the three up to date" is "$(grep -c ': up to date, ' "$work/again" || true)" 3
check "... logs nothing" is "$(cat "$LOG_FILE")" "$log_before"
"$BIN/aishie-update" --dry-run > "$work/dry" 2>&1 || fail "aishie-update --dry-run failed: $(cat "$work/dry")"
check "aishie-update --dry-run would do nothing" is "$(grep -c ': up to date, ' "$work/dry" || true)" 3
aishie compose up -d > "$work/up" 2>&1 || { cat "$work/up" >&2; fail "aishie compose up -d failed"; }
check "... and neither run nor docker compose up -d recreated a container" \
  is "$(docker ps -q --no-trunc --filter label=com.docker.compose.project=aishie | sort)" "$before"

if [ "$failed" != 0 ]; then
  diagnose
  echo "# e2e: failed (above)" >&2
  exit 1
fi
echo "# e2e: all passed"
