#!/usr/bin/env bash
# The stack's configuration, checked without running it:
#
# - compose.yaml, with stack.yaml, against the example settings
#   (env/*.example) and an images.env, before any deploy and after one:
#   `docker compose config`, which needs no Docker daemon, and what must hold
#   in the model it gives (only Caddy on a public interface, Core trusting
#   Caddy alone, the images by digest);
# - the Caddyfile, with `caddy validate`: a caddy binary on PATH (or $CADDY),
#   else Caddy's image.
#
#   make config
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failed=0
fail() { echo "FAIL config $case: $*" >&2; failed=1; }

mkdir -p "$work/etc" "$work/state"
for f in aishie core runtime postgres; do cp "$root/env/$f.env.example" "$work/etc/$f.env"; done
export AISHIE_ETC=$work/etc AISHIE_STATE=$work/state
# Names the settings would otherwise take from this shell.
unset HOST CORE_REF RUNTIME_REF WEB_REF AISHIE_SUBNET AISHIE_CADDY_IP RUNTIME_STOP_GRACE FRAME_ANCESTORS
compose() { docker compose --project-directory "$root" -f "$root/compose.yaml" "$@"; }
hex() { printf "$1%.0s" $(seq 64); }
CORE=ghcr.io/aishie-education/aishie-core@sha256:$(hex a)
RUNTIME=ghcr.io/aishie-education/aishie-agent-runtime@sha256:$(hex b)
WEB=ghcr.io/aishie-education/aishie-frontend@sha256:$(hex c)

