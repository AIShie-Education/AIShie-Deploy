#!/usr/bin/env bash
# aishie-update against stand-ins for docker (and docker compose), curl,
# flock, sleep and logger, which record what they are asked to do and play a
# registry, a Docker and the stack's health checks:
#
#   make test
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
. "$here/fakes.sh"
make_fakes "$work/bin"

REG=ghcr.io/aishie-education
CORE=$REG/aishie-core
RUNTIME=$REG/aishie-agent-runtime
WEB=$REG/aishie-frontend
A=$(printf 'a%.0s' $(seq 64))
B=$(printf 'b%.0s' $(seq 64))
C=$(printf 'c%.0s' $(seq 64))
D=$(printf 'd%.0s' $(seq 64))
E=$(printf 'e%.0s' $(seq 64))
F=$(printf 'f%.0s' $(seq 64))
# A secret in each env file: nothing aishie-update prints or logs may hold it.
SECRET=s3cr3t-$(printf 'x%.0s' $(seq 20))

failed=0
fail() { echo "FAIL $case: $*" >&2; failed=1; }

# setup CASE: a server set up by setup-server.sh, with nothing deployed; a
# registry where each channel's :edge names a healthy image.
setup() {
  case=$1
  export FAKE=$work/$case CALLS=$work/$case/calls
  mkdir -p "$FAKE/etc/runtime/agents" "$FAKE/etc/runtime/secrets" "$FAKE/state" "$FAKE/backups"
  : > "$CALLS"
  cat > "$FAKE/etc/aishie.env" <<ENV
HOST=test.aishie.app
ENVIRONMENT=edge
CORE_IMAGE=$CORE:edge
RUNTIME_IMAGE=$RUNTIME:edge
WEB_IMAGE=$WEB:edge
AISHIE_SUBNET=172.30.83.0/24
AISHIE_CADDY_IP=172.30.83.10
ENV
  for f in core runtime postgres; do printf 'SIGNING_KEY=%s\n' "$SECRET" > "$FAKE/etc/$f.env"; done
  export AISHIE_ETC=$FAKE/etc AISHIE_STATE=$FAKE/state AISHIE_APP=$root \
    AISHIE_BACKUPS=$FAKE/backups AISHIE_LOG_FILE=$FAKE/log AISHIE_LOCK_FILE=$FAKE/lock \
    AISHIE_HEALTH_TRIES=3
  unset PULL_FAIL MIGRATE_FAIL VERSION_FAIL SEED_FAIL CHECK_FAIL BACKUP_FAIL FLOCK_FAIL POSTGRES_FAIL INVOCATION_ID
  image core "$A" v0.2.0 abc1234
  image runtime "$B" v0.4.0 bcd2345
  image web "$C" v0.3.0 cde3456
  tag "$CORE:edge" "$A"
  tag "$RUNTIME:edge" "$B"
  tag "$WEB:edge" "$C"
}
update() { PATH="$work/bin:$PATH" "$root/bin/aishie-update" "$@" < /dev/null > "$FAKE/out" 2>&1; }
called() { grep -q -- "$1" "$CALLS"; }
count() { grep -c -- "$1" "$CALLS" || true; }
# line PATTERN: the first line of the record that matches, 0 if none.
line() { grep -n -- "$1" "$CALLS" | head -n 1 | cut -d: -f1 || true; }
running() { cat "$FAKE/running/$1" 2>/dev/null || echo none; }
ref() { sed -n "s/^$1=//p" "$FAKE/state/images.env"; }
logged() { grep -c -- "$1" "$FAKE/log" 2>/dev/null || true; }
said() { grep -q -- "$1" "$FAKE/out"; }
# deployed: core, runtime and web on A, B and C.
deployed() { update || fail "the first deploy failed: $(cat "$FAKE/out")"; : > "$CALLS"; }

