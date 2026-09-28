#!/usr/bin/env bash
# aishie against the stand-ins of tests/fakes.sh:
#
#   make test
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
. "$here/fakes.sh"
make_fakes "$work/bin"

CORE=ghcr.io/aishie-education/aishie-core@sha256:$(printf 'a%.0s' $(seq 64))
RUNTIME=ghcr.io/aishie-education/aishie-agent-runtime@sha256:$(printf 'b%.0s' $(seq 64))
PASSWORD=pw-$(printf 'y%.0s' $(seq 16))

failed=0
fail() { echo "FAIL aishie $case: $*" >&2; failed=1; }

# setup CASE [deployed]: a server set up, with core and the runtime deployed
# and running, or nothing.
setup() {
  case=$1
  export FAKE=$work/$case CALLS=$work/$case/calls
  mkdir -p "$FAKE/etc" "$FAKE/state" "$FAKE/backups" "$FAKE/running" "$FAKE/registry"
  : > "$CALLS"
  echo "HOST=test.aishie.app" > "$FAKE/etc/aishie.env"
  export AISHIE_ETC=$FAKE/etc AISHIE_STATE=$FAKE/state AISHIE_APP=$root \
    AISHIE_BACKUPS=$FAKE/backups AISHIE_LOCK_FILE=$FAKE/lock
  unset BACKUP_FAIL FLOCK_FAIL
  if [ "${2:-}" = deployed ]; then
    printf 'CORE_REF=%s\nRUNTIME_REF=%s\n' "$CORE" "$RUNTIME" > "$FAKE/state/images.env"
    echo "$CORE" > "$FAKE/running/core"
    echo "$RUNTIME" > "$FAKE/running/runtime"
    echo postgres:18 > "$FAKE/running/postgres"
  fi
}
# aishie ARGS: with nothing on standard input, unless STDIN names a file.
aishie() { PATH="$work/bin:$PATH" "$root/bin/aishie" "$@" < "${STDIN:-/dev/null}" > "$FAKE/out" 2>&1; }
called() { grep -q -- "$1" "$CALLS"; }
said() { grep -q -- "$1" "$FAKE/out"; }

# The first administrator: the password on standard input, and nowhere else.
setup bootstrap deployed
printf '%s\n' "$PASSWORD" > "$FAKE/password"
STDIN=$FAKE/password aishie core bootstrap --name "Your Name" --email you@example.edu --password-stdin ||
  fail "exit $?: $(cat "$FAKE/out")"
grep -q "^docker compose --project-directory $root -f $root/compose.yaml run --rm --no-deps -T core bootstrap --name Your Name --email you@example.edu --password-stdin$" "$CALLS" ||
  fail "ran: $(cat "$CALLS")"
[ "$(cat "$FAKE/stdin")" = "$PASSWORD" ] || fail "the password did not reach standard input"
! grep -q "$PASSWORD" "$CALLS" "$FAKE/out" || fail "the password is on a command line or in the output"
said "core bootstrap .* with $CORE" || fail "not with the image that runs: $(cat "$FAKE/out")"

# The runtime's commands, with the image it runs.
setup runtime deployed
aishie runtime check --live || fail "exit $?: $(cat "$FAKE/out")"
called "run --rm --no-deps -T runtime check --live" || fail "ran: $(cat "$CALLS")"
aishie runtime migrate version || fail "exit $?"
called "run --rm --no-deps -T runtime migrate version" || fail "ran: $(cat "$CALLS")"

# Nothing deployed yet: said, and nothing run.
setup not-deployed
if aishie core token issue --actor x --label y; then fail "ran with no image deployed"; fi
said "core is not deployed yet" || fail "said: $(cat "$FAKE/out")"
[ ! -s "$CALLS" ] || fail "ran: $(cat "$CALLS")"

# The environment does not steer compose.
setup environment deployed
CORE_REF=nginx:latest aishie core migrate version || fail "exit $?"
! grep -q "^CORE_REF=" "$CALLS" || fail "passed CORE_REF on: $(cat "$CALLS")"

# logs, ps and compose.
setup logs deployed
aishie logs core || fail "exit $?"
called "compose.yaml logs -f --tail 100 core" || fail "ran: $(cat "$CALLS")"
aishie logs runtime --since 1h || fail "exit $?"
called "compose.yaml logs runtime --since 1h" || fail "ran: $(cat "$CALLS")"
aishie ps || fail "exit $?"
called "compose.yaml ps" || fail "ran: $(cat "$CALLS")"
aishie compose up -d core || fail "exit $?"
called "compose.yaml up -d core" || fail "ran: $(cat "$CALLS")"

# The runtime's /status, from inside its own network namespace.
setup runtime-status deployed
aishie runtime-status || fail "exit $?: $(cat "$FAKE/out")"
called "docker run --rm --network container:container-of-runtime --entrypoint wget caddy:2 -qO- http://127.0.0.1:9090/status" ||
  fail "ran: $(cat "$CALLS")"
rm "$FAKE/running/runtime"
if aishie runtime-status; then fail "passed with no runtime running"; fi

# The nightly backup: both databases, one file per day of the week.
setup backup deployed
aishie backup || fail "exit $?: $(cat "$FAKE/out")"
day=$(date +%u)
for s in core runtime; do
  called "pg_dump -U postgres -Fc aishie_$s" || fail "no dump of aishie_$s"
  [ -s "$FAKE/backups/$s-daily-$day.dump" ] || fail "no $s-daily-$day.dump: $(ls "$FAKE/backups")"
done
[ "$(stat -c %a "$FAKE/backups/core-daily-$day.dump")" = 600 ] || fail "the backup is $(stat -c %a "$FAKE/backups/core-daily-$day.dump")"
called "flock -w 3600 9" || fail "took no lock"
# One that fails leaves no half file, and last week's in place.
echo "last week" > "$FAKE/backups/core-daily-$day.dump"
if BACKUP_FAIL=1 aishie backup; then fail "passed while pg_dump failed"; fi
[ "$(cat "$FAKE/backups/core-daily-$day.dump")" = "last week" ] || fail "replaced last week's with a failed dump"
! ls "$FAKE/backups"/*.part >/dev/null 2>&1 || fail "a .part file left behind"
# Not while a deploy holds the lock, and not with PostgreSQL down.
: > "$CALLS"
if FLOCK_FAIL=1 aishie backup; then fail "backed up without the lock"; fi
! called "pg_dump" || fail "dumped without the lock"
rm "$FAKE/running/postgres"
if aishie backup; then fail "passed with PostgreSQL down"; fi
said "PostgreSQL is not running" || fail "said: $(cat "$FAKE/out")"

# Anything else: usage, and nothing run.
for args in "" "core" "frobnicate" "backup now" "runtime-status x"; do
  setup usage deployed
  # shellcheck disable=SC2086 # the arguments, split
  if aishie $args; then fail "took «$args»"; fi
  [ ! -s "$CALLS" ] || fail "ran something for «$args»: $(cat "$CALLS")"
done

[ "$failed" = 0 ] && echo "aishie: ok"
exit "$failed"