for case in before-any-deploy deployed; do
  if [ $case = deployed ]; then
    printf 'CORE_REF=%s\nRUNTIME_REF=%s\nWEB_REF=%s\n' "$CORE" "$RUNTIME" "$WEB" > "$work/state/images.env"
  else
    printf '# nothing deployed yet\n' > "$work/state/images.env"
  fi
  compose config -q || { fail "docker compose config refused it"; continue; }
  model=$(compose config --format json)
  q() { jq -r "$1" <<< "$model"; }

  [ "$(q .name)" = aishie ] || fail "project $(q .name)"
  [ "$(q '.services | keys | join(" ")')" = "caddy core postgres runtime web" ] || fail "services: $(q '.services | keys | join(" ")')"
  # Only Caddy is published beyond the loopback, and PostgreSQL not at all.
  [ "$(q '[.services | to_entries[] | select(.key != "caddy") | .value.ports[]? | select(.host_ip != "127.0.0.1")] | length')" = 0 ] ||
    fail "published beyond 127.0.0.1: $(q '[.services | to_entries[] | select(.key != "caddy") | .value.ports[]?]')"
  [ "$(q '.services.postgres.ports // [] | length')" = 0 ] || fail "PostgreSQL is published"
  [ "$(q '[.services.caddy.ports[].target] | sort | join(" ")')" = "80 443 443" ] || fail "Caddy's ports: $(q '.services.caddy.ports')"
  [ "$(q '.services.core.ports[0].published'):$(q '.services.runtime.ports[0].published'):$(q '.services.web.ports[0].published')" = 8080:9090:8081 ] ||
    fail "the health checks' ports moved"
  # Core trusts Caddy's address alone, and Caddy has that address.
  caddy_ip=$(q '.services.caddy.networks.default.ipv4_address')
  [ "$caddy_ip" = 172.30.83.10 ] || fail "Caddy's address: $caddy_ip"
  [ "$(q '.services.core.environment.TRUSTED_PROXIES')" = "$caddy_ip/32" ] || fail "TRUSTED_PROXIES: $(q '.services.core.environment.TRUSTED_PROXIES')"
  [ "$(q '.networks.default.ipam.config[0].subnet')" = 172.30.83.0/24 ] || fail "subnet: $(q '.networks.default.ipam.config[0].subnet')"
  # Inside the network, HOST is Caddy.
  [ "$(q '.services.caddy.networks.default.aliases | join(" ")')" = test.aishie.app ] || fail "Caddy's aliases: $(q '.services.caddy.networks.default.aliases')"
  [ "$(q '.services.core.environment.PUBLIC_URL')" = https://test.aishie.app ] || fail "PUBLIC_URL: $(q '.services.core.environment.PUBLIC_URL')"
  [ "$(q '.services.runtime.environment.CORE_BASE_URL_ALLOWLIST')" = https://test.aishie.app ] || fail "the runtime's allowlist"
  [ "$(q '.services.caddy.environment.HOST')" = test.aishie.app ] || fail "Caddy's HOST"
  # The runtime reads its configuration and secrets, and writes neither.
  [ "$(q '[.services.runtime.volumes[] | select(.read_only != true)] | length')" = 0 ] || fail "the runtime can write a mount"
  [ "$(q '.services.runtime.user')" = 65532:65532 ] || fail "the runtime's user: $(q '.services.runtime.user')"
  [ "$(q '.services.runtime.stop_grace_period')" = 30s ] || fail "the runtime's stop grace: $(q '.services.runtime.stop_grace_period')"
  [ "$(q '.services.postgres.image')" = postgres:18 ] || fail "PostgreSQL: $(q '.services.postgres.image')"
  # The web runs as its image's contract allows: its user, a read-only file
  # system, no capability, no new privileges.
  [ "$(q '.services.web.user')" = 65532:65532 ] || fail "the web's user: $(q '.services.web.user')"
  [ "$(q '.services.web.read_only')" = true ] || fail "the web's file system is writable"
  [ "$(q '.services.web.cap_drop | join(" ")')" = ALL ] || fail "the web's capabilities: $(q '.services.web.cap_drop')"
  [ "$(q '.services.web.security_opt | join(" ")')" = no-new-privileges:true ] || fail "the web's security_opt: $(q '.services.web.security_opt')"
  # aishie.env sets no FRAME_ANCESTORS: the web gets 'self', quotes and all,
  # never an empty value (which would let no page frame the app).
  [ "$(q '.services.web.environment.FRAME_ANCESTORS')" = "'self'" ] || fail "FRAME_ANCESTORS: «$(q '.services.web.environment.FRAME_ANCESTORS')»"
  if [ $case = deployed ]; then
    [ "$(q '.services.core.image')" = "$CORE" ] || fail "core runs $(q '.services.core.image')"
    [ "$(q '.services.runtime.image')" = "$RUNTIME" ] || fail "the runtime runs $(q '.services.runtime.image')"
    [ "$(q '.services.web.image')" = "$WEB" ] || fail "the web runs $(q '.services.web.image')"
  else
    [ "$(q '.services.core.image')" = aishie.invalid/aishie-core:not-deployed-yet ] || fail "core runs $(q '.services.core.image')"
  fi
done

# FRAME_ANCESTORS, as the operator may write it in aishie.env: given, it
# reaches the web as it is, CSP's single quotes included; empty, it is
# 'self', as unset.
case=frame-ancestors
cp "$work/etc/aishie.env" "$work/aishie.env.orig"
for given in "\"'self' https://canvas.example.edu\"=>'self' https://canvas.example.edu" \
  "\"'none'\"=>'none'" "\"'self'\"=>'self'" "=>'self'" "\"\"=>'self'"; do
  cp "$work/aishie.env.orig" "$work/etc/aishie.env"
  printf 'FRAME_ANCESTORS=%s\n' "${given%%=>*}" >> "$work/etc/aishie.env"
  got=$(compose config --format json | jq -r '.services.web.environment.FRAME_ANCESTORS')
  [ "$got" = "${given#*=>}" ] || fail "FRAME_ANCESTORS=${given%%=>*} reached the web as «$got», not «${given#*=>}»"
done
# ... and one left in the operator's shell does not: aishie-update and aishie
# clear it, as they clear the stack's other names.
for script in aishie-update aishie; do
  grep -q '^  AISHIE_SUBNET AISHIE_CADDY_IP RUNTIME_STOP_GRACE FRAME_ANCESTORS$' "$root/bin/$script" ||
    fail "bin/$script does not clear FRAME_ANCESTORS from its environment"
done
cp "$work/aishie.env.orig" "$work/etc/aishie.env"

# Settings missing: compose refuses, and names the one.
case=no-host
sed -i '/^HOST=/d' "$work/etc/aishie.env"
if out=$(compose config -q 2>&1); then fail "took aishie.env without HOST"; fi
grep -q "set HOST in /etc/aishie/aishie.env" <<< "$out" || fail "said: $out"

# The Caddyfile, for a public name and for localhost (CI's end to end).
case=caddy
caddy=${CADDY:-$(command -v caddy || true)}
for host in test.aishie.app localhost; do
  if [ -n "$caddy" ]; then
    out=$(HOST=$host "$caddy" validate --config "$root/caddy/Caddyfile" --adapter caddyfile 2>&1) || fail "caddy validate, HOST=$host: $out"
  else
    out=$(docker run --rm -e "HOST=$host" -v "$root/caddy:/etc/caddy:ro" "${CADDY_IMAGE:-caddy:2}" \
      caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1) || fail "caddy validate, HOST=$host: $out"
  fi
done

# Caddy's routes, as Caddy reads them: Core's paths to Core, uncompressed;
# the runtime's API without the browser's cookies, and nothing else of the
# runtime's (9090 never); everything else to the web. One line per route,
# in order: its paths => its handlers.
case="caddy routes"
if [ -n "$caddy" ]; then
  adapted=$(HOST=test.aishie.app "$caddy" adapt --config "$root/caddy/Caddyfile" --adapter caddyfile 2>/dev/null) || adapted=
else
  adapted=$(docker run --rm -e HOST=test.aishie.app -v "$root/caddy:/etc/caddy:ro" "${CADDY_IMAGE:-caddy:2}" \
    caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null) || adapted=
fi
routes=$(jq -r '
  .apps.http.servers[].routes[] | select(.match[0].host == ["test.aishie.app"]) | .handle[] | .routes[] |
  ((.match // [{path: ["*"]}])[0].path | join(" ")) + " => " +
  ([.handle[] | if .handler == "subroute" then .routes[].handle[] else . end |
    if .handler == "reverse_proxy" then "reverse_proxy " + ([.upstreams[].dial] | join(","))
    elif .handler == "headers" then "headers -" + (.request.delete | join(" -"))
    else .handler end] | join(", "))' <<< "${adapted:-null}" 2>&1) || routes="caddy adapt failed: $routes"
want='/v1/* /mcp /mcp/* /healthz /.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/* /.well-known/oauth-authorization-server /.well-known/oauth-authorization-server/* /.well-known/openid-configuration => reverse_proxy core:8080
/runtime/api/* => headers -Cookie, reverse_proxy runtime:9091
* => reverse_proxy web:8080'
[ "$routes" = "$want" ] || fail "the routes are
$routes
not
$want"
[ "$(jq '[.. | objects | select(.handler? == "reverse_proxy") | .upstreams[].dial | select(test(":9090$"))] | length' <<< "${adapted:-null}")" = 0 ] ||
  fail "something is routed to the runtime's 9090"

[ "$failed" = 0 ] && echo "config: ok"
exit "$failed"