# A fresh server: all three, in order, each by the safe sequence.
setup first
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(ref CORE_REF)" = "$CORE@sha256:$A" ] || fail "core: $(ref CORE_REF)"
[ "$(ref RUNTIME_REF)" = "$RUNTIME@sha256:$B" ] || fail "runtime: $(ref RUNTIME_REF)"
[ "$(ref WEB_REF)" = "$WEB@sha256:$C" ] || fail "web: $(ref WEB_REF)"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
[ "$(running runtime)" = "$RUNTIME@sha256:$B" ] || fail "runtime runs $(running runtime)"
[ "$(running web)" = "$WEB@sha256:$C" ] || fail "web runs $(running web)"
for step in "pull -q $CORE:edge" "pull -q $CORE@sha256:$A" "up -d --no-recreate --wait" "pg_dump -U postgres -Fc aishie_core" \
  "run -d --no-deps core migrate up" "run -d --no-deps core seed" "up -d --no-deps core" \
  "run -d --no-deps runtime check" "pg_dump -U postgres -Fc aishie_runtime" "run -d --no-deps runtime migrate up" \
  "up -d --no-deps runtime" "up -d --no-deps web" "image prune -af --filter label=org.opencontainers.image.source="; do
  called "$step" || fail "no «$step»"
done
# Pulled by digest too, before anything else: the name compose runs it by,
# which stays when the tag moves on.
[ "$(line "pull -q $CORE@sha256:$A")" -lt "$(line 'aishie_core')" ] || fail "core not pulled by digest before its deploy"
[ "$(line 'aishie_core')" -lt "$(line 'core migrate up')" ] || fail "core migrated before its backup"
[ "$(line 'core migrate up')" -lt "$(line 'core seed')" ] || fail "core seeded before migrating"
[ "$(line 'core seed')" -lt "$(line 'up -d --no-deps core')" ] || fail "core started before seeding"
[ "$(line 'up -d --no-deps core')" -lt "$(line 'runtime check')" ] || fail "the runtime went before core"
[ "$(line 'runtime check')" -lt "$(line 'aishie_runtime')" ] || fail "the runtime was backed up before its check"
[ "$(line 'aishie_runtime')" -lt "$(line 'runtime migrate up')" ] || fail "the runtime migrated before its backup"
[ "$(line 'runtime migrate up')" -lt "$(line 'up -d --no-deps runtime')" ] || fail "the runtime started before migrating"
[ "$(line 'up -d --no-deps runtime')" -lt "$(line 'up -d --no-deps web')" ] || fail "web went before the runtime"
! called "runtime seed" || fail "seeded the runtime"
# The one-off containers run the new image, and are waited for and removed.
grep -q "CORE_REF=$CORE@sha256:$A docker compose .* run -d --no-deps core migrate up" "$CALLS" ||
  fail "migrate up not with the new image: $(grep 'migrate up' "$CALLS" | head -n 1)"
