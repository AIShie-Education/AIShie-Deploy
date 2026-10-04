#!/usr/bin/env bash
# aishie front-proxy (bin/aishie-front-proxy) against the stand-ins of
# tests/fakes.sh: Cloudflare's two lists of its addresses, and what answers
# http://HOST/.well-known/acme-challenge/, played by curl; HOST's address in
# public DNS by dig, resolvectl and curl, and this server's /etc/hosts,
# which names HOST 127.0.1.1 as Ubuntu's does; Caddy, its reload included,
# by docker. Its pure parts are sourced with
# AISHIE_FRONT_PROXY_LIB=1, in sh as the server runs them; the rest runs
# whole, through aishie, as root (id played below) and its weekly timer run
# it. No network is reached. tests/config.sh has Caddy read what it writes.
#
#   make test
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
. "$here/fakes.sh"
make_fakes "$work/bin"
cat > "$work/bin/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -u ]; then echo "${NOT_ROOT:-0}"; else exec /usr/bin/id "$@"; fi
EOF
chmod +x "$work/bin"/*

failed=0
fail() { echo "FAIL aishie-front-proxy $case: $*" >&2; failed=1; }

# Cloudflare's addresses as this repository pins them, one to a line, IPv4's
# first; and a range Cloudflare does not have, to tell a list fetched from
# the pinned one.
PINNED=$(grep -v '^#' "$root/caddy/cloudflare-ips")
NEW4=198.51.100.0/24
# An address of Cloudflare's, in 104.16.0.0/13, as it gives a proxied name;
# and one that is not, this server's own, as an unproxied name has it.
CF_ADDR=104.21.32.1
OWN_ADDR=203.0.113.10

# setup CASE [SETTING...]: a server set up with this copy (its Caddyfile, and
# Caddy's front-proxy/ as setup-server.sh installs it), aishie.env saying
# HOST and the settings given, Caddy running, and Cloudflare listing the
# pinned addresses and NEW4, each list with no newline at its end, as
# Cloudflare serves them. HOST is proxied: public DNS gives it two of
# Cloudflare's addresses; and /etc/hosts names it as Ubuntu's does, this
# server itself at 127.0.1.1, where Caddy answers with no Cloudflare in
# front.
setup() {
  case=$1
  shift
  export FAKE=$work/$case CALLS=$work/$case/calls
  mkdir -p "$FAKE/etc" "$FAKE/state" "$FAKE/app/caddy/front-proxy" "$FAKE/running" "$FAKE/cloudflare"
  : > "$CALLS"
  export AISHIE_ETC=$FAKE/etc AISHIE_STATE=$FAKE/state AISHIE_APP=$FAKE/app
  unset CF_DOWN CF_STATUS CF_EDGE CADDY_RELOAD_FAIL NOT_ROOT NO_DIG DNS_BLOCKED NO_RESOLVED DOH_DOWN
  cp "$root/caddy/Caddyfile" "$root/caddy/cloudflare-ips" "$FAKE/app/caddy/"
  install -m 644 "$root"/caddy/front-proxy/*.caddy "$FAKE/app/caddy/front-proxy/"
  printf 'HOST=test.aishie.app\nENVIRONMENT=edge\n' > "$FAKE/etc/aishie.env"
  for s in "$@"; do echo "$s" >> "$FAKE/etc/aishie.env"; done
  touch "$FAKE/running/caddy"
  lists "$NEW4"
  printf '127.0.0.1 localhost\n127.0.1.1 test.aishie.app test\n' > "$FAKE/hosts"
  record "$CF_ADDR" 172.67.155.1
}
# record [ADDRESS...]: HOST's A records in public DNS from now on (none,
# with no ADDRESS).
record() {
  mkdir -p "$FAKE/dns"
  printf '%s\n' "$@" | sed '/^$/d' > "$FAKE/dns/test.aishie.app"
}
# lists [EXTRA4]: what Cloudflare lists from now on: the pinned addresses,
# and EXTRA4 after its IPv4 ones.
lists() {
  printf '%s' "$(grep -F . <<< "$PINNED"; [ -z "${1:-}" ] || echo "$1")" > "$FAKE/cloudflare/ips-v4"
  printf '%s' "$(grep -F : <<< "$PINNED")" > "$FAKE/cloudflare/ips-v6"
}
# setting NAME VALUE: aishie.env says it from now on (none, with no VALUE).
setting() {
  sed -i "/^$1=/d" "$AISHIE_ETC/aishie.env"
  [ $# -lt 2 ] || echo "$1=$2" >> "$AISHIE_ETC/aishie.env"
}
# fp [ARGS...]: aishie front-proxy, through aishie, as root runs it.
fp() { PATH="$work/bin:$PATH" "$root/bin/aishie" front-proxy "$@" > "$FAKE/out" 2>&1; }
# lib FUNCTION ARGS...: one of its functions, in sh.
lib() { PATH="$work/bin:$PATH" AISHIE_FRONT_PROXY_LIB=1 sh -c '. "$0"; "$@"' "$root/bin/aishie-front-proxy" "$@"; }
called() { grep -q -- "$1" "$CALLS"; }
# cloudflares ADDRESS: true when the pinned list holds it, in sh.
cloudflares() {
  AISHIE_FRONT_PROXY_LIB=1 sh -c '. "$0"; fp_list=$(fp_check_ranges < "$1"); fp_cloudflare "$2"' \
    "$root/bin/aishie-front-proxy" "$root/caddy/cloudflare-ips" "$1"
}
said() { grep -q -- "$1" "$FAKE/out"; }
reloads() { grep -c 'exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile$' "$CALLS" || true; }
fetches() { grep -c 'https://www.cloudflare.com/ips-v' "$CALLS" || true; }
dir() { echo "$AISHIE_APP/caddy/front-proxy"; }
# trusted: the ranges global.caddy has Caddy trust, one to a line.
trusted() { sed -n $'s/^\ttrusted_proxies static //p' "$(dir)/global.caddy" | tr ' ' '\n'; }
# sums: the two files' sums, and the list kept's, if there is one.
sums() {
  (cd "$(dir)" && sha256sum global.caddy site.caddy) || true
  sha256sum "$AISHIE_STATE/cloudflare-ips" 2>/dev/null || true
}
is_repos() { cmp -s "$(dir)/$1.caddy" "$root/caddy/front-proxy/$1.caddy"; }
# both_repos: both files are this copy's, as with nothing in front.
both_repos() { is_repos global && is_repos site; }

# A list of ranges is taken whole or not at all: every line a range of
# either family, both families there, none wider than a /8 (an IPv6 /16);
# comments, blank lines, CRLFs and capitals are no matter. What is taken
# comes back IPv4's first.
case=ranges
[ "$(lib fp_check_ranges < "$root/caddy/cloudflare-ips")" = "$PINNED" ] || fail "the pinned list is not taken as it is"
[ "$(grep -c . <<< "$PINNED")" = 22 ] || fail "the pinned list has $(grep -c . <<< "$PINNED") ranges"
got=$(printf '# a comment\r\n2400:CB00::/32\r\n\r\n  173.245.48.0/20 \r\n::1/128\n2a06:98c0:0:0:0:0:0:0/29\n' | lib fp_check_ranges) ||
  fail "a list with comments, CRLFs and capitals is refused: $got"
[ "$got" = "$(printf '173.245.48.0/20\n2400:cb00::/32\n::1/128\n2a06:98c0:0:0:0:0:0:0/29')" ] || fail "it came back as «$got»"
for bad in '0.0.0.0/0\n2400:cb00::/32' '173.245.48.0/20\n::/0' '173.245.48.0/20' '2400:cb00::/32' '' '<html><body>Just a moment...</body></html>' \
  '256.0.0.0/8\n2400:cb00::/32' '173.245.48.0\n2400:cb00::/32' '173.245.48.0/20\n2400:cb00:1:2:3:4:5/64' '173.245.48.0/20\n1::2::3/64' \
  '173.245.48.0/20 103.21.244.0/22\n2400:cb00::/32' '173.245.48.0/20\n2400:cb00::/32\ntrusted_proxies_strict'; do
  # shellcheck disable=SC2059 # the list, with its \n
  if got=$(printf "$bad" | lib fp_check_ranges); then fail "took «$bad» as a list: $got"; fi
done
too_many=$(for i in $(seq 1 201); do echo "10.$((i / 256)).$((i % 256)).0/24"; done; echo 2400:cb00::/32)
if lib fp_check_ranges <<< "$too_many" > /dev/null; then fail "took 202 ranges as Cloudflare's"; fi

# Nothing in front, as a server is set up: the two files are this copy's,
# nothing is fetched, Caddy is not reloaded, and nothing is asked of HOST.
setup none
fp || fail "exit $?: $(cat "$FAKE/out")"
both_repos || fail "the files are not this copy's"
said "FRONT_PROXY is not set: Caddy takes a client's address from the connection" || fail "said: $(cat "$FAKE/out")"
said "Caddy has these settings already: nothing changed" || fail "said: $(cat "$FAKE/out")"
[ "$(fetches)" = 0 ] || fail "fetched Cloudflare's addresses with no FRONT_PROXY"
[ "$(reloads)" = 0 ] || fail "reloaded Caddy for nothing"
! called "acme-challenge" || fail "asked HOST something"
! ls "$(dir)"/*.before "$(dir)"/*.new >/dev/null 2>&1 || fail "left $(ls "$(dir)"/*.before "$(dir)"/*.new 2>/dev/null)"

# FRONT_PROXY=cloudflare: Cloudflare's two lists fetched, over HTTPS alone,
# and kept with when; Caddy trusts those ranges, the visitor's address from
# CF-Connecting-IP (else X-Forwarded-For, from the right), and nothing else
# changes; requests from anywhere are still taken; Caddy
# reloaded once; and the challenge path asked from here, which Cloudflare
# passes to Caddy: at the address public DNS gives HOST, Cloudflare's, as
# Let's Encrypt asks it, not at 127.0.1.1, where this server's own lookup
# finds HOST in /etc/hosts and Caddy answers with no Cloudflare in front.
setup cloudflare FRONT_PROXY=cloudflare
fp || fail "exit $?: $(cat "$FAKE/out")"
[ "$(trusted)" = "$(grep -F . <<< "$PINNED"; echo "$NEW4"; grep -F : <<< "$PINNED")" ] || fail "Caddy trusts $(trusted | tr '\n' ' ')"
grep -qx $'\ttrusted_proxies_strict' "$(dir)/global.caddy" || fail "not trusted_proxies_strict"
grep -qx $'\tclient_ip_headers CF-Connecting-IP X-Forwarded-For' "$(dir)/global.caddy" || fail "the client's address is not taken from CF-Connecting-IP"
[ "$(grep -v '^#' "$(dir)/global.caddy" | tr -d '\t')" = "servers {
trusted_proxies static $(trusted | tr '\n' ' ' | sed 's/ $//')
trusted_proxies_strict
client_ip_headers CF-Connecting-IP X-Forwarded-For
}" ] || fail "global.caddy says more than whose addresses to believe: $(cat "$(dir)/global.caddy")"
is_repos site || fail "site.caddy refuses something, with no FRONT_PROXY_ONLY: $(cat "$(dir)/site.caddy")"
for f in global site; do [ "$(stat -c %a "$(dir)/$f.caddy")" = 644 ] || fail "$f.caddy is $(stat -c %a "$(dir)/$f.caddy")"; done
[ "$(fetches)" = 2 ] || fail "fetched $(fetches) times"
called "curl -fsS --proto =https .* https://www.cloudflare.com/ips-v4$" || fail "ips-v4 not fetched over HTTPS alone: $(grep cloudflare.com "$CALLS")"
[ "$(lib fp_check_ranges < "$AISHIE_STATE/cloudflare-ips")" = "$(trusted)" ] || fail "the list kept is not the one in force"
grep -q "^# Cloudflare's addresses, fetched from https://www.cloudflare.com/ips-v4 and /ips-v6 at 20[0-9-]*T[0-9:]*Z by aishie front-proxy$" "$AISHIE_STATE/cloudflare-ips" ||
  fail "the list kept does not say when it was fetched: $(head -n 1 "$AISHIE_STATE/cloudflare-ips")"
[ "$(reloads)" = 1 ] || fail "Caddy reloaded $(reloads) times"
said "on connections from Cloudflare's 23 ranges: fetched from www.cloudflare.com now" || fail "said: $(cat "$FAKE/out")"
said "FRONT_PROXY_ONLY is not yes: a request from anywhere else is taken too" || fail "said: $(cat "$FAKE/out")"
said "Caddy reloaded with them" || fail "said: $(cat "$FAKE/out")"
called "^dig +short +time=5 +tries=2 A test.aishie.app @1.1.1.1$" || fail "public DNS not asked by dig at 1.1.1.1: $(grep -e '^dig' -e '^resolvectl' "$CALLS")"
if grep '^dig ' "$CALLS" | grep -qv ' @'; then fail "dig asked systemd-resolved's stub, which answers from /etc/hosts"; fi
said "the DNS record of test.aishie.app is proxied: public DNS (dig, at 1.1.1.1) gives $CF_ADDR, one of Cloudflare's addresses" || fail "said: $(cat "$FAKE/out")"
called "curl -sS --max-time 15 --resolve test.aishie.app:80:$CF_ADDR -o /dev/null -D .* http://test.aishie.app/.well-known/acme-challenge/aishie-front-proxy-check$" ||
  fail "the challenge path not asked at $CF_ADDR: $(grep acme "$CALLS")"
if grep acme-challenge "$CALLS" | grep -qv -- "--resolve test.aishie.app:80:"; then fail "asked the challenge path where /etc/hosts sends it: $(grep acme "$CALLS")"; fi
said "goes through Cloudflare (cf-ray 8c0ffee0a1b2c3d4-SIN) to Caddy, which answers it (308)" || fail "said: $(cat "$FAKE/out")"
! said "warning" || fail "warned: $(cat "$FAKE/out")"
! ls "$(dir)"/*.before "$AISHIE_STATE"/cloudflare-ips.* "$AISHIE_STATE"/front-proxy.* >/dev/null 2>&1 ||
  fail "left $(ls "$(dir)"/*.before "$AISHIE_STATE"/cloudflare-ips.* "$AISHIE_STATE"/front-proxy.* 2>/dev/null)"

# ... again, every week by the timer: fetched again, and the same, so Caddy
# is not reloaded.
before=$(sums | grep -v cloudflare-ips)
: > "$CALLS"
fp || fail "again: exit $?: $(cat "$FAKE/out")"
[ "$(fetches)" = 2 ] || fail "again: fetched $(fetches) times"
[ "$(reloads)" = 0 ] || fail "again: Caddy reloaded for the same list"
said "Caddy has these settings already: nothing changed" || fail "again: said: $(cat "$FAKE/out")"
[ "$(sums | grep -v cloudflare-ips)" = "$before" ] || fail "again: the files changed"

# ... Cloudflare lists another range: Caddy trusts it, reloaded.
lists 192.0.2.0/24
: > "$CALLS"
fp || fail "a new range: exit $?: $(cat "$FAKE/out")"
trusted | grep -qx 192.0.2.0/24 || fail "a new range is not trusted"
! trusted | grep -qx "$NEW4" || fail "a range Cloudflare no longer lists is still trusted"
[ "$(reloads)" = 1 ] || fail "a new range: Caddy reloaded $(reloads) times"

# ... the fetch fails, or brings something else than a whole list: the last
# list fetched stays in force, as it was, said with when it was fetched and
# why it is kept; nothing is written or reloaded, and the run does not fail.
kept=$(sums)
when=$(sed -n '1s/.* at \([^ ]*\) by .*/\1/p' "$AISHIE_STATE/cloudflare-ips")
for how in CF_DOWN=1 CF_STATUS=500 html no-v6 slash-0; do
  : > "$CALLS"
  lists 192.0.2.0/24
  case $how in
    html) printf '<!DOCTYPE html><title>Just a moment...</title>' > "$FAKE/cloudflare/ips-v4" ;;
    no-v6) : > "$FAKE/cloudflare/ips-v6" ;;
    slash-0) printf '0.0.0.0/0' > "$FAKE/cloudflare/ips-v4" ;;
    *) export "${how?}" ;;
  esac
  fp || fail "$how: exit $?: $(cat "$FAKE/out")"
  unset CF_DOWN CF_STATUS
  [ "$(sums)" = "$kept" ] || fail "$how: changed what was kept: $(diff <(echo "$kept") <(sums))"
  [ "$(reloads)" = 0 ] || fail "$how: Caddy reloaded"
  said "Cloudflare's 23 ranges: the last list fetched, at $when, kept, as this time it " || fail "$how: said: $(cat "$FAKE/out")"
  case $how in
    CF_DOWN=1) said "could not fetch https://www.cloudflare.com/ips-v4 (curl: (6) Could not resolve host: www.cloudflare.com)" || fail "$how: said: $(cat "$FAKE/out")" ;;
    CF_STATUS=500) said "returned error: 500" || fail "$how: said: $(cat "$FAKE/out")" ;;
    html) said "a list that is not whole: «<!doctype html><title>just a moment...</title>» is not an address range" || fail "$how: said: $(cat "$FAKE/out")" ;;
    no-v6) said "a list that is not whole: it has no IPv6 range" || fail "$how: said: $(cat "$FAKE/out")" ;;
    slash-0) said "«0.0.0.0/0» is not an address range" || fail "$how: said: $(cat "$FAKE/out")" ;;
  esac
