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
  # core.env reaches Core whole, its keys with the rest: compose passes the
  # file, not a list of names, so a key added to it needs nothing here.
  for n in DATABASE_URL SIGNING_KEY SECRETS_KEY; do
    [ "$(q ".services.core.environment.$n")" = "$(sed -n "s/^$n=//p" "$work/etc/core.env")" ] || fail "Core is not given core.env's $n"
  done
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

# Caddy, from a binary on PATH (or $CADDY), else from its image.
caddy=${CADDY:-$(command -v caddy || true)}
# caddy_in DIR HOST COMMAND: caddy validate, or adapt, of DIR's Caddyfile
# (a caddy/ directory, front-proxy/ in it), for HOST.
caddy_in() {
  if [ -n "$caddy" ]; then
    HOST=$2 "$caddy" "$3" --config "$1/Caddyfile" --adapter caddyfile
  else
    docker run --rm -e "HOST=$2" -v "$1:/etc/caddy:ro" "${CADDY_IMAGE:-caddy:2}" caddy "$3" --config /etc/caddy/Caddyfile --adapter caddyfile
  fi
}
# routes JSON: the routes for test.aishie.app in Caddy's JSON, one line per
# route, in order: its paths (or not remote_ip, for the front proxy's
# refusal) => its handlers.
routes() {
  jq -r '
    .apps.http.servers[].routes[] | select(.match[0].host == ["test.aishie.app"]) | .handle[] | .routes[] |
    (if .match[0].not then "not remote_ip" else ((.match // [{path: ["*"]}])[0].path | join(" ")) end) + " => " +
    ([.handle[] | if .handler == "subroute" then .routes[].handle[] else . end |
      if .handler == "reverse_proxy" then "reverse_proxy " + ([.upstreams[].dial] | join(","))
      elif .handler == "headers" then "headers -" + (.request.delete | join(" -"))
      elif .handler == "static_response" then "respond \(.status_code)"
      else .handler end] | join(", "))' <<< "${1:-null}" 2>&1
}
# render NAME SETTING...: a copy of caddy/ in $work/NAME/caddy, with the two
# files of front-proxy/ as aishie front-proxy writes them from an aishie.env
# that says the settings given. No network: the fetch of Cloudflare's
# addresses fails, and the list pinned in caddy/cloudflare-ips is taken.
render() {
  local at=$work/$1
  shift
  rm -rf "$at"
  mkdir -p "$at/etc" "$at/state" "$at/bin"
  cp -R "$root/caddy" "$at/caddy"
  { echo HOST=test.aishie.app; printf '%s\n' "$@"; } > "$at/etc/aishie.env"
  printf '#!/bin/sh\necho "curl: (7) no network in tests/config.sh" >&2\nexit 7\n' > "$at/bin/curl"
  chmod +x "$at/bin/curl"
  PATH="$at/bin:$PATH" AISHIE_APP=$at AISHIE_ETC=$at/etc AISHIE_STATE=$at/state AISHIE_FRONT_PROXY_LIB=1 \
    sh -c '. "$0"; fp_write' "$root/bin/aishie-front-proxy" > "$at/out" 2>&1 || fail "aishie front-proxy did not write: $(cat "$at/out")"
}
# Core's routes, the runtime's API's and the web's, as with nothing in front.
want='/v1/* /mcp /mcp/* /healthz /.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/* /.well-known/oauth-authorization-server /.well-known/oauth-authorization-server/* /.well-known/openid-configuration => reverse_proxy core:8080
/runtime/api/* => headers -Cookie, reverse_proxy runtime:9091
* => reverse_proxy web:8080'

# The Caddyfile as this repository has it, with nothing in front, for a
# public name and for localhost (CI's end to end); front-proxy/ is what
# aishie front-proxy writes with nothing in front.
case=caddy
for host in test.aishie.app localhost; do
  out=$(caddy_in "$root/caddy" "$host" validate 2>&1) || fail "caddy validate, HOST=$host: $out"
done
render none
for f in global site; do
  cmp -s "$work/none/caddy/front-proxy/$f.caddy" "$root/caddy/front-proxy/$f.caddy" ||
    fail "caddy/front-proxy/$f.caddy is not what aishie front-proxy writes with nothing in front: $(diff "$root/caddy/front-proxy/$f.caddy" "$work/none/caddy/front-proxy/$f.caddy")"
done

# Caddy's routes, as Caddy reads them: Core's paths to Core, uncompressed;
# the runtime's API without the browser's cookies, and nothing else of the
# runtime's (9090 never); everything else to the web. Each proxy gives
# X-Forwarded-For as the client's address Caddy takes ({client_ip}), and
# Caddy believes no proxy about it.
case="caddy routes"
adapted=$(caddy_in "$root/caddy" test.aishie.app adapt 2>/dev/null) || adapted=
got=$(routes "$adapted")
[ "$got" = "$want" ] || fail "the routes are
$got
not
$want"
[ "$(jq '[.. | objects | select(.handler? == "reverse_proxy") | .upstreams[].dial | select(test(":9090$"))] | length' <<< "${adapted:-null}")" = 0 ] ||
  fail "something is routed to the runtime's 9090"
[ "$(jq -c '[.. | objects | select(.handler? == "reverse_proxy") | .headers.request.set["X-Forwarded-For"]]' <<< "${adapted:-null}")" = \
  '[["{http.vars.client_ip}"],["{http.vars.client_ip}"],["{http.vars.client_ip}"]]' ] ||
  fail "a proxy does not give X-Forwarded-For as {client_ip}: $(jq -c '[.. | objects | select(.handler? == "reverse_proxy") | .headers]' <<< "${adapted:-null}")"
[ "$(jq -c '[.apps.http.servers[] | .trusted_proxies, .client_ip_headers | select(. != null)]' <<< "${adapted:-null}")" = '[]' ] ||
  fail "Caddy believes a proxy, with nothing in front"
[ "$(jq -c '.apps.tls.automation // null' <<< "${adapted:-null}")" = null ] || fail "Caddy's certificates are not its defaults: $(jq -c .apps.tls <<< "$adapted")"

# Behind Cloudflare (FRONT_PROXY=cloudflare), as aishie front-proxy writes
# it: Caddy believes Cloudflare's addresses alone, which name the visitor in
# CF-Connecting-IP, else in X-Forwarded-For read from the right; gets its
# certificates as before; and its routes are as before. With
# FRONT_PROXY_ONLY=yes, a first route refuses (403) a request from neither
# Cloudflare's addresses nor a private one.
pinned=$(grep -v '^#' "$root/caddy/cloudflare-ips" | jq -R . | jq -sc .)
for only in no yes; do
  case="caddy behind cloudflare, FRONT_PROXY_ONLY=$only"
  render "cloudflare-$only" FRONT_PROXY=cloudflare "FRONT_PROXY_ONLY=$only"
  dir=$work/cloudflare-$only/caddy
  out=$(caddy_in "$dir" test.aishie.app validate 2>&1) || fail "caddy validate: $out"
  adapted=$(caddy_in "$dir" test.aishie.app adapt 2>/dev/null) || adapted=
  for s in $(jq -r '.apps.http.servers | keys[]' <<< "${adapted:-null}" 2>/dev/null); do
    [ "$(jq -c ".apps.http.servers.$s.trusted_proxies" <<< "$adapted")" = "{\"ranges\":$pinned,\"source\":\"static\"}" ] ||
      fail "server $s trusts $(jq -c ".apps.http.servers.$s.trusted_proxies" <<< "$adapted")"
    [ "$(jq -c ".apps.http.servers.$s | [.client_ip_headers, .trusted_proxies_strict]" <<< "$adapted")" = '[["CF-Connecting-IP","X-Forwarded-For"],1]' ] ||
      fail "server $s takes the client's address as $(jq -c ".apps.http.servers.$s | [.client_ip_headers, .trusted_proxies_strict]" <<< "$adapted")"
  done
  # One server, 443's: the redirect from 80 is made when Caddy starts.
  [ "$(jq -r '.apps.http.servers | length' <<< "${adapted:-null}")" = 1 ] || fail "not Caddy's one server: $(jq -c '.apps.http.servers // {} | keys' <<< "${adapted:-null}")"
  [ "$(jq -c '.apps.tls.automation // null' <<< "${adapted:-null}")" = null ] || fail "Caddy's certificates are not its defaults: $(jq -c .apps.tls <<< "${adapted:-null}")"
  got=$(routes "$adapted")
  if [ "$only" = yes ]; then
    [ "$got" = "not remote_ip => respond 403
$want" ] || fail "the routes are
$got"
    [ "$(jq -c '.apps.http.servers[].routes[] | select(.match[0].host == ["test.aishie.app"]) | .handle[].routes[0].match[0].not[0].remote_ip.ranges' <<< "${adapted:-null}")" = \
      "$(jq -c '. + ["192.168.0.0/16","172.16.0.0/12","10.0.0.0/8","127.0.0.1/8","fd00::/8","::1"]' <<< "$pinned")" ] ||
      fail "the refusal lets through $(jq -c '.apps.http.servers[].routes[] | select(.match[0].host == ["test.aishie.app"]) | .handle[].routes[0].match' <<< "${adapted:-null}")"
  else
    [ "$got" = "$want" ] || fail "the routes are
$got"
  fi
done

[ "$failed" = 0 ] && echo "config: ok"
exit "$failed"