[ "$(count 'docker wait')" = "$(count ' run -d --no-deps')" ] || fail "not every one-off waited for"
[ "$(count 'docker rm -f oneoff')" = "$(count ' run -d --no-deps')" ] || fail "not every one-off removed"
called "curl -fsS --noproxy \\* --max-time 5 http://127.0.0.1:8080/healthz" || fail "core's health asked elsewhere"
called "curl -fsS --noproxy \\* --max-time 5 http://127.0.0.1:9090/healthz" || fail "the runtime's health asked elsewhere"
called "curl -fsS --noproxy \\* --max-time 5 http://127.0.0.1:8081/version.json" || fail "the web's health asked elsewhere"
[ "$(logged ': deployed')" = 3 ] || fail "log: $(cat "$FAKE/log")"
grep -q "core none -> sha256:$A: deployed v0.2.0 (abc1234)" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"
grep -q "web none -> sha256:$C: deployed v0.3.0 (cde3456)" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"
[ "$(logger_lines)" = 3 ] || fail "the journal (logger) got $(logger_lines) lines, not 3"
ls "$FAKE/backups"/core-deploy-*.dump "$FAKE/backups"/runtime-deploy-*.dump >/dev/null 2>&1 || fail "no backups kept: $(ls "$FAKE/backups")"
! ls "$FAKE/backups"/*.part >/dev/null 2>&1 || fail "a .part file left behind"
[ "$(stat -c %a "$FAKE/state/images.env")" = 600 ] || fail "images.env is $(stat -c %a "$FAKE/state/images.env")"
update --status || fail "--status: exit $?"
said "running:     $CORE@sha256:$A" || fail "--status: $(cat "$FAKE/out")"
said "channel:     $WEB:edge" || fail "--status: $(cat "$FAKE/out")"
said "last result: .* web none -> sha256:$C: deployed" || fail "--status: $(cat "$FAKE/out")"

# Nothing new: nothing done, nothing logged.
setup no-change
deployed
before=$(cat "$FAKE/log")
update || fail "exit $?: $(cat "$FAKE/out")"
! called "up -d" || fail "started something: $(grep 'up -d' "$CALLS")"
! called "pg_dump" || fail "backed up with nothing to deploy"
! called "image prune" || fail "pruned with nothing deployed"
[ "$(cat "$FAKE/log")" = "$before" ] || fail "logged: $(diff <(echo "$before") "$FAKE/log")"
[ "$(grep -c 'up to date' "$FAKE/out")" = 3 ] || fail "said: $(cat "$FAKE/out")"
grep -q "up to date" "$FAKE/state/core.checked" || fail "last check: $(cat "$FAKE/state/core.checked")"

# A new digest on core's channel: core alone is deployed, old -> new.
setup new-digest
deployed
image core "$D" v0.2.1 def4567
tag "$CORE:edge" "$D"
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "core runs $(running core)"
[ "$(ref CORE_REF)" = "$CORE@sha256:$D" ] || fail "images.env: $(ref CORE_REF)"
! called "up -d --no-deps runtime" || fail "recreated the runtime"
! called "up -d --no-deps web" || fail "recreated the web"
grep -q "core sha256:$A -> sha256:$D: deployed v0.2.1 (def4567)" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# A migration that fails: the old version goes on running, untouched, and
# the new digest is recorded as failed.
setup migrate-fails
deployed
image core "$D" v0.2.1 def4567
tag "$CORE:edge" "$D"
if MIGRATE_FAIL=1 update; then fail "went on after a failed migration"; fi
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
[ "$(ref CORE_REF)" = "$CORE@sha256:$A" ] || fail "images.env: $(ref CORE_REF)"
! called "up -d --no-deps core" || fail "recreated core"
! called "core seed" || fail "seeded after a failed migration"
! called "image prune" || fail "pruned after a failed deploy"
! called "runtime" || fail "went on to the runtime"
grep -qx "sha256:$D" "$FAKE/state/core.failed" || fail "not recorded as failed"
grep -q "migrate up failed" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# A new version that never reports healthy: the one before runs again, is
# waited for, and the new digest is recorded as failed.
setup unhealthy
deployed
image core "$D" v0.2.1 def4567
unhealthy "$D"
tag "$CORE:edge" "$D"
if update; then fail "passed while the new version was not healthy"; fi
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
[ "$(ref CORE_REF)" = "$CORE@sha256:$A" ] || fail "images.env: $(ref CORE_REF)"
[ "$(count 'up -d --no-deps core')" = 2 ] || fail "recreated core $(count 'up -d --no-deps core') times, not 2"
[ "$(count 'http://127.0.0.1:8080/healthz')" = 4 ] || fail "asked /healthz $(count 'http://127.0.0.1:8080/healthz') times, not 3 and 1"
called "logs --no-color --tail 30 core" || fail "did not show the new version's log"
grep -qx "sha256:$D" "$FAKE/state/core.failed" || fail "not recorded as failed"
grep -q "rolled back: sha256:$A runs again" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"
! called "image prune" || fail "pruned the image rolled back from"

# ... and the next run leaves that digest be, and says so once.
update || fail "exit $?: $(cat "$FAKE/out")"
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(logged 'skipped: it failed before')" = 1 ] || fail "logged the skip $(logged 'skipped: it failed before') times, not once"
[ "$(count 'up -d --no-deps core')" = 2 ] || fail "deployed the failed digest again"
said "(as before: not logged again)" || fail "said: $(cat "$FAKE/out")"
called "pull -q $WEB:edge" || fail "the run stopped at the skipped core: the web was not checked"

# A newer digest on the channel is deployed, failed one or not.
image core "$E" v0.2.2 ef56789
tag "$CORE:edge" "$E"
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$E" ] || fail "core runs $(running core)"

# --retry: the failed digest is tried again.
setup retry
deployed
image core "$D" v0.2.1 def4567
unhealthy "$D"
tag "$CORE:edge" "$D"
update || true
healthy_again "$D"
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "tried the failed digest without --retry"
update --retry core || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "core runs $(running core) after --retry"
[ ! -s "$FAKE/state/core.failed" ] || fail "still recorded: $(cat "$FAKE/state/core.failed")"
grep -q "retry" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# A Core that says where its migrations stop, past none that breaks the
# release before: asked `migrate version` before the backup, and rolled back
# as ever when the new one is not healthy.
setup rollback-before-0027
migrations "$A" 25
deployed
[ "$(cat "$FAKE/schema")" = 25 ] || fail "schema $(cat "$FAKE/schema")"
image core "$D" v0.2.1 def4567
migrations "$D" 26
unhealthy "$D"
tag "$CORE:edge" "$D"
if update; then fail "passed while the new version was not healthy"; fi
grep -q "CORE_REF=$CORE@sha256:$D docker compose .* run -d --no-deps core migrate version" "$CALLS" ||
  fail "migrate version not asked of the new image"
[ "$(line 'core migrate version')" -lt "$(line 'aishie_core')" ] || fail "migrate version not before the backup"
grep -q "CORE_REF=$CORE@sha256:$A docker compose .* run -d --no-deps core migrate version" "$CALLS" ||
  fail "migrate version not asked of the one before"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
grep -qx "sha256:$D" "$FAKE/state/core.failed" || fail "not recorded as failed"
grep -q "rolled back: sha256:$A runs again" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# Core's migration 0027 does not leave the release before it working: a new
# Core with it that is not healthy is left running, not replaced by one
# whose migrations stop before it, which would pass /healthz and fail every
# authenticated call. Nothing is recorded as failed.
setup rollback-past-0027
migrations "$A" 26
deployed
image core "$D" v0.3.0 def4567
migrations "$D" 27
unhealthy "$D"
tag "$CORE:edge" "$D"
if update; then fail "passed while the new version was not healthy"; fi
[ "$(cat "$FAKE/schema")" = 27 ] || fail "schema $(cat "$FAKE/schema")"
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "core runs $(running core)"
[ "$(ref CORE_REF)" = "$CORE@sha256:$D" ] || fail "images.env: $(ref CORE_REF)"
[ "$(count 'up -d --no-deps core')" = 1 ] || fail "recreated core $(count 'up -d --no-deps core') times, not once"
grep -q "CORE_REF=$CORE@sha256:$A docker compose .* run -d --no-deps core migrate version" "$CALLS" ||
  fail "migrate version not asked of the one before"
[ ! -s "$FAKE/state/core.failed" ] || fail "recorded as failed: $(cat "$FAKE/state/core.failed")"
grep -q "core sha256:$A -> sha256:$D: not healthy within 6 seconds .*; not rolled back: sha256:$A's migrations stop at 26, before Core's migration 0027, which the schema has (version 27)" "$FAKE/log" ||
  fail "log: $(cat "$FAKE/log")"
grep -q "sha256:$D goes on running: aishie logs core says why it is not healthy; to go back, README.md, Rolling back past Core's migration 0027" "$FAKE/log" ||
  fail "log: $(cat "$FAKE/log")"
! called "image prune" || fail "pruned after a failed deploy"
! called "runtime" || fail "went on to the runtime"
grep -q "not rolled back" "$FAKE/state/core.checked" || fail "last check: $(cat "$FAKE/state/core.checked")"
# ... and the one before is not asked when it cannot say: rolled back as ever.
setup rollback-past-0027-unknown
migrations "$A" 26
deployed
image core "$D" v0.3.0 def4567
migrations "$D" 27
unhealthy "$D"
tag "$CORE:edge" "$D"
rm "$FAKE/registry/img/$A/migrations"
if update; then fail "passed while the new version was not healthy"; fi
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
grep -q "rolled back: sha256:$A runs again" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# A Core whose migrations stop before 0027 is not deployed onto a schema that
# has it, by --pin or by its channel (main reverted past 0027): refused
# before the backup, nothing changed, nothing recorded as failed, said once.
# Once the schema is migrated down, the same goes ahead.
setup pin-past-0027
migrations "$A" 26
tag "$CORE:0.2.0" "$A"
image core "$D" v0.3.0 def4567
migrations "$D" 27
tag "$CORE:edge" "$D"
deployed
[ "$(cat "$FAKE/schema")" = 27 ] || fail "schema $(cat "$FAKE/schema")"
if update --pin core "$CORE:0.2.0"; then fail "--pin deployed a Core from before 0027 onto its schema"; fi
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "core runs $(running core)"
[ "$(ref CORE_REF)" = "$CORE@sha256:$D" ] || fail "images.env: $(ref CORE_REF)"
[ ! -e "$FAKE/state/core.pin" ] || fail "pinned: $(cat "$FAKE/state/core.pin")"
! called "pg_dump" || fail "backed up for a refused Core"
! called "migrate up" || fail "migrated for a refused Core"
! called "up -d --no-deps core" || fail "recreated core"
[ ! -s "$FAKE/state/core.failed" ] || fail "recorded as failed: $(cat "$FAKE/state/core.failed")"
grep -q "core sha256:$D -> sha256:$A: refused: sha256:$A's migrations stop at 26, before Core's migration 0027, which the schema has (version 27): it would report healthy and fail every authenticated call that reads an actor or a document's version. sha256:$D goes on running. To go back past 0027, migrate down first" "$FAKE/log" ||
  fail "log: $(cat "$FAKE/log")"
tag "$CORE:edge" "$A"
if update; then fail "deployed a Core from before 0027 onto its schema from the channel"; fi
if update; then fail "deployed a Core from before 0027 onto its schema from the channel"; fi
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "core runs $(running core)"
[ "$(logged "refused: sha256:$A's migrations stop at 26")" = 1 ] || fail "logged the refusal $(logged 'refused: sha256') times, not once"
said "(as before: not logged again)" || fail "said: $(cat "$FAKE/out")"
! called "pg_dump" || fail "backed up for a refused Core"
# Migrated down by hand (README.md, Rolling back past Core's migration 0027).
echo 26 > "$FAKE/schema"
update --pin core "$CORE:0.2.0" || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core) after the down"
[ "$(cat "$FAKE/state/core.pin")" = "$CORE@sha256:$A" ] || fail "pin: $(cat "$FAKE/state/core.pin" 2>/dev/null)"

# --pin: exactly that digest, by the same sequence, and the channel is not
# followed until --unpin.
setup pin
image core "$D" v0.2.1 def4567
tag "$CORE:edge" "$D"
tag "$CORE:0.2.0" "$A"
deployed
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "core runs $(running core)"
update --pin core "sha256:$A" || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core) after --pin"
for step in "pull -q $CORE@sha256:$A" "pg_dump -U postgres -Fc aishie_core" "core migrate up" "core seed"; do
  called "$step" || fail "--pin: no «$step»"
done
[ "$(cat "$FAKE/state/core.pin")" = "$CORE@sha256:$A" ] || fail "pin: $(cat "$FAKE/state/core.pin" 2>/dev/null)"
: > "$CALLS"
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "the channel undid the pin"
! called "pull -q $CORE:edge" || fail "pulled a pinned service's channel"
[ "$(logged 'pinned by hand to')" = 0 ] || fail "logged the pin again: $(cat "$FAKE/log")"
update --status || fail "--status: exit $?"
said "pinned:      $CORE@sha256:$A" || fail "--status: $(cat "$FAKE/out")"
update --pin core "$CORE:0.2.0" || fail "--pin by tag: exit $?: $(cat "$FAKE/out")"
[ "$(cat "$FAKE/state/core.pin")" = "$CORE@sha256:$A" ] || fail "pinned by tag: $(cat "$FAKE/state/core.pin")"
update --unpin core || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "core runs $(running core) after --unpin"
[ ! -e "$FAKE/state/core.pin" ] || fail "still pinned"
if update --pin core "$REG/other:1.0.0"; then fail "--pin took another repository's image"; fi
if update --pin core "sha256:1234"; then fail "--pin took half a digest"; fi

# The backup fails: nothing is changed, and nothing is recorded against the
# image; the next run tries again.
setup backup-fails
deployed
image core "$D" v0.2.1 def4567
tag "$CORE:edge" "$D"
kept=$(ls "$FAKE/backups")
if BACKUP_FAIL=1 update; then fail "went on without a backup"; fi
! called "migrate up" || fail "migrated without a backup"
! called "up -d --no-deps" || fail "recreated something"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
[ "$(ref CORE_REF)" = "$CORE@sha256:$A" ] || fail "images.env: $(ref CORE_REF)"
[ "$(ls "$FAKE/backups")" = "$kept" ] || fail "left $(ls "$FAKE/backups")"
[ ! -s "$FAKE/state/core.failed" ] || fail "recorded the image as failed"
grep -q "backup of the database aishie_core failed; nothing was changed" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"
update || fail "the next run: exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "the next run did not deploy: core runs $(running core)"

# The newest ten deploy backups of a service stay; the daily ones and the
# other service's are not touched.
setup keep-ten
for n in $(seq -w 1 12); do touch -t "202601${n}0000" "$FAKE/backups/core-deploy-202601${n}T000000Z.dump"; done
touch "$FAKE/backups/core-daily-1.dump" "$FAKE/backups/runtime-deploy-20260101T000000Z.dump"
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(find "$FAKE/backups" -name 'core-deploy-*.dump' | wc -l)" = 10 ] || fail "kept $(find "$FAKE/backups" -name 'core-deploy-*.dump' | wc -l)"
[ ! -e "$FAKE/backups/core-deploy-20260101T000000Z.dump" ] || fail "kept the oldest"
[ -e "$FAKE/backups/core-daily-1.dump" ] || fail "removed a daily backup"
[ -e "$FAKE/backups/runtime-deploy-20260101T000000Z.dump" ] || fail "removed the runtime's"

# An image of another repository is refused before anything is pulled.
for bad in "ghcr.io/other/aishie-core:edge" "$CORE-evil:edge" "$CORE" "nginx:latest" "$CORE:edge;id" "$CORE:\$(id)"; do
  setup refused
  sed -i "s|^CORE_IMAGE=.*|CORE_IMAGE=$bad|" "$FAKE/etc/aishie.env"
  if update; then fail "took «$bad»"; fi
  ! called "docker pull" || fail "pulled for «$bad»: $(grep 'docker pull' "$CALLS")"
  ! called "up -d" || fail "started something for «$bad»"
  grep -q "CORE_IMAGE refused" "$FAKE/log" || fail "log for «$bad»: $(cat "$FAKE/log" 2>/dev/null)"
done

# ... and so is one of this repository whose label names another source.
setup wrong-source
deployed
image core "$D" v0.2.1 def4567 https://github.com/someone/else
tag "$CORE:edge" "$D"
if update; then fail "took an image of another source"; fi
! called "pg_dump" || fail "backed up for it"
! called "up -d --no-deps" || fail "recreated something"
grep -qx "sha256:$D" "$FAKE/state/core.failed" || fail "not recorded as failed"
grep -q "refused: its source is https://github.com/someone/else" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# The runtime's new image refuses the agents' configuration: nothing changes.
setup check-fails
deployed
image runtime "$D" v0.4.1 d0d0d0d
tag "$RUNTIME:edge" "$D"
if CHECK_FAIL=1 update; then fail "went on after a failed check"; fi
! called "aishie_runtime" || fail "backed up after a failed check"
! called "runtime migrate up" || fail "migrated after a failed check"
[ "$(running runtime)" = "$RUNTIME@sha256:$B" ] || fail "the runtime runs $(running runtime)"
grep -q "does not pass \`check\`" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# The web's new image does not report its commit: the one before runs again.
setup web-unhealthy
deployed
image web "$D" v0.3.1 d1d1d1d
unhealthy "$D"
tag "$WEB:edge" "$D"
if update; then fail "passed while the web was not healthy"; fi
[ "$(running web)" = "$WEB@sha256:$C" ] || fail "the web runs $(running web)"
! called "pg_dump" || fail "backed up for the web"
grep -q "rolled back: sha256:$C runs again" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# A first deploy that never reports healthy leaves nothing running, and
# nothing in images.env.
setup first-unhealthy
unhealthy "$A"
if update; then fail "passed while core was not healthy"; fi
called "rm -s -f core" || fail "left the new core in place"
[ -z "$(ref CORE_REF)" ] || fail "images.env: $(ref CORE_REF)"
! called "runtime" || fail "went on to the runtime"
grep -q "nothing ran before it, and nothing runs now" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# A pull that fails (an old login to ghcr.io whose token has expired): the run
# stops, the log has it once, and nothing changes.
setup pull-fails
deployed
image core "$D" v0.2.1 def4567
tag "$CORE:edge" "$D"
if PULL_FAIL=1 update; then fail "passed while the pull failed"; fi
if PULL_FAIL=1 update; then fail "passed while the pull failed"; fi
[ "$(logged 'could not pull')" = 1 ] || fail "logged the failed pull $(logged 'could not pull') times, not once"
grep -q "denied" "$FAKE/log" || fail "log without Docker's error: $(cat "$FAKE/log")"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
[ ! -s "$FAKE/state/core.failed" ] || fail "recorded the image as failed"

# Stable follows releases: :edge is refused, and so is :stable, which moves
# by itself; X.Y.Z is taken.
setup stable
tag "$CORE:stable" "$A"
for moving in edge stable; do
  sed -i 's/^ENVIRONMENT=.*/ENVIRONMENT=stable/; s|^CORE_IMAGE=.*|CORE_IMAGE='"$CORE:$moving"'|' "$FAKE/etc/aishie.env"
  if update; then fail "stable took :$moving"; fi
  grep -q "stable follows releases: $CORE:$moving is not a release" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"
  ! called "docker pull" || fail "pulled :$moving"
