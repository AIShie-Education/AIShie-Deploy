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
# The tests are not root: chown is recorded.
cat > "$work/bin/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$CALLS"
EOF
chmod +x "$work/bin/chown"

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
  unset BACKUP_FAIL FLOCK_FAIL ISSUE_FAIL SERVICE_TOKEN
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

# aishie admin: the same, asked for, and then Core restarted.
setup admin deployed
printf 'Your Name\nyou@example.edu\n%s\n%s\n' "$PASSWORD" "$PASSWORD" > "$FAKE/answers"
STDIN=$FAKE/answers aishie admin || fail "exit $?: $(cat "$FAKE/out")"
grep -q "^docker compose --project-directory $root -f $root/compose.yaml run --rm --no-deps -T core bootstrap --name Your Name --email you@example.edu --password-stdin$" "$CALLS" ||
  fail "ran: $(cat "$CALLS")"
[ "$(cat "$FAKE/stdin")" = "$PASSWORD" ] || fail "the password did not reach bootstrap's standard input"
! grep -q "$PASSWORD" "$CALLS" "$FAKE/out" || fail "the password is on a command line or in the output"
called "compose.yaml restart core" || fail "Core was not restarted: $(cat "$CALLS")"
said "Sign in at https://test.aishie.app with you@example.edu" || fail "said: $(cat "$FAKE/out")"
! said "API token" || fail "spoke of an API token: $(cat "$FAKE/out")"
# A Core from before people held no API tokens prints one for the
# administrator at bootstrap: it is not shown, nor its heading, and what
# else bootstrap says is.
setup admin-old-core deployed
printf 'Your Name\nyou@example.edu\n%s\n%s\n' "$PASSWORD" "$PASSWORD" > "$FAKE/answers"
TOKEN=ais_abcdefghijkl_$(printf 'z%.0s' $(seq 40))
STDIN=$FAKE/answers BOOTSTRAP_TOKEN=$TOKEN aishie admin || fail "exit $?: $(cat "$FAKE/out")"
! said "$TOKEN" || fail "the token bootstrap printed was shown"
! said "API token" || fail "the token's heading was shown: $(cat "$FAKE/out")"
said "system actor 0192f3c1" || fail "what bootstrap said was not shown: $(cat "$FAKE/out")"
said "Sign in at https://test.aishie.app with you@example.edu" || fail "said: $(cat "$FAKE/out")"
# admin_refused CASE ANSWERS WHY: aishie admin fails, says WHY, and neither
# bootstraps nor restarts anything.
admin_refused() {
  setup "$1" deployed
  printf '%b' "$2" > "$FAKE/answers"
  if STDIN=$FAKE/answers aishie admin; then fail "made an administrator"; fi
  said "$3" || fail "said: $(cat "$FAKE/out")"
  ! called bootstrap || fail "bootstrapped: $(cat "$CALLS")"
  ! called restart || fail "restarted: $(cat "$CALLS")"
}
admin_refused admin-mismatch "Your Name\nyou@example.edu\n$PASSWORD\nsomething-else-here\n" "the two passwords differ"
admin_refused admin-short "Your Name\nyou@example.edu\nshort\nshort\n" "shorter than 10 characters"
admin_refused admin-email "Your Name\nnot-an-email\n$PASSWORD\n$PASSWORD\n" "is not an email address"
admin_refused admin-name "\nyou@example.edu\n$PASSWORD\n$PASSWORD\n" "a name is needed"
admin_refused admin-eof "Your Name\n" "no answer"
# bootstrap refused (an administrator already, say): Core is left alone.
setup admin-bootstrap-fails deployed
printf 'Your Name\nyou@example.edu\n%s\n%s\n' "$PASSWORD" "$PASSWORD" > "$FAKE/answers"
if STDIN=$FAKE/answers RUN_FAIL=1 aishie admin; then fail "succeeded though bootstrap failed"; fi
said "bootstrap failed" || fail "said: $(cat "$FAKE/out")"
! called restart || fail "restarted: $(cat "$CALLS")"
# Before Core is deployed: nothing to bootstrap with.
setup admin-undeployed
printf 'Your Name\nyou@example.edu\n%s\n%s\n' "$PASSWORD" "$PASSWORD" > "$FAKE/answers"
if STDIN=$FAKE/answers aishie admin; then fail "went ahead with no Core"; fi
said "core is not deployed yet" || fail "said: $(cat "$FAKE/out")"

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

# The runtime's credential for Core, issued anew: Core's `service issue`, in
# the image Core runs, under aishie-update's lock, with --replace; its
# standard output into the file the runtime reads, whole, 0600, the
# runtime's user's, and printed nowhere; the runtime recreated after.
setup runtime-credential deployed
cred=$FAKE/etc/runtime/secrets/core/agent_runtime
aishie runtime-credential || fail "exit $?: $(cat "$FAKE/out")"
grep -q "^docker compose --project-directory $root -f $root/compose.yaml run --rm --no-deps -T core service issue agent_runtime --label runtime --replace$" "$CALLS" ||
  fail "ran: $(cat "$CALLS")"