done

# A server that never fetched a list, and cannot: the list pinned in this
# repository, said; Caddy reloaded with it.
setup pinned FRONT_PROXY=cloudflare
CF_DOWN=1 fp || fail "exit $?: $(cat "$FAKE/out")"
[ "$(trusted)" = "$PINNED" ] || fail "Caddy trusts $(trusted | tr '\n' ' '), not the pinned list"
[ ! -e "$AISHIE_STATE/cloudflare-ips" ] || fail "kept the pinned list as one fetched"
said "Cloudflare's 22 ranges: the list pinned in $AISHIE_APP/caddy/cloudflare-ips, as none was fetched before and this time it could not fetch" ||
  fail "said: $(cat "$FAKE/out")"
[ "$(reloads)" = 1 ] || fail "Caddy reloaded $(reloads) times"
# ... and with that copy not whole either: nothing changes, and it fails.
printf '173.245.48.0/20\n' > "$AISHIE_APP/caddy/cloudflare-ips"
before=$(sums)
: > "$CALLS"
if CF_DOWN=1 fp; then fail "passed with no list at all"; fi
said "no list of Cloudflare's addresses: this time it could not fetch .* and $AISHIE_APP/caddy/cloudflare-ips is not whole either (it has no IPv6 range): nothing was changed" ||
  fail "said: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "changed the files"