done
tag "$CORE:0.2.0" "$A"
tag "$RUNTIME:0.4.0" "$B"
tag "$WEB:0.3.0" "$C"
sed -i "s|^CORE_IMAGE=.*|CORE_IMAGE=$CORE:0.2.0|; s|^RUNTIME_IMAGE=.*|RUNTIME_IMAGE=$RUNTIME:0.4.0|; s|^WEB_IMAGE=.*|WEB_IMAGE=$WEB:0.3.0|" "$FAKE/etc/aishie.env"
update || fail "stable refused releases: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
! grep -q "the name .* had before" "$FAKE/log" || fail "a note of an old name: $(cat "$FAKE/log")"
update --status || fail "--status: exit $?"
said "^test.aishie.app (stable)$" || fail "--status: $(cat "$FAKE/out")"

# A server set up as staging, before edge had its name, as test.aishie.app
# was: it follows :edge as it did, and aishie.env is left as it is. That the
# old name is taken is logged once, and --status and --dry-run say it.
setup old-staging
sed -i 's/^ENVIRONMENT=.*/ENVIRONMENT=staging/' "$FAKE/etc/aishie.env"
settings=$(sha256sum < "$FAKE/etc/aishie.env")
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(ref CORE_REF)" = "$CORE@sha256:$A" ] || fail "core: $(ref CORE_REF)"
[ "$(ref RUNTIME_REF)" = "$RUNTIME@sha256:$B" ] || fail "runtime: $(ref RUNTIME_REF)"
[ "$(ref WEB_REF)" = "$WEB@sha256:$C" ] || fail "web: $(ref WEB_REF)"
[ "$(logged 'settings ENVIRONMENT=staging in .* is the name edge had before: it is taken as edge')" = 1 ] || fail "log: $(cat "$FAKE/log")"
image core "$D" v0.2.1 def4567
tag "$CORE:edge" "$D"
update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$D" ] || fail "the next :edge not deployed: core runs $(running core)"
[ "$(logged 'the name edge had before')" = 1 ] || fail "logged the old name $(logged 'the name edge had before') times, not once"
[ "$(sha256sum < "$FAKE/etc/aishie.env")" = "$settings" ] || fail "aishie.env was changed: $(cat "$FAKE/etc/aishie.env")"
[ ! -e "$FAKE/state/settings.last" ] || fail "settings taken for a service"
update --status || fail "--status: exit $?"
said "^test.aishie.app (edge)$" || fail "--status: $(cat "$FAKE/out")"
said "Change it to ENVIRONMENT=edge by hand" || fail "--status: $(cat "$FAKE/out")"
before=$(cat "$FAKE/log")
update --dry-run || fail "--dry-run: exit $?"
said "ENVIRONMENT=staging in .* is taken as edge" || fail "--dry-run: $(cat "$FAKE/out")"
[ "$(cat "$FAKE/log")" = "$before" ] || fail "--dry-run logged: $(diff <(echo "$before") "$FAKE/log")"
# ... renamed by hand: nothing more said.
sed -i 's/^ENVIRONMENT=.*/ENVIRONMENT=edge/' "$FAKE/etc/aishie.env"
update || fail "exit $?: $(cat "$FAKE/out")"
! said "had before" || fail "said: $(cat "$FAKE/out")"
[ ! -e "$FAKE/state/settings.noted" ] || fail "the note is kept"
update --status || fail "--status: exit $?"
! said "had before" || fail "--status: $(cat "$FAKE/out")"