[ "$(cat "$cred")" = "$(cat "$FAKE/issued")" ] || fail "the file is not what Core printed"
[ "$(stat -c %a "$cred")" = 600 ] || fail "the credential is $(stat -c %a "$cred")"
[ "$(stat -c %a "$(dirname "$cred")")" = 750 ] || fail "its directory is $(stat -c %a "$(dirname "$cred")")"
called "chown root:65532 $(dirname "$cred")$" || fail "its directory not given to the runtime's group: $(grep chown "$CALLS")"
called "chown 65532:65532 $cred.new$" || fail "not given to the runtime's user: $(grep chown "$CALLS")"
! ls "$cred".* >/dev/null 2>&1 || fail "left $(ls "$cred".*)"
called "flock -w 600 9" || fail "took no lock"
[ "$(grep -n 'flock -w 600 9' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'service issue' "$CALLS" | cut -d: -f1)" ] || fail "issued before it took the lock"
[ "$(grep -n 'service issue' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'compose.yaml up -d --no-deps --force-recreate runtime$' "$CALLS" | cut -d: -f1)" ] ||
  fail "the runtime was not recreated after: $(cat "$CALLS")"
said "for the site service agent_runtime, 0 other(s) revoked$" || fail "Core's description not shown: $(cat "$FAKE/out")"
! said "shown once" || fail "said the credential is shown"
said "the runtime recreated, with it" || fail "said: $(cat "$FAKE/out")"
first=$(cat "$cred")
if grep -qF -- "$first" "$FAKE/out" "$CALLS"; then fail "the credential is in the output or on a command line"; fi
# Again: a new one in its place, the one before revoked by Core.
inode=$(stat -c %i "$cred")
aishie runtime-credential || fail "again: exit $?: $(cat "$FAKE/out")"
[ "$(cat "$cred")" = "$(tail -n 1 "$FAKE/issued")" ] || fail "again: the file is not what Core printed last"
[ "$(cat "$cred")" != "$first" ] || fail "again: the credential is the one before"
[ "$(stat -c %i "$cred")" != "$inode" ] || fail "again: written over in place, not put in place whole"
said "1 other(s) revoked$" || fail "again: said: $(cat "$FAKE/out")"
if grep -qF -- "$(cat "$cred")" "$FAKE/out" "$CALLS"; then fail "again: the credential is in the output or on a command line"; fi
# Core refuses (a Core from before the agent_runtime service), or answers
# with something that is not a credential: the file is left as it was, and
# so is the runtime; what is not a credential is not shown either.
for how in refused garbled; do
  : > "$CALLS"
  before=$(sha256sum < "$cred")
  if [ $how = refused ]; then
    if ISSUE_FAIL=1 aishie runtime-credential; then fail "$how: passed"; fi
    said "no site service \"agent_runtime\"" || fail "$how: Core's refusal not shown: $(cat "$FAKE/out")"
    said "Core issued no credential (above)" || fail "$how: said: $(cat "$FAKE/out")"
  else
    if SERVICE_TOKEN="api_error_not_a_credential" aishie runtime-credential; then fail "$how: passed"; fi
    said "is not a site service's credential" || fail "$how: said: $(cat "$FAKE/out")"
    ! said "api_error_not_a_credential" || fail "$how: showed what Core printed"
  fi
  [ "$(sha256sum < "$cred")" = "$before" ] || fail "$how: the file changed"
  ! ls "$cred".* >/dev/null 2>&1 || fail "$how: left $(ls "$cred".*)"
  ! called "force-recreate" || fail "$how: recreated the runtime"
done
# The runtime not deployed yet: the credential kept for it, nothing
# recreated.
setup runtime-credential-no-runtime
echo "CORE_REF=$CORE" > "$FAKE/state/images.env"
aishie runtime-credential || fail "exit $?: $(cat "$FAKE/out")"
[ -s "$FAKE/etc/runtime/secrets/core/agent_runtime" ] || fail "no credential kept"
! called "force-recreate" || fail "recreated a runtime that is not deployed"
said "the runtime is not deployed yet" || fail "said: $(cat "$FAKE/out")"
# Core not deployed, or a deploy holding the lock: nothing run.
setup runtime-credential-no-core
if aishie runtime-credential; then fail "passed with no Core"; fi
said "core is not deployed yet" || fail "said: $(cat "$FAKE/out")"
[ ! -s "$CALLS" ] || fail "ran: $(cat "$CALLS")"
setup runtime-credential-locked deployed
if FLOCK_FAIL=1 aishie runtime-credential; then fail "passed without the lock"; fi
! called "service issue" || fail "issued without the lock"
[ ! -e "$FAKE/etc/runtime/secrets/core/agent_runtime" ] || fail "wrote a credential"

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

# aishie storage is aishie-storage, beside it (tests/aishie-storage_test.sh).
setup storage deployed
aishie storage help || fail "exit $?: $(cat "$FAKE/out")"
said "aishie storage migrate --to s3" || fail "said: $(cat "$FAKE/out")"
said "aishie storage \[COMMAND\]" && fail "aishie's own usage, not aishie-storage's"
aishie frobnicate || :
said "aishie storage \[COMMAND\]" || fail "aishie's usage does not name storage: $(cat "$FAKE/out")"

# Anything else: usage, and nothing run.
for args in "" "core" "frobnicate" "backup now" "runtime-status x" "runtime-credential x"; do
  setup usage deployed
  # shellcheck disable=SC2086 # the arguments, split
  if aishie $args; then fail "took «$args»"; fi
  [ ! -s "$CALLS" ] || fail "ran something for «$args»: $(cat "$CALLS")"
done

[ "$failed" = 0 ] && echo "aishie: ok"
exit "$failed"