[ "$(reloads)" = 0 ] || fail "Caddy reloaded"

# FRONT_PROXY_ONLY=yes: Caddy's first route refuses (403) a request that
# comes from neither Cloudflare's addresses nor a private one; no again
# takes them back.
setup only FRONT_PROXY=cloudflare FRONT_PROXY_ONLY=yes
fp || fail "exit $?: $(cat "$FAKE/out")"
ranges=$(trusted | tr '\n' ' ')
grep -qxF "@not_from_front_proxy not remote_ip ${ranges}private_ranges" "$(dir)/site.caddy" || fail "site.caddy: $(cat "$(dir)/site.caddy")"
grep -A 2 -xF 'handle @not_from_front_proxy {' "$(dir)/site.caddy" | grep -qF 'respond "This server is reached through Cloudflare alone." 403' ||
  fail "the refusal is not a 403: $(cat "$(dir)/site.caddy")"
said "FRONT_PROXY_ONLY=yes: a request from anywhere else but a private address is refused (403)" || fail "said: $(cat "$FAKE/out")"
[ "$(reloads)" = 1 ] || fail "Caddy reloaded $(reloads) times"
setting FRONT_PROXY_ONLY no
: > "$CALLS"
fp || fail "no: exit $?: $(cat "$FAKE/out")"
is_repos site || fail "no: site.caddy still refuses: $(cat "$(dir)/site.caddy")"
[ "$(reloads)" = 1 ] || fail "no: Caddy reloaded $(reloads) times"
# ... and FRONT_PROXY taken out: both files are this copy's again, nothing
# fetched, Caddy reloaded; the list kept stays for another time.
setting FRONT_PROXY
setting FRONT_PROXY_ONLY
: > "$CALLS"
fp || fail "none again: exit $?: $(cat "$FAKE/out")"
both_repos || fail "none again: the files are not this copy's"
[ "$(fetches)" = 0 ] || fail "none again: fetched"
[ "$(reloads)" = 1 ] || fail "none again: Caddy reloaded $(reloads) times"
[ -s "$AISHIE_STATE/cloudflare-ips" ] || fail "none again: the list kept was removed"