# A server set up as production before stable had its name: it still
# follows releases alone.
setup old-production
sed -i 's/^ENVIRONMENT=.*/ENVIRONMENT=production/' "$FAKE/etc/aishie.env"
if update; then fail "production took :edge"; fi
grep -q "stable follows releases: $CORE:edge is not a release" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"
grep -q "ENVIRONMENT=production in .* is the name stable had before: it is taken as stable" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"
tag "$CORE:0.2.0" "$A"
tag "$RUNTIME:0.4.0" "$B"
tag "$WEB:0.3.0" "$C"
sed -i "s|^CORE_IMAGE=.*|CORE_IMAGE=$CORE:0.2.0|; s|^RUNTIME_IMAGE=.*|RUNTIME_IMAGE=$RUNTIME:0.4.0|; s|^WEB_IMAGE=.*|WEB_IMAGE=$WEB:0.3.0|" "$FAKE/etc/aishie.env"
update || fail "production refused releases: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
[ "$(logged 'the name stable had before')" = 1 ] || fail "logged the old name $(logged 'the name stable had before') times, not once"
update --status || fail "--status: exit $?"
said "^test.aishie.app (stable)$" || fail "--status: $(cat "$FAKE/out")"

# No channel yet (stable before its versions are set): said, not guessed.
setup no-channel
sed -i 's/^CORE_IMAGE=.*/CORE_IMAGE=/' "$FAKE/etc/aishie.env"
if update; then fail "passed with no channel"; fi
grep -q "no channel: set CORE_IMAGE" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"
! called "docker pull" || fail "pulled something"