# Settings that mean nothing here: refused, with nothing fetched, written or
# reloaded.
setup refused
before=$(sums)
for s in "FRONT_PROXY=akamai" "FRONT_PROXY=Cloudflare" "FRONT_PROXY_ONLY=yes" "FRONT_PROXY=cloudflare FRONT_PROXY_ONLY=maybe"; do
  setting FRONT_PROXY
  setting FRONT_PROXY_ONLY
  for kv in $s; do setting "${kv%%=*}" "${kv#*=}"; done
  : > "$CALLS"
  if fp; then fail "took «$s»"; fi
  case $s in
    FRONT_PROXY=[aC]*) said "FRONT_PROXY=${s#*=} in $AISHIE_ETC/aishie.env: the front proxy known here is cloudflare (unset for none): nothing was changed" || fail "«$s»: said: $(cat "$FAKE/out")" ;;
    FRONT_PROXY_ONLY=yes) said "FRONT_PROXY_ONLY=yes in $AISHIE_ETC/aishie.env, with no FRONT_PROXY: it would refuse everyone" || fail "«$s»: said: $(cat "$FAKE/out")" ;;
    *) said "FRONT_PROXY_ONLY=maybe in $AISHIE_ETC/aishie.env: yes, or no" || fail "«$s»: said: $(cat "$FAKE/out")" ;;
  esac
  [ "$(sums)" = "$before" ] || fail "«$s»: changed the files"
  [ "$(fetches)" = 0 ] || fail "«$s»: fetched"
  [ "$(reloads)" = 0 ] || fail "«$s»: Caddy reloaded"