# --dry-run: says, and changes nothing.
setup dry-run
deployed
image core "$D" v0.2.1 def4567
tag "$CORE:edge" "$D"
before=$(cat "$FAKE/log")
update --dry-run || fail "exit $?: $(cat "$FAKE/out")"
said "core: would deploy $CORE@sha256:$D" || fail "said: $(cat "$FAKE/out")"
said "runtime: up to date" || fail "said: $(cat "$FAKE/out")"
! called "up -d" || fail "started something"
! called "pg_dump" || fail "backed up"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"
[ "$(cat "$FAKE/log")" = "$before" ] || fail "logged something"

# Another run holds the lock: nothing runs.
setup lock-held
if FLOCK_FAIL=1 update; then fail "ran without the lock"; fi
! called "docker" || fail "ran docker: $(head -n 3 "$CALLS")"
said "held the lock" || fail "said: $(cat "$FAKE/out")"

# No settings: nothing runs.
setup no-settings
rm "$FAKE/etc/aishie.env"
if update; then fail "ran without aishie.env"; fi
[ ! -s "$CALLS" ] || fail "ran something: $(head -n 3 "$CALLS")"

# Bad arguments: usage, and nothing runs.
for args in "--retry" "--retry nginx" "--pin core" "--pin db sha256:$A" "--frobnicate" "extra"; do
  setup "usage"
  # shellcheck disable=SC2086 # the arguments, split
  if update $args; then fail "took «$args»"; fi
  [ ! -s "$CALLS" ] || fail "ran something for «$args»"
done

# The environment does not steer compose: a CORE_REF left in the operator's
# shell is not what runs.
setup environment
CORE_REF=$REG/aishie-core@sha256:$F HOST=evil.example update || fail "exit $?: $(cat "$FAKE/out")"
[ "$(running core)" = "$CORE@sha256:$A" ] || fail "core runs $(running core)"

# No secret from the env files, anywhere.
for f in "$work"/*/out "$work"/*/log "$work"/*/state/*; do
  [ -f "$f" ] || continue
  if grep -q "$SECRET" "$f"; then case=secrets fail "$f holds a secret"; fi
done

[ "$failed" = 0 ] && echo "aishie-update: ok"
exit "$failed"