done

# Caddy refuses the reload: the files are put back as they were, Caddy's
# error shown, and the run fails; the run after, which Caddy takes, writes
# them again.
setup reload-refused FRONT_PROXY=cloudflare
before=$(sums)
if CADDY_RELOAD_FAIL=1 fp; then fail "passed with the reload refused"; fi
said "as the test asks" || fail "Caddy's error not shown: $(cat "$FAKE/out")"
said "Caddy refused them (above): $(dir) is put back as it was, and Caddy goes on as before" || fail "said: $(cat "$FAKE/out")"
both_repos || fail "the files were not put back"
! ls "$(dir)"/*.before >/dev/null 2>&1 || fail "left $(ls "$(dir)"/*.before)"
fp || fail "then: exit $?: $(cat "$FAKE/out")"
trusted | grep -qx "$NEW4" || fail "then: not written again"
said "Caddy reloaded with them" || fail "then: said: $(cat "$FAKE/out")"

# Caddy not running: the files written, for when it starts.
setup caddy-stopped FRONT_PROXY=cloudflare
rm "$FAKE/running/caddy"
fp || fail "exit $?: $(cat "$FAKE/out")"
[ "$(reloads)" = 0 ] || fail "reloaded a Caddy that is not running"
trusted | grep -qx "$NEW4" || fail "not written"
said "Caddy is not running: it reads them when it starts" || fail "said: $(cat "$FAKE/out")"

# What answers http://HOST/.well-known/acme-challenge/, asked at the address
# public DNS gives HOST, as Let's Encrypt asks it: each said, and never a
# failure of the run.
for edge in 301 403 521 no-ray down; do
  setup "challenge-$edge" FRONT_PROXY=cloudflare
  CF_EDGE=$edge fp || fail "exit $?: $(cat "$FAKE/out")"
  case $edge in
    301) said "warning: Cloudflare (cf-ray 8c0ffee0a1b2c3d4-HKG) redirects http://test.aishie.app/.well-known/acme-challenge/aishie-front-proxy-check itself (301): Always Use HTTPS" ||
      fail "said: $(cat "$FAKE/out")" ;;
    403 | 521) said "warning: Cloudflare (cf-ray 8c0ffee0a1b2c3d4-HKG) answers .* with $edge: Let's Encrypt's HTTP-01 challenges do not reach Caddy" ||
      fail "said: $(cat "$FAKE/out")" ;;
    no-ray) said "warning: http://test.aishie.app/.well-known/acme-challenge/aishie-front-proxy-check, asked at $CF_ADDR, is answered (200) without a cf-ray" ||
      fail "said: $(cat "$FAKE/out")" ;;
    down) said "warning: could not ask .* at $CF_ADDR from this server (curl: (7) Failed to connect" || fail "said: $(cat "$FAKE/out")" ;;
  esac
  ! ls "$AISHIE_STATE"/front-proxy.* >/dev/null 2>&1 || fail "left $(ls "$AISHIE_STATE"/front-proxy.* 2>/dev/null)"
done

# The record not proxied: public DNS gives HOST this server's own address,
# none of Cloudflare's, which is said; the challenge path, which Cloudflare
# has no part in then, is not asked.
setup challenge-direct FRONT_PROXY=cloudflare
record "$OWN_ADDR"
fp || fail "exit $?: $(cat "$FAKE/out")"
said "the DNS record of test.aishie.app is not proxied: public DNS (dig, at 1.1.1.1) gives $OWN_ADDR, which is none of Cloudflare's addresses, and people reach this server's own address" ||
  fail "said: $(cat "$FAKE/out")"
! said "warning" || fail "warned: $(cat "$FAKE/out")"
! called "acme-challenge" || fail "asked the challenge path of a name not proxied"
# ... nor with one address of Cloudflare's and one not: Let's Encrypt may
# take either.
record "$CF_ADDR" "$OWN_ADDR"
fp || fail "two addresses: exit $?: $(cat "$FAKE/out")"
said "is not proxied: public DNS (dig, at 1.1.1.1) gives $OWN_ADDR, which is none of Cloudflare's" || fail "two addresses: said: $(cat "$FAKE/out")"
# ... with FRONT_PROXY_ONLY=yes, the people who reach this server's own
# address are refused, which is said.
setup challenge-direct-only FRONT_PROXY=cloudflare FRONT_PROXY_ONLY=yes
record "$OWN_ADDR"
fp || fail "exit $?: $(cat "$FAKE/out")"
said "warning: FRONT_PROXY_ONLY=yes refuses the people who reach this server's own address: proxy the record first" || fail "said: $(cat "$FAKE/out")"

# /etc/hosts decides nothing, either way: every case above has Ubuntu's,
# naming HOST 127.0.1.1, and HOST is proxied as public DNS has it; nor does
# one that names HOST at Cloudflare's address make a record proxied that
# public DNS has at this server's own.
setup hosts-cloudflare FRONT_PROXY=cloudflare
printf '127.0.0.1 localhost\n%s test.aishie.app\n' "$CF_ADDR" > "$FAKE/hosts"
record "$OWN_ADDR"
fp || fail "exit $?: $(cat "$FAKE/out")"
said "is not proxied: public DNS (dig, at 1.1.1.1) gives $OWN_ADDR" || fail "said: $(cat "$FAKE/out")"

# How public DNS is asked, which is said: dig at 1.1.1.1, else at 8.8.8.8;
# with no dig, resolvectl, past /etc/hosts and its cache, which asks the
# server's DNS servers; with neither, Cloudflare's DNS over HTTPS, by curl.
setup dns-8888 FRONT_PROXY=cloudflare
DNS_BLOCKED=1.1.1.1 fp || fail "exit $?: $(cat "$FAKE/out")"
said "is proxied: public DNS (dig, at 8.8.8.8) gives $CF_ADDR" || fail "said: $(cat "$FAKE/out")"
said "goes through Cloudflare (cf-ray 8c0ffee0a1b2c3d4-SIN) to Caddy" || fail "said: $(cat "$FAKE/out")"
setup dns-resolvectl FRONT_PROXY=cloudflare
NO_DIG=1 fp || fail "exit $?: $(cat "$FAKE/out")"
[ "$(grep -c '^dig ' "$CALLS")" = 1 ] || fail "dig asked again once it was not installed: $(grep '^dig ' "$CALLS")"
called "^resolvectl --cache=no --synthesize=no --zone=no --legend=no -4 query test.aishie.app$" || fail "resolvectl not asked past /etc/hosts: $(grep resolvectl "$CALLS")"
said "is proxied: public DNS (resolvectl, past /etc/hosts and its cache) gives $CF_ADDR" || fail "said: $(cat "$FAKE/out")"
said "goes through Cloudflare (cf-ray 8c0ffee0a1b2c3d4-SIN) to Caddy" || fail "said: $(cat "$FAKE/out")"
setup dns-doh FRONT_PROXY=cloudflare
NO_DIG=1 NO_RESOLVED=1 fp || fail "exit $?: $(cat "$FAKE/out")"
called "curl -fsS --proto =https .* https://cloudflare-dns.com/dns-query?name=test.aishie.app&type=A$" || fail "DNS over HTTPS not asked: $(grep dns-query "$CALLS")"
said "is proxied: public DNS (curl, at cloudflare-dns.com/dns-query) gives $CF_ADDR" || fail "said: $(cat "$FAKE/out")"
said "goes through Cloudflare (cf-ray 8c0ffee0a1b2c3d4-SIN) to Caddy" || fail "said: $(cat "$FAKE/out")"
# ... none of them answers: said, with what each said, and the challenge
# path not asked, as where is not known.
setup dns-down FRONT_PROXY=cloudflare
DNS_BLOCKED="1.1.1.1 8.8.8.8" NO_RESOLVED=1 DOH_DOWN=1 fp || fail "exit $?: $(cat "$FAKE/out")"
said "warning: could not find the address of test.aishie.app in public DNS (dig, at 1.1.1.1: no servers could be reached; dig, at 8.8.8.8: no servers could be reached; resolvectl, past /etc/hosts and its cache: test.aishie.app: resolve call failed: Unit dbus-org.freedesktop.resolve1.service not found.; curl, at cloudflare-dns.com/dns-query: curl: (28) Failed to connect to cloudflare-dns.com port 443 after 15002 ms: Timeout was reached): whether Let's Encrypt reaches Caddy through Cloudflare is not known" ||
  fail "said: $(cat "$FAKE/out")"
! called "acme-challenge" || fail "asked the challenge path with no address"
! ls "$AISHIE_STATE"/front-proxy.* >/dev/null 2>&1 || fail "left $(ls "$AISHIE_STATE"/front-proxy.* 2>/dev/null)"
# ... or a name public DNS does not have.
setup dns-nxdomain FRONT_PROXY=cloudflare
record
fp || fail "exit $?: $(cat "$FAKE/out")"
said "warning: could not find the address of test.aishie.app in public DNS (dig, at 1.1.1.1: no IPv4 address; dig, at 8.8.8.8: no IPv4 address; resolvectl, past /etc/hosts and its cache: test.aishie.app: resolve call failed: 'test.aishie.app' not found; curl, at cloudflare-dns.com/dns-query: no IPv4 address)" ||
  fail "said: $(cat "$FAKE/out")"
! called "acme-challenge" || fail "asked the challenge path with no address"

# An address is Cloudflare's when one of its IPv4 ranges holds it, the
# first and last of a range included.
case=cloudflare-address
for a in 104.21.32.1 172.67.155.1 173.245.48.0 173.245.63.255 131.0.75.255 104.27.255.255 198.41.255.255; do
  cloudflares "$a" || fail "$a is not taken for Cloudflare's"
done
for a in 127.0.1.1 203.0.113.10 173.245.64.0 173.245.47.255 131.0.76.0 104.15.255.255 104.28.0.0 8.8.8.8 0.0.0.0; do
  if cloudflares "$a"; then fail "$a is taken for Cloudflare's"; fi
done

# Not root, or with arguments: nothing is done.
setup not-root FRONT_PROXY=cloudflare
before=$(sums)
if NOT_ROOT=1000 fp; then fail "ran as a user"; fi
said "run this as root" || fail "said: $(cat "$FAKE/out")"
if fp now; then fail "took an argument"; fi
said "usage: aishie front-proxy" || fail "said: $(cat "$FAKE/out")"
if [ "$(sums)" != "$before" ] || [ -s "$CALLS" ]; then fail "did something"; fi

# The weekly timer runs it through aishie, after Docker.
grep -qx 'ExecStart=/usr/local/bin/aishie front-proxy' "$root/systemd/aishie-front-proxy.service" || fail "the service does not run aishie front-proxy"
grep -qx 'OnCalendar=weekly' "$root/systemd/aishie-front-proxy.timer" || fail "the timer is not weekly"

[ "$failed" = 0 ] && echo "aishie-front-proxy: ok"
exit "$failed"
