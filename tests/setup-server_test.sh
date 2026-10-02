#!/usr/bin/env bash
# setup-server.sh against stand-ins. Its pure parts are sourced with
# AISHIE_SETUP_LIB=1, in sh as the server runs them; then whole runs, as root
# would make them, with docker, apt, ufw, systemctl and id played by
# tests/fakes.sh and the stand-ins below, and a bucket's S3 service by the
# fake curl. The first update is the real aishie-update, against the fake
# registry. tests/aishie-storage_test.sh has the rest of the bucket's
# functions.
#
#   make test
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
. "$here/fakes.sh"
make_fakes "$work/bin"

# The stand-ins setup-server.sh needs besides: apt (APT_COMPOSE is the
# docker-compose-v2 version Ubuntu offers, none by default; installing it
# makes that the compose `docker compose version` says), dpkg-query
# (DOCKER_CE: docker-ce is installed), cloud-init, systemctl, ufw
# (UFW_ACTIVE), id (NOT_ROOT), and chown, which is only recorded, for the
# aishie the run installs and runs: the tests are not root.
cat > "$work/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$CALLS"
case "$*" in
  *" install "*docker-compose-v2*) echo "${APT_COMPOSE%%+*}" > "$FAKE/compose-version" ;;
  *" install "*docker-compose-plugin*) echo 2.39.4 > "$FAKE/compose-version" ;;
esac
EOF
cat > "$work/bin/apt-cache" <<'EOF'
#!/bin/sh
echo "apt-cache $*" >> "$CALLS"
printf '%s:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n' "${2:-}" "${APT_COMPOSE:-(none)}"
EOF
cat > "$work/bin/dpkg-query" <<'EOF'
#!/bin/sh
if [ -n "${DOCKER_CE:-}" ]; then printf 'install ok installed'; else exit 1; fi
EOF
printf '#!/bin/sh\nexit 0\n' > "$work/bin/cloud-init"
cat > "$work/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$CALLS"
EOF
cat > "$work/bin/ufw" <<'EOF'
#!/bin/sh
echo "ufw $*" >> "$CALLS"
if [ "$1" = status ]; then
  if [ -n "${UFW_ACTIVE:-}" ]; then echo "Status: active"; else echo "Status: inactive"; fi
fi
EOF
cat > "$work/bin/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -u ]; then echo "${NOT_ROOT:-0}"; else exec /usr/bin/id "$@"; fi
EOF
cat > "$work/bin/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$CALLS"
EOF
chmod +x "$work/bin"/*

REG=ghcr.io/aishie-education
AK=AKIAFAKEACCESSKEY0001
# A secret with a $ in it, which core.env must quote.
# shellcheck disable=SC2016 # the $ is the secret's
SK='fake/Secret+Key$0123456789abcdefghijklmno'
R2=0123456789abcdef0123456789abcdef
A=$(printf 'a%.0s' $(seq 64))
B=$(printf 'b%.0s' $(seq 64))
C=$(printf 'c%.0s' $(seq 64))

failed=0
fail() { echo "FAIL setup-server $case: $*" >&2; failed=1; }

# setup CASE: a fresh server, with the paths moved into the test's own
# directory, and a registry where each :edge names a healthy image.
setup() {
  case=$1
  export FAKE=$work/$case CALLS=$work/$case/calls
  mkdir -p "$FAKE"
  : > "$CALLS"
  export AISHIE_ETC=$FAKE/etc AISHIE_STATE=$FAKE/state AISHIE_APP=$FAKE/opt AISHIE_DATA=$FAKE/srv \
    AISHIE_BACKUPS=$FAKE/backups AISHIE_BIN=$FAKE/usr-local-bin AISHIE_UNITS=$FAKE/units \
    AISHIE_LOCK_FILE=$FAKE/lock AISHIE_LOG_FILE=$FAKE/log AISHIE_HEALTH_TRIES=3
  unset PULL_FAIL CADDY_FAIL FLOCK_FAIL COMPOSE_PULL_FAIL ISSUE_FAIL SERVICE_TOKEN APT_COMPOSE DOCKER_CE UFW_ACTIVE NOT_ROOT COMPOSE_VERSION INVOCATION_ID \
    S3_LIST S3_HEAD S3_CORS_GET S3_CORS_PUT S3_DOWN AISHIE_STORAGE AISHIE_S3_BUCKET AISHIE_S3_REGION AISHIE_S3_ENDPOINT \
    AISHIE_S3_PATH_STYLE AISHIE_R2_ACCOUNT_ID AISHIE_R2_JURISDICTION AISHIE_S3_ACCESS_KEY AISHIE_S3_SECRET_KEY
  image core "$A" v0.2.0 abc1234
  image runtime "$B" v0.4.0 bcd2345
  image web "$C" v0.3.0 cde3456
  tag "$REG/aishie-core:edge" "$A"
  tag "$REG/aishie-agent-runtime:edge" "$B"
  tag "$REG/aishie-frontend:edge" "$C"
}
# lib FUNCTION ARGS...: one of setup-server.sh's functions, in sh.
lib() { PATH="$work/bin:$PATH" AISHIE_SETUP_LIB=1 sh -c '. "$0"; "$@"' "$root/setup-server.sh" "$@"; }
# setup_server ARGS...: a whole run, as root; chown and systemd are only
# recorded (the tests are not root, and need not run under systemd). With
# ANSWERS, someone is there to answer, with that file's lines.
setup_server() {
  PATH="$work/bin:$PATH" AISHIE_SETUP_LIB=1 ASKED=${ANSWERS:+1} sh -c '
    . "$0"
    own() { echo "chown $*" >> "$CALLS"; }
    systemd() { true; }
    if [ -n "$ASKED" ]; then st_interactive() { true; }; fi
    main "$@"' "$root/setup-server.sh" "$@" < "${ANSWERS:-/dev/null}" > "$FAKE/out" 2>&1
}
called() { grep -q -- "$1" "$CALLS"; }
said() { grep -q -- "$1" "$FAKE/out"; }
setting() { sed -n "s/^$2=//p" "$AISHIE_ETC/$1" | tail -n 1; }
mode() { stat -c %a "$1"; }
sums() { (cd "$AISHIE_ETC" && find . -type f -exec sha256sum {} + | sort); }
# is_secrets_key VALUE: 32 bytes in base64, as SECRETS_KEY is.
is_secrets_key() { [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]] && [ "$(printf '%s' "$1" | base64 -d | wc -c)" = 32 ]; }

# The arguments: edge and stable, and their old names, staging and
# production, until a later release.
case=args
for good in "test.aishie.app edge" "localhost stable" "aishie.localhost edge" "a-b.example.edu edge" \
  "test.aishie.app staging" "localhost production"; do
  # shellcheck disable=SC2086 # the arguments, split
  lib check_args $good || fail "refused «$good»"
done
for bad in "'' edge" "a\ b edge" "-x edge" "../etc edge" "a..b edge" ".a edge" "a;id edge" \
  "test.aishie.app" "test.aishie.app dev" "test.aishie.app Edge" "test.aishie.app Staging" "test.aishie.app prod"; do
  if eval "lib check_args $bad" 2>/dev/null; then fail "took «$bad»"; fi
done
for pair in "edge edge" "stable stable" "staging edge" "production stable"; do
  [ "$(lib environment_of "${pair% *}")" = "${pair#* }" ] || fail "${pair% *} is taken as «$(lib environment_of "${pair% *}")»"
done

# Versions of compose, as Docker's and Ubuntu's packages write them.
case=versions
for v in 2.24.0 2.24.6+ds1-0ubuntu1~24.04.1 v2.27.0 2.39.4 5.1.1 3.0; do
  lib version_at_least "$v" 2.24 || fail "$v is not taken as 2.24 or later"
done
for v in 2.23.3 2.20.2+ds1-0ubuntu1~22.04.1 1.29.2 v2.9.0 ''; do
  if lib version_at_least "$v" 2.24; then fail "«$v» is taken as 2.24 or later"; fi
done

# Where Docker comes from: Ubuntu's packages when they have compose 2.24 or
# later, else Docker's apt repository, which also wins when docker-ce is
# installed already.
case=docker-source
setup docker-source
[ "$(APT_COMPOSE=2.24.6+ds1-0ubuntu1~24.04.1 lib docker_source)" = "ubuntu 2.24.6+ds1-0ubuntu1~24.04.1" ] ||
  fail "noble's compose: $(APT_COMPOSE=2.24.6+ds1-0ubuntu1~24.04.1 lib docker_source)"
[ "$(APT_COMPOSE=2.20.2+ds1-0ubuntu1~22.04.1 lib docker_source)" = docker ] || fail "jammy's compose is taken"
[ "$(lib docker_source)" = docker ] || fail "no candidate: $(lib docker_source)"
[ "$(DOCKER_CE=1 APT_COMPOSE=2.24.6 lib docker_source)" = docker ] || fail "Ubuntu's, beside docker-ce"

# Docker and compose there already: left alone.
case=docker-there
setup docker-there
lib install_docker > "$FAKE/out" 2>&1 || fail "exit $?: $(cat "$FAKE/out")"
! called "apt-get" || fail "installed something: $(grep apt-get "$CALLS")"
said "compose 2.27.0 are installed: left as they are" || fail "said: $(cat "$FAKE/out")"
# Compose too old: Ubuntu's, when they are recent enough.
setup docker-old
COMPOSE_VERSION=2.20.2 APT_COMPOSE=2.24.6+ds1-0ubuntu1~24.04.1 lib install_docker > "$FAKE/out" 2>&1 || fail "exit $?: $(cat "$FAKE/out")"
called "install -y -q docker.io docker-compose-v2" || fail "ran: $(cat "$CALLS")"
said "installing Docker from Ubuntu's packages" || fail "said: $(cat "$FAKE/out")"

# A fresh server, edge: everything, then the first update.
setup fresh
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
# Its settings, from the arguments.
[ "$(setting aishie.env HOST)" = test.aishie.app ] || fail "HOST=$(setting aishie.env HOST)"
[ "$(setting aishie.env ENVIRONMENT)" = edge ] || fail "ENVIRONMENT=$(setting aishie.env ENVIRONMENT)"
[ "$(setting aishie.env CORE_IMAGE)" = "$REG/aishie-core:edge" ] || fail "CORE_IMAGE=$(setting aishie.env CORE_IMAGE)"
[ "$(setting aishie.env RUNTIME_IMAGE)" = "$REG/aishie-agent-runtime:edge" ] || fail "RUNTIME_IMAGE=$(setting aishie.env RUNTIME_IMAGE)"
[ "$(setting aishie.env WEB_IMAGE)" = "$REG/aishie-frontend:edge" ] || fail "WEB_IMAGE=$(setting aishie.env WEB_IMAGE)"
[ -z "$(setting aishie.env FRAME_ANCESTORS)" ] || fail "FRAME_ANCESTORS is set: $(setting aishie.env FRAME_ANCESTORS)"
# Every setting the example has, with the example's value (it is an edge
# server named test.aishie.app too), so that compose.yaml finds each.
while IFS='=' read -r n v; do
  [ "$(setting aishie.env "$n")" = "$v" ] || fail "$n=$(setting aishie.env "$n"), the example has $v"
done < <(grep -E '^[A-Z_]+=' "$root/env/aishie.env.example")
# The secrets: generated, root's alone, and the same password on both
# sides of each database.
for f in aishie core runtime postgres; do
  [ "$(mode "$AISHIE_ETC/$f.env")" = 600 ] || fail "$f.env is $(mode "$AISHIE_ETC/$f.env")"
done
core_pw=$(setting postgres.env AISHIE_CORE_DB_PASSWORD)
runtime_pw=$(setting postgres.env AISHIE_RUNTIME_DB_PASSWORD)
[[ $core_pw =~ ^[0-9a-f]{48}$ ]] || fail "the core database's password is not 24 random bytes in hex"
[[ $runtime_pw =~ ^[0-9a-f]{48}$ ]] || fail "the runtime database's password is not 24 random bytes in hex"
[[ $(setting postgres.env POSTGRES_PASSWORD) =~ ^[0-9a-f]{48}$ ]] || fail "POSTGRES_PASSWORD is not 24 random bytes in hex"
[ "$core_pw" != "$runtime_pw" ] || fail "the two databases have one password"
[ "$(setting core.env DATABASE_URL)" = "postgres://aishie_core:$core_pw@postgres:5432/aishie_core?sslmode=disable" ] ||
  fail "core's DATABASE_URL does not match postgres.env"
[ "$(setting runtime.env DATABASE_URL)" = "postgres://aishie_runtime:$runtime_pw@postgres:5432/aishie_runtime?sslmode=disable" ] ||
  fail "the runtime's DATABASE_URL does not match postgres.env"
[[ $(setting core.env SIGNING_KEY) =~ ^[0-9a-f]{64}$ ]] || fail "SIGNING_KEY is not 32 random bytes in hex"
# SECRETS_KEY, beside it, once: 32 random bytes in base64, as Core takes it.
secrets_key=$(setting core.env SECRETS_KEY)
is_secrets_key "$secrets_key" || fail "SECRETS_KEY is not 32 random bytes in base64"
[ "$(grep -c '^SECRETS_KEY=' "$AISHIE_ETC/core.env")" = 1 ] || fail "SECRETS_KEY is there $(grep -c '^SECRETS_KEY=' "$AISHIE_ETC/core.env") times"
said "with generated passwords, SIGNING_KEY and SECRETS_KEY" || fail "said: $(cat "$FAKE/out")"
! said "added SECRETS_KEY" || fail "said it added SECRETS_KEY to the core.env it wrote"
[ "$(setting core.env BLOB_FS_ROOT)" = /data/blobs ] || fail "BLOB_FS_ROOT=$(setting core.env BLOB_FS_ROOT)"
# Nobody to ask and no options: this server's disk, as before.
[ "$(setting core.env BLOB_STORE)" = fs ] || fail "BLOB_STORE=$(setting core.env BLOB_STORE)"
! grep -q '^S3_' "$AISHIE_ETC/core.env" || fail "S3 settings for a server on its disk: $(grep '^S3_' "$AISHIE_ETC/core.env")"
said "Core keeps the files people upload on this server's disk" || fail "did not say where the files are kept"
! called "aws-sigv4" || fail "asked a bucket something"
[ "$(setting runtime.env KMS_KEY_ID)" = local:/secrets/kek/v1 ] || fail "KMS_KEY_ID=$(setting runtime.env KMS_KEY_ID)"
# The key that seals the runtime's stored secrets: 32 random bytes, base64, in
# the secrets directory, readable by the runtime's group alone.
kek=$AISHIE_ETC/runtime/secrets/kek/v1
[ "$(base64 -d < "$kek" | wc -c)" = 32 ] || fail "kek/v1 is not 32 bytes in base64"
[ "$(mode "$kek")" = 640 ] || fail "kek/v1 is $(mode "$kek")"
called "chown root:65532 ${kek%/*}/.v1.new" || fail "kek/v1 not given to the runtime's group"
# The directories, each with its owner and mode.
for d in "$AISHIE_ETC" "$AISHIE_ETC/runtime" "$AISHIE_STATE" "$AISHIE_BACKUPS"; do
  [ "$(mode "$d")" = 700 ] || fail "$d is $(mode "$d")"
done
for d in agents secrets secrets/kek secrets/core; do
  [ "$(mode "$AISHIE_ETC/runtime/$d")" = 750 ] || fail "runtime/$d is $(mode "$AISHIE_ETC/runtime/$d")"
  called "chown root:65532 $AISHIE_ETC/runtime/$d$" || fail "runtime/$d not given to the runtime's group"
done
called "chown 65532:65532 $AISHIE_DATA/core$" || fail "Core's files not given to Core's user"
# This copy's stack, scripts and units, installed.
for f in compose.yaml stack.yaml README.md caddy/Caddyfile postgres/initdb/10-aishie.sh env/core.env.example docs/troubleshooting.md; do
  cmp -s "$root/$f" "$AISHIE_APP/$f" || fail "$f not installed in $AISHIE_APP"
done
[ -x "$AISHIE_APP/postgres/initdb/10-aishie.sh" ] || fail "the init script is not executable"
for f in aishie-update aishie aishie-storage; do
  if ! cmp -s "$root/bin/$f" "$AISHIE_BIN/$f" || [ ! -x "$AISHIE_BIN/$f" ]; then fail "$f not installed in $AISHIE_BIN"; fi
done
for f in aishie-update.service aishie-update.timer aishie-backup.service aishie-backup.timer; do
  cmp -s "$root/systemd/$f" "$AISHIE_UNITS/$f" || fail "$f not installed in $AISHIE_UNITS"
done
called "systemctl daemon-reload" || fail "no daemon-reload"
called "systemctl enable --now aishie-update.timer aishie-backup.timer" || fail "the timers are not on"
# Caddy's configuration checked before Caddy runs it; PostgreSQL started and
# never recreated; the three images pulled.
called "docker run --rm --network none -e HOST=test.aishie.app .* caddy:2 caddy validate" || fail "no caddy validate"
[ "$(grep -n 'caddy validate' "$CALLS" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'up -d --no-deps caddy' "$CALLS" | head -n 1 | cut -d: -f1)" ] ||
  fail "Caddy started before its Caddyfile was checked"
called "up -d --no-recreate --wait --wait-timeout 180 postgres" || fail "PostgreSQL not started"
! called "up -d postgres" || fail "PostgreSQL recreated"
for img in "$REG/aishie-core:edge" "$REG/aishie-agent-runtime:edge" "$REG/aishie-frontend:edge"; do
  said "can pull $img" || fail "did not check the pull of $img: $(cat "$FAKE/out")"
done
# The first update deployed the three, in order; then each is recreated
# under the updater's lock, for a change to stack.yaml.
grep -q "^CORE_REF=$REG/aishie-core@sha256:$A$" "$AISHIE_STATE/images.env" || fail "core not deployed: $(cat "$AISHIE_STATE/images.env")"
grep -q "^RUNTIME_REF=$REG/aishie-agent-runtime@sha256:$B$" "$AISHIE_STATE/images.env" || fail "the runtime not deployed"
grep -q "^WEB_REF=$REG/aishie-frontend@sha256:$C$" "$AISHIE_STATE/images.env" || fail "the web not deployed"
# aishie-update's, aishie runtime-credential's (below), and this one's.
[ "$(grep -c 'flock -w 600 9' "$CALLS")" = 3 ] || fail "the recreate did not take aishie-update's lock"
[ "$(grep -n 'flock -w 600 9' "$CALLS" | tail -n 1 | cut -d: -f1)" -lt "$(grep -n 'up -d --no-deps web' "$CALLS" | tail -n 1 | cut -d: -f1)" ] ||
  fail "the web was recreated outside the lock"
# The runtime's credential for Core: issued once Core was migrated, by Core's
# `service issue` in the image Core runs, with --replace; its standard output
# put in the file whole, under another name until it was, root's alone, then
# the runtime's user's, still 0600, in a directory of the runtime's group;
# and the runtime recreated after, to take it.
cred=$AISHIE_ETC/runtime/secrets/core/agent_runtime
line() { grep -n -- "$1" "$CALLS" | head -n 1 | cut -d: -f1; }
[ "$(grep -c 'service issue' "$CALLS")" = 1 ] || fail "issued $(grep -c 'service issue' "$CALLS") credentials"
called "^docker compose --project-directory $AISHIE_APP -f $AISHIE_APP/compose.yaml run --rm --no-deps -T core service issue agent_runtime --label runtime --replace$" ||
  fail "not issued by Core's service issue, with --replace: $(grep 'service issue' "$CALLS")"
[ "$(line 'run -d --no-deps core migrate up')" -lt "$(line 'service issue')" ] || fail "issued before Core was migrated"
[ -s "$cred" ] || fail "no credential in $cred"
[ "$(cat "$cred")" = "$(tail -n 1 "$FAKE/issued")" ] || fail "the file is not what Core printed"
[ "$(wc -l < "$cred")" = 1 ] || fail "the file is not Core's one line"
[ "$(mode "$cred")" = 600 ] || fail "the credential is $(mode "$cred")"
called "chown 65532:65532 $cred.new$" || fail "the credential not given to the runtime's user: $(grep chown "$CALLS")"
! ls "$cred".* >/dev/null 2>&1 || fail "left $(ls "$cred".*)"
[ "$(line 'service issue')" -lt "$(line 'up -d --no-deps --force-recreate runtime')" ] || fail "the runtime was not recreated after the issue"
said "aishie: kept in $cred, which the runtime reads as secret://core/agent_runtime" || fail "said: $(cat "$FAKE/out")"
said "credential 0192f3c1-.* for the site service agent_runtime, 0 other(s) revoked$" || fail "Core's description not shown: $(cat "$FAKE/out")"
! said "shown once" || fail "said the credential is shown"
! said "runtime's credential for Core, which it hosts agents with" || fail "said the credential is left to do"
# What is left, said; and no secret anywhere in what it printed.
said "Point test.aishie.app at this server" || fail "no DNS step: $(cat "$FAKE/out")"
said "aishie admin" || fail "no step for the first administrator"
said "install -g 65532 -m 640 tutor.yaml" || fail "no agent step"
said "names its agent_id and holds no token" || fail "the agent step does not say agents name their agent_id: $(cat "$FAKE/out")"
! said "core_token" || fail "the agent step still has a token pasted: $(cat "$FAKE/out")"
said "it holds SIGNING_KEY, SECRETS_KEY and the runtime's key" || fail "no step to keep a copy of the keys: $(cat "$FAKE/out")"
said "runtime's credential for Core (README.md, What to keep off the server)" || fail "the copy step does not name the credential: $(cat "$FAKE/out")"
! said "docker logout" || fail "said how to pull, though every pull worked"
! said "notice:" || fail "said a notice: $(cat "$FAKE/out")"
for secret in "$core_pw" "$runtime_pw" "$(setting postgres.env POSTGRES_PASSWORD)" "$(setting core.env SIGNING_KEY)" "$secrets_key" "$(cat "$kek")" "$(cat "$cred")"; do
  if grep -qF -- "$secret" "$FAKE/out" "$CALLS" "$FAKE/log"; then fail "a secret is in the output, a command line or the log"; fi
done
if grep -qrF -- "$(cat "$cred")" "$FAKE/journal" "$AISHIE_STATE" 2>/dev/null; then fail "the credential is in the journal or the state"; fi

# Run again: this copy's files over the old ones, and the settings, the
# secrets and the key as they were.
case=again
before=$(sums)
echo "an old aishie" > "$AISHIE_BIN/aishie"
: > "$CALLS"
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "changed $AISHIE_ETC: $(diff <(echo "$before") <(sums))"
cmp -s "$root/bin/aishie" "$AISHIE_BIN/aishie" || fail "did not install aishie again"
said "aishie.env is there already: left as it is (HOST=test.aishie.app)" || fail "said: $(cat "$FAKE/out")"
said "core.env and runtime.env are there already: left as they are" || fail "said: $(cat "$FAKE/out")"
said "kek/v1 is there already: left as it is" || fail "said: $(cat "$FAKE/out")"
! said "added SECRETS_KEY" || fail "added SECRETS_KEY to a core.env that has it: $(cat "$FAKE/out")"
[ "$(grep -c 'up to date' "$FAKE/out")" = 3 ] || fail "the update did something: $(cat "$FAKE/out")"
! called "pg_dump" || fail "backed up, with nothing to deploy"
# ... the runtime's credential among them, byte for byte (above): no issue,
# and the runtime not recreated for it.
said "core/agent_runtime is there already: left as it is" || fail "said: $(cat "$FAKE/out")"
! called "service issue" || fail "issued a credential beside the one there: $(grep 'service issue' "$CALLS")"
! called "force-recreate" || fail "recreated the runtime: $(grep force-recreate "$CALLS")"
[ "$(wc -l < "$FAKE/issued")" = 1 ] || fail "Core issued $(wc -l < "$FAKE/issued") credentials in all"

# The credential's file lost, or emptied: issued once again, with --replace,
# which revokes the one lost, into the file, and the runtime recreated with
# it; nothing else in $AISHIE_ETC changes, and nothing prints it.
case=credential-lost
for how in removed emptied; do
  old=$(cat "$cred")
  if [ $how = removed ]; then rm "$cred"; else : > "$cred"; fi
  others=$(sums | grep -v ' \./runtime/secrets/core/agent_runtime$')
  : > "$CALLS"
  setup_server test.aishie.app edge || fail "$how: exit $?: $(cat "$FAKE/out")"
  [ "$(grep -c 'service issue' "$CALLS")" = 1 ] || fail "$how: issued $(grep -c 'service issue' "$CALLS") credentials"
  called "run --rm --no-deps -T core service issue agent_runtime --label runtime --replace$" || fail "$how: not with --replace: $(grep 'service issue' "$CALLS")"
  [ "$(cat "$cred")" = "$(tail -n 1 "$FAKE/issued")" ] || fail "$how: the file is not what Core printed"
  [ "$(cat "$cred")" != "$old" ] || fail "$how: the credential is the old one"
  [ "$(mode "$cred")" = 600 ] || fail "$how: the credential is $(mode "$cred")"
  said "other(s) revoked$" || fail "$how: Core's description not shown: $(cat "$FAKE/out")"
  called "up -d --no-deps --force-recreate runtime" || fail "$how: the runtime was not recreated"
  [ "$(sums | grep -v ' \./runtime/secrets/core/agent_runtime$')" = "$others" ] || fail "$how: changed another file in $AISHIE_ETC"
  if grep -qF -- "$(cat "$cred")" "$FAKE/out" "$CALLS" "$FAKE/log"; then fail "$how: the credential is in the output, a command line or the log"; fi
done
case=again
# ... another name, given by mistake: said, and aishie.env left as it is.
setup_server other.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
said "warning: .*aishie.env says HOST=test.aishie.app, not other.aishie.app" || fail "no warning: $(cat "$FAKE/out")"
[ "$(setting aishie.env HOST)" = test.aishie.app ] || fail "HOST changed to $(setting aishie.env HOST)"

# ... asked for a bucket then: said how to move the files, and core.env
# left as it is.
before=$(sums)
AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server test.aishie.app edge --storage aws --s3-region ap-east-1 --s3-bucket aishie-files ||
  fail "exit $?: $(cat "$FAKE/out")"
said "warning: .*core.env keeps uploaded files with BLOB_STORE=fs, and is left as it is: to move them, aishie storage migrate --to s3" ||
  fail "no warning: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "changed $AISHIE_ETC"
! called "aws-sigv4" || fail "asked the bucket something"

# ... after a rotation of the runtime's key (README.md, Rotating secrets),
# v2 in the keyring and v1 removed: no v1 made in its place, and nothing in
# /etc/aishie changed. A keyring with no key but a file in the making
# (.v2.new, which the runtime passes over) is given v1, and so is one that
# holds only what a run of setup-server.sh stopped before its mv left
# (.v1.new), which is replaced, not left beside v1.
case=key-rotated
kek_dir=$AISHIE_ETC/runtime/secrets/kek
mv "$kek_dir/v1" "$kek_dir/v2"
before=$(sums)
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
[ ! -e "$kek_dir/v1" ] || fail "made v1 beside v2"
[ "$(sums)" = "$before" ] || fail "changed $AISHIE_ETC: $(diff <(echo "$before") <(sums))"
said "$kek_dir holds the runtime's key already (v2): no v1 made" || fail "said: $(cat "$FAKE/out")"
rm "$kek_dir/v2"
echo partial > "$kek_dir/.v2.new"
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
[ "$(base64 -d < "$kek_dir/v1" | wc -c)" = 32 ] || fail "no v1 made in a keyring with no key"
said "made $kek_dir/v1" || fail "said: $(cat "$FAKE/out")"
rm "$kek_dir/v1" "$kek_dir/.v2.new"
: > "$kek_dir/.v1.new"
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
[ "$(base64 -d < "$kek_dir/v1" | wc -c)" = 32 ] || fail "no v1 made after an interrupted run"
[ ! -e "$kek_dir/.v1.new" ] || fail "left .v1.new beside v1"
said "made $kek_dir/v1" || fail "said: $(cat "$FAKE/out")"

# A server set up before SECRETS_KEY, set up again: core.env is given one,
# as one line at its end, and keeps every other line, its mode and its owner
# (the same file, appended to); nothing else in /etc/aishie changes, the key
# is printed nowhere, and Core is recreated with it. What fails says no
# line of core.env: they are secrets.
setup secrets-key-added
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
core_env=$AISHIE_ETC/core.env
grep -v '^SECRETS_KEY=' "$core_env" > "$FAKE/core.env.old"
old_last=$(tail -n 1 "$FAKE/core.env.old")
for last_newline in yes no; do
  # In place, as the copy from before wrote it: the same file, mode and
  # owner; and once with no newline after its last line.
  if [ $last_newline = yes ]; then
    cat "$FAKE/core.env.old" > "$core_env"
  else
    printf '%s' "$(cat "$FAKE/core.env.old")" > "$core_env"
  fi
  file=$(stat -c '%i %u:%g %a' "$core_env")
  others=$(sums | grep -v ' \./core\.env$')
  : > "$CALLS"
  setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
  said "added SECRETS_KEY to $core_env" || fail "said: $(cat "$FAKE/out")"
  said "must never be lost" || fail "did not say to keep it: $(cat "$FAKE/out")"
  said "A copy made before this run has no SECRETS_KEY" || fail "what is left does not say to copy $AISHIE_ETC again"
  [ "$(grep -c '^SECRETS_KEY=' "$core_env")" = 1 ] || fail "SECRETS_KEY is there $(grep -c '^SECRETS_KEY=' "$core_env") times"
  added=$(tail -n 1 "$core_env")
  [ "${added%%=*}" = SECRETS_KEY ] || fail "the last line is not SECRETS_KEY's"
  is_secrets_key "${added#SECRETS_KEY=}" || fail "the key added is not 32 random bytes in base64"
  cmp -s <(head -n -1 "$core_env") "$FAKE/core.env.old" || fail "core.env's other lines changed (last line with a newline: $last_newline)"
  [ "$(tail -n 2 "$core_env" | head -n 1)" = "$old_last" ] || fail "the line before the key is not the old last line"
  [ "$(stat -c '%i %u:%g %a' "$core_env")" = "$file" ] || fail "core.env is not the same file, owner and mode: $(stat -c '%i %u:%g %a' "$core_env"), was $file"
  [ "$(sums | grep -v ' \./core\.env$')" = "$others" ] || fail "changed another file in $AISHIE_ETC"
  for f in "$FAKE/out" "$CALLS" "$FAKE/log"; do
    if grep -qF -- "${added#SECRETS_KEY=}" "$f"; then fail "the key is in $(basename "$f")"; fi
  done
  called "up -d --no-deps core" || fail "Core was not recreated, to take the key"
done
# ... and again: the key kept, byte for byte, and none added.
before=$(sums)
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "changed $AISHIE_ETC: $(diff <(echo "$before") <(sums))"
! said "added SECRETS_KEY" || fail "added SECRETS_KEY again: $(cat "$FAKE/out")"
! said "A copy made before this run has no SECRETS_KEY" || fail "asked for a new copy of $AISHIE_ETC"

# A core.env that sets SECRETS_KEY already, however it is written, anywhere
# in it: left as it is, byte for byte, and no key added. One that sets it to
# nothing is said, since Core then sets no provider up.
case=secrets-key-kept
own_key=$(printf 'k%.0s' $(seq 43))=
for line in "SECRETS_KEY=$own_key" "SECRETS_KEY='$own_key'" "export SECRETS_KEY=$own_key" " SECRETS_KEY = $own_key" "SECRETS_KEY="; do
  { head -n 5 "$FAKE/core.env.old"; echo "$line"; tail -n +6 "$FAKE/core.env.old"; } > "$core_env"
  before=$(sums)
  setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
  [ "$(sums)" = "$before" ] || fail "changed $AISHIE_ETC, with «${line%%=*}=»"
  ! said "added SECRETS_KEY" || fail "added a key beside «${line%%=*}=»"
  if [ "$line" = "SECRETS_KEY=" ]; then
    said "warning: .*core.env says SECRETS_KEY with no value, and is left as it is" || fail "no warning: $(cat "$FAKE/out")"
  else
    ! said "warning: .*SECRETS_KEY" || fail "warned: $(cat "$FAKE/out")"
    if grep -qF -- "$own_key" "$FAKE/out"; then fail "the key is in the output"; fi
  fi
done

# ufw on: 80 and 443 opened, and nothing else.
setup ufw
UFW_ACTIVE=1 setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
for rule in 80/tcp 443/tcp 443/udp; do called "ufw allow $rule" || fail "ufw: no $rule"; done
[ "$(grep -c 'ufw allow' "$CALLS")" = 3 ] || fail "ufw: $(grep 'ufw allow' "$CALLS")"

# Docker Hub refuses the newest postgres:18 and caddy:2 for a while: the
# set-up goes on with the ones the server has.
setup docker-hub-refuses
COMPOSE_PULL_FAIL=1 setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
said "could not pull the newest postgres:18 and caddy:2 (above): going on with the ones this server has" || fail "said: $(cat "$FAKE/out")"
grep -q "^CORE_REF=" "$AISHIE_STATE/images.env" || fail "stopped before the first update"

# The images cannot be pulled: why it may be, said, with no login asked
# for (the packages are public), and the run fails once it has said what is
# left.
setup no-pull
if PULL_FAIL=1 setup_server test.aishie.app edge; then fail "passed though nothing could be pulled"; fi
said "cannot pull $REG/aishie-core:edge" || fail "said: $(cat "$FAKE/out")"
said "public packages" || fail "no pull help: $(cat "$FAKE/out")"
said "As root: docker logout ghcr.io" || fail "a stale login's way out is not said: $(cat "$FAKE/out")"
said "An image cannot be pulled" || fail "the troubleshooting section is not named"
! said "docker login" || fail "asked to log in: $(cat "$FAKE/out")"
[ -e "$AISHIE_ETC/core.env" ] || fail "the settings were not written before the pull"
! grep -q "_REF=" "$AISHIE_STATE/images.env" || fail "deployed something: $(cat "$AISHIE_STATE/images.env")"
! called "service issue" || fail "issued a credential with no Core"
said "^     aishie runtime-credential$" || fail "what is left does not give the runtime its credential: $(cat "$FAKE/out")"

# A Core from before migration 0025, which has no agent_runtime service:
# Core's refusal shown, nothing kept, and the rest of the run as it was, but
# for a step of what is left.
setup issue-refused
ISSUE_FAIL=1 setup_server test.aishie.app edge || fail "failed for a Core that cannot issue the credential: $(cat "$FAKE/out")"
called "service issue agent_runtime --label runtime --replace" || fail "did not ask Core: $(cat "$CALLS")"
said "no site service \"agent_runtime\"" || fail "Core's refusal not shown: $(cat "$FAKE/out")"
said "warning: the runtime was not given its credential for Core" || fail "said: $(cat "$FAKE/out")"
said "^     aishie runtime-credential$" || fail "not in what is left: $(cat "$FAKE/out")"
if [ -e "$AISHIE_ETC/runtime/secrets/core/agent_runtime" ] || ls "$AISHIE_ETC/runtime/secrets/core/agent_runtime".* >/dev/null 2>&1; then
  fail "left a file: $(ls "$AISHIE_ETC/runtime/secrets/core")"
fi
! called "force-recreate" || fail "recreated the runtime for nothing"
grep -q "^WEB_REF=" "$AISHIE_STATE/images.env" || fail "stopped before the web"
# ... and once Core has it, the run after issues it.
: > "$CALLS"
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
[ -s "$AISHIE_ETC/runtime/secrets/core/agent_runtime" ] || fail "not issued once Core could"
! said "aishie runtime-credential$" || fail "still left to do: $(cat "$FAKE/out")"

# Stable: no channel until a person sets the releases, so no update.
setup stable
setup_server aishie.example.edu stable || fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting aishie.env ENVIRONMENT)" = stable ] || fail "ENVIRONMENT=$(setting aishie.env ENVIRONMENT)"
for n in CORE_IMAGE RUNTIME_IMAGE WEB_IMAGE; do
  grep -qx "$n=" "$AISHIE_ETC/aishie.env" || fail "$n=$(setting aishie.env "$n")"
done
! called "docker pull" || fail "pulled something: $(grep 'docker pull' "$CALLS")"
said "Set the releases stable runs" || fail "said: $(cat "$FAKE/out")"
# ... nor Core to issue the runtime its credential: what is left says how,
# once it runs.
! called "service issue" || fail "issued a credential with no Core"
said "Core is not deployed yet: the runtime is given its credential for Core once it is" || fail "said: $(cat "$FAKE/out")"
said "The runtime's credential for Core, which it hosts agents with" || fail "not in what is left: $(cat "$FAKE/out")"
said "^     aishie runtime-credential$" || fail "what is left does not say how: $(cat "$FAKE/out")"
[ ! -e "$AISHIE_ETC/runtime/secrets/core/agent_runtime" ] || fail "wrote a credential"

# The old names as arguments: taken as edge and stable, said, and a new
# server's aishie.env written with the new names.
setup old-argument-staging
setup_server test.aishie.app staging || fail "exit $?: $(cat "$FAKE/out")"
said "notice: staging is called edge now: setting this server up for edge" || fail "said: $(cat "$FAKE/out")"
[ "$(setting aishie.env ENVIRONMENT)" = edge ] || fail "ENVIRONMENT=$(setting aishie.env ENVIRONMENT)"
[ "$(setting aishie.env CORE_IMAGE)" = "$REG/aishie-core:edge" ] || fail "CORE_IMAGE=$(setting aishie.env CORE_IMAGE)"
grep -q "^CORE_REF=$REG/aishie-core@sha256:$A$" "$AISHIE_STATE/images.env" || fail "core not deployed: $(cat "$AISHIE_STATE/images.env")"
setup old-argument-production
setup_server aishie.example.edu production || fail "exit $?: $(cat "$FAKE/out")"
said "notice: production is called stable now: setting this server up for stable" || fail "said: $(cat "$FAKE/out")"
[ "$(setting aishie.env ENVIRONMENT)" = stable ] || fail "ENVIRONMENT=$(setting aishie.env ENVIRONMENT)"
grep -qx "CORE_IMAGE=" "$AISHIE_ETC/aishie.env" || fail "CORE_IMAGE=$(setting aishie.env CORE_IMAGE)"
said "Set the releases stable runs" || fail "said: $(cat "$FAKE/out")"

# A server set up as staging, before edge had its name, as test.aishie.app
# was, set up again with this copy: aishie.env is left as it is, its old
# name said and taken, and the stack updates as before.
setup old-staging
setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
sed -i 's/^ENVIRONMENT=edge$/ENVIRONMENT=staging/' "$AISHIE_ETC/aishie.env"
before=$(sums)
D=$(printf 'd%.0s' $(seq 64))
image core "$D" v0.2.1 def4567
tag "$REG/aishie-core:edge" "$D"
for given in edge staging; do
  : > "$CALLS"
  setup_server test.aishie.app "$given" || fail "set up again with $given: exit $?: $(cat "$FAKE/out")"
  [ "$(sums)" = "$before" ] || fail "changed $AISHIE_ETC: $(diff <(echo "$before") <(sums))"
  said "notice: .*aishie.env says ENVIRONMENT=staging, the name edge had before: aishie-update takes it as edge" ||
    fail "no notice of the file's old name: $(cat "$FAKE/out")"
  ! said "warning: .*ENVIRONMENT" || fail "warned: $(cat "$FAKE/out")"
done
said "notice: staging is called edge now" || fail "no notice of the old argument: $(cat "$FAKE/out")"
grep -q "^CORE_REF=$REG/aishie-core@sha256:$D$" "$AISHIE_STATE/images.env" ||
  fail "the new :edge not deployed: $(cat "$AISHIE_STATE/images.env")"
[ "$(grep -c 'the name edge had before' "$FAKE/log")" = 1 ] || fail "log: $(cat "$FAKE/log")"
# ... and given the other environment by mistake: said, and left as it is.
setup_server test.aishie.app stable || fail "exit $?: $(cat "$FAKE/out")"
said "warning: .*aishie.env says ENVIRONMENT=staging, not stable" || fail "no warning: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "changed $AISHIE_ETC"

# A server set up as production before stable had its name, its releases
# set: set up again, it still runs them, and aishie.env is left as it is.
setup old-production
tag "$REG/aishie-core:0.2.0" "$A"
tag "$REG/aishie-agent-runtime:0.4.0" "$B"
tag "$REG/aishie-frontend:0.3.0" "$C"
setup_server aishie.example.edu stable || fail "exit $?: $(cat "$FAKE/out")"
sed -i "s/^ENVIRONMENT=stable$/ENVIRONMENT=production/; s|^CORE_IMAGE=.*|CORE_IMAGE=$REG/aishie-core:0.2.0|; s|^RUNTIME_IMAGE=.*|RUNTIME_IMAGE=$REG/aishie-agent-runtime:0.4.0|; s|^WEB_IMAGE=.*|WEB_IMAGE=$REG/aishie-frontend:0.3.0|" "$AISHIE_ETC/aishie.env"
# Nothing had deployed Core, so the runtime has no credential for Core yet:
# the one file this run writes.
before=$(sums)
setup_server aishie.example.edu stable || fail "exit $?: $(cat "$FAKE/out")"
[ "$(sums | grep -v ' \./runtime/secrets/core/agent_runtime$')" = "$before" ] || fail "changed $AISHIE_ETC"
[ -s "$AISHIE_ETC/runtime/secrets/core/agent_runtime" ] || fail "the runtime was not given its credential once Core ran"
said "notice: .*aishie.env says ENVIRONMENT=production, the name stable had before" || fail "said: $(cat "$FAKE/out")"
grep -q "^CORE_REF=$REG/aishie-core@sha256:$A$" "$AISHIE_STATE/images.env" || fail "core not deployed: $(cat "$AISHIE_STATE/images.env")"
grep -q "^WEB_REF=$REG/aishie-frontend@sha256:$C$" "$AISHIE_STATE/images.env" || fail "the web not deployed: $(cat "$AISHIE_STATE/images.env")"
# ... and :edge in its channel is still refused.
sed -i "s|^CORE_IMAGE=.*|CORE_IMAGE=$REG/aishie-core:edge|" "$AISHIE_ETC/aishie.env"
if setup_server aishie.example.edu stable; then fail "passed with :edge on a server set up as production"; fi
grep -q "stable follows releases: $REG/aishie-core:edge is not a release" "$FAKE/log" || fail "log: $(cat "$FAKE/log")"

# Some of the env files there, not all: refused, and nothing written.
setup partial
mkdir -p "$AISHIE_ETC"
echo "DATABASE_URL=kept" > "$AISHIE_ETC/core.env"
if setup_server test.aishie.app edge; then fail "passed with core.env alone"; fi
said "Some of .*postgres.env, core.env and runtime.env are there, but not all" || fail "said: $(cat "$FAKE/out")"
[ ! -e "$AISHIE_ETC/postgres.env" ] || fail "wrote postgres.env"
[ "$(cat "$AISHIE_ETC/core.env")" = "DATABASE_URL=kept" ] || fail "changed core.env"

# The database's volume without postgres.env: its passwords are unknown.
setup volume-without-env
mkdir -p "$FAKE/volumes"
touch "$FAKE/volumes/aishie_postgres"
if setup_server test.aishie.app edge; then fail "passed with a volume and no postgres.env"; fi
said "volume aishie_postgres is there, but" || fail "said: $(cat "$FAKE/out")"
[ ! -e "$AISHIE_ETC/postgres.env" ] || fail "wrote postgres.env"

# A Caddyfile Caddy refuses: Caddy is not started on it.
setup caddy-refuses
if CADDY_FAIL=1 setup_server test.aishie.app edge; then fail "passed while caddy validate failed"; fi
said "caddy validate refused" || fail "said: $(cat "$FAKE/out")"
! called "up -d --no-deps caddy" || fail "started Caddy"

# A bucket of AWS's, by the options, for a run nobody answers, with the keys
# in the environment: checked before anything is written, by reading alone,
# then written to core.env, and given the CORS rule the site's uploads need.
setup aws
AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage aws --s3-region ap-east-1 --s3-bucket aishie-files test.aishie.app edge ||
  fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env BLOB_STORE)" = s3 ] || fail "BLOB_STORE=$(setting core.env BLOB_STORE)"
[ "$(setting core.env S3_ENDPOINT)" = s3.ap-east-1.amazonaws.com ] || fail "S3_ENDPOINT=$(setting core.env S3_ENDPOINT)"
[ "$(setting core.env S3_BUCKET)" = aishie-files ] || fail "S3_BUCKET=$(setting core.env S3_BUCKET)"
[ "$(setting core.env S3_REGION)" = ap-east-1 ] || fail "S3_REGION=$(setting core.env S3_REGION)"
[ "$(setting core.env S3_BUCKET_LOOKUP)" = auto ] || fail "S3_BUCKET_LOOKUP=$(setting core.env S3_BUCKET_LOOKUP)"
[ "$(setting core.env S3_USE_SSL)" = true ] || fail "S3_USE_SSL=$(setting core.env S3_USE_SSL)"
[ "$(setting core.env S3_ACCESS_KEY)" = "$AK" ] || fail "S3_ACCESS_KEY is not the key given"
! said "needs a Core whose help names S3_BUCKET_LOOKUP" || fail "said a Core from after S3_BUCKET_LOOKUP is needed: $(cat "$FAKE/out")"
# In single quotes, for its $, which Compose would take for a variable.
[ "$(setting core.env S3_SECRET_KEY)" = "'$SK'" ] || fail "S3_SECRET_KEY is not the secret given, quoted"
[ "$(setting core.env BLOB_FS_ROOT)" = /data/blobs ] || fail "BLOB_FS_ROOT=$(setting core.env BLOB_FS_ROOT)"
[[ $(setting core.env SIGNING_KEY) =~ ^[0-9a-f]{64}$ ]] || fail "no SIGNING_KEY, which Core needs with a bucket"
[ "$(mode "$AISHIE_ETC/core.env")" = 600 ] || fail "core.env is $(mode "$AISHIE_ETC/core.env")"
[ "$(grep -n 'aws-sigv4' "$CALLS" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'pull -q postgres caddy' "$CALLS" | head -n 1 | cut -d: -f1)" ] ||
  fail "the bucket was not checked first"
called "curl .*--aws-sigv4 aws:amz:ap-east-1:s3 .*https://aishie-files.s3.ap-east-1.amazonaws.com/?list-type=2&max-keys=1&prefix=courses%2F" ||
  fail "the check: $(grep aws-sigv4 "$CALLS" | head -n 1)"
[ "$(head -n 2 "$FAKE/s3-requests" | cut -d ' ' -f 1 | tr '\n' ' ')" = "GET HEAD " ] || fail "the check wrote: $(head -n 2 "$FAKE/s3-requests")"
grep -qxF "user = \"$AK:$SK\"" "$FAKE/s3-keys" || fail "curl was not given the keys on its standard input"
grep -qF '<AllowedOrigin>https://test.aishie.app</AllowedOrigin>' "$FAKE/s3-cors" || fail "no CORS rule for the site"
said "Core keeps the files people upload in the bucket aishie-files of Amazon S3, in ap-east-1" || fail "said: $(cat "$FAKE/out")"
said "the bucket has a CORS rule now: https://test.aishie.app may upload to it" || fail "said: $(cat "$FAKE/out")"
! said "Give the bucket the CORS rule" || fail "asked for a CORS rule it has"
grep -q "^CORE_REF=" "$AISHIE_STATE/images.env" || fail "stopped before the first update"
for f in "$FAKE/out" "$CALLS" "$FAKE/log" "$FAKE/s3-requests"; do
  if grep -qF -- "$SK" "$f"; then fail "the secret key is in $(basename "$f")"; fi
done

# R2 by the variables alone, but the bucket, as --name=value; B2 and
# another service by their options.
setup r2
AISHIE_STORAGE=r2 AISHIE_R2_ACCOUNT_ID=$R2 AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server test.aishie.app edge --s3-bucket=files ||
  fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION) $(setting core.env S3_BUCKET)" = "$R2.r2.cloudflarestorage.com auto files" ] ||
  fail "R2: $(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION) $(setting core.env S3_BUCKET)"
called "aws:amz:auto:s3 .*https://$R2.r2.cloudflarestorage.com/files/?list-type=2" || fail "R2's check: $(grep aws-sigv4 "$CALLS" | head -n 1)"
setup b2
AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage b2 --s3-region us-west-004 --s3-bucket files test.aishie.app edge ||
  fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION)" = "s3.us-west-004.backblazeb2.com us-west-004" ] ||
  fail "B2: $(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION)"
setup s3
AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage s3 --s3-endpoint https://s3.example.edu --s3-bucket files test.aishie.app edge ||
  fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION) $(setting core.env S3_USE_SSL)" = "s3.example.edu us-east-1 true" ] ||
  fail "s3: $(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION) $(setting core.env S3_USE_SSL)"
[ "$(setting core.env S3_BUCKET_LOOKUP)" = auto ] || fail "S3_BUCKET_LOOKUP=$(setting core.env S3_BUCKET_LOOKUP)"
called "https://s3.example.edu/files/?list-type=2" || fail "not by path: $(grep aws-sigv4 "$CALLS" | head -n 1)"
# A service that takes only virtual-hosted requests, and an AWS region
# newer than the table of Core's S3 client: each said to need a Core that
# reads S3_BUCKET_LOOKUP, which the first update deploys.
setup s3-dns
AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage s3 --s3-endpoint s3.example.edu --s3-bucket files --s3-path-style no test.aishie.app edge ||
  fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env S3_ENDPOINT) $(setting core.env S3_BUCKET_LOOKUP)" = "s3.example.edu dns" ] ||
  fail "s3, virtual-hosted: $(setting core.env S3_ENDPOINT) $(setting core.env S3_BUCKET_LOOKUP)"
called "https://files.s3.example.edu/?list-type=2" || fail "not in the host name: $(grep aws-sigv4 "$CALLS" | head -n 1)"
said "--s3-path-style no needs a Core whose help names S3_BUCKET_LOOKUP (any from its main since its PR #46, d8f256c): the first Core this server deploys must be one" ||
  fail "said: $(cat "$FAKE/out")"
grep -q "^CORE_REF=" "$AISHIE_STATE/images.env" || fail "stopped before the first update"
# ... and on stable, where a person sets the release, what is left says
# CORE_IMAGE must be one; a bucket any Core reaches is not said to.
! said "The bucket needs a Core whose help names S3_BUCKET_LOOKUP" || fail "said on edge: $(cat "$FAKE/out")"
setup s3-dns-stable
AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage s3 --s3-endpoint s3.example.edu --s3-bucket files --s3-path-style no aishie.example.edu stable ||
  fail "exit $?: $(cat "$FAKE/out")"
said "The bucket needs a Core whose help names S3_BUCKET_LOOKUP (above), which" || fail "not in what is left: $(cat "$FAKE/out")"
said "^     docker run --rm IMAGE help | grep S3_BUCKET_LOOKUP$" || fail "what is left does not say how: $(cat "$FAKE/out")"
setup s3-stable
AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage s3 --s3-endpoint s3.example.edu --s3-bucket files aishie.example.edu stable ||
  fail "exit $?: $(cat "$FAKE/out")"
said "Set the releases stable runs" || fail "said: $(cat "$FAKE/out")"
! said "The bucket needs a Core" || fail "said for a bucket any Core reaches: $(cat "$FAKE/out")"
setup aws-new-region
AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage aws --s3-region ap-southeast-9 --s3-bucket aishie-files test.aishie.app edge ||
  fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION)" = "s3.ap-southeast-9.amazonaws.com ap-southeast-9" ] ||
  fail "aws: $(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION)"
said "the region ap-southeast-9, newer than the table of Core's S3 client, needs a Core" || fail "said: $(cat "$FAKE/out")"
# ... asked, with someone to answer: Enter leaves it to Core's S3 client.
setup s3-asked
printf '5\ns3.example.edu\n\nfiles\nno\n%s\n%s\n' "$AK" "$SK" > "$FAKE/answers"
ANSWERS=$FAKE/answers setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
said "Bucket in the path, https://HOST/BUCKET/KEY (yes), or in the host name, https://BUCKET.HOST/KEY (no)" || fail "not asked: $(cat "$FAKE/out")"
[ "$(setting core.env S3_REGION) $(setting core.env S3_BUCKET_LOOKUP)" = "us-east-1 dns" ] ||
  fail "answers: $(setting core.env S3_REGION) $(setting core.env S3_BUCKET_LOOKUP)"
setup s3-asked-enter
printf '5\ns3.example.edu\n\nfiles\n\n%s\n%s\n' "$AK" "$SK" > "$FAKE/answers"
ANSWERS=$FAKE/answers setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env S3_BUCKET_LOOKUP)" = auto ] || fail "Enter: S3_BUCKET_LOOKUP=$(setting core.env S3_BUCKET_LOOKUP)"

# Asked, with someone to answer: the menu, then what the choice needs, the
# secret not shown. Enter alone is this server's disk.
setup asked
printf '2\nap-east-1\naishie-files\n%s\n%s\n' "$AK" "$SK" > "$FAKE/answers"
ANSWERS=$FAKE/answers setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
said "Where should Core keep the files people upload?" || fail "not asked: $(cat "$FAKE/out")"
said "Secret access key (not shown): " || fail "the secret not asked for: $(cat "$FAKE/out")"
[ "$(setting core.env S3_BUCKET) $(setting core.env S3_REGION)" = "aishie-files ap-east-1" ] || fail "answers: $(setting core.env S3_BUCKET) $(setting core.env S3_REGION)"
[ "$(setting core.env S3_SECRET_KEY)" = "'$SK'" ] || fail "S3_SECRET_KEY is not the secret typed"
if grep -qF -- "$SK" "$FAKE/out"; then fail "the secret typed is in the output"; fi
setup asked-disk
echo > "$FAKE/answers"
ANSWERS=$FAKE/answers setup_server test.aishie.app edge || fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env BLOB_STORE)" = fs ] || fail "Enter alone: BLOB_STORE=$(setting core.env BLOB_STORE)"

# The keys refused: the run stops before it writes anything, and says why,
# without the service's whole answer, which names the key.
setup keys-refused
if S3_LIST=403 AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage aws --s3-region ap-east-1 --s3-bucket aishie-files test.aishie.app edge; then
  fail "passed with the keys refused"
fi
said "setup-server.sh: the keys were refused, or may not list the bucket's objects (SignatureDoesNotMatch" || fail "said: $(cat "$FAKE/out")"
if [ -e "$AISHIE_ETC/aishie.env" ] || [ -e "$AISHIE_ETC/core.env" ]; then fail "wrote settings"; fi
! said "$AK" || fail "printed the access key"
# ... or nothing given that the choice needs, and nobody to ask: nothing done.
setup missing
if AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage aws --s3-region ap-east-1 test.aishie.app edge; then fail "passed without a bucket"; fi
said "aws needs the bucket's name (--s3-bucket): nothing was changed" || fail "said: $(cat "$FAKE/out")"
if [ -s "$CALLS" ] || [ -e "$AISHIE_ETC" ]; then fail "did something"; fi
if setup_server --storage aws --s3-region ap-east-1 --s3-bucket aishie-files test.aishie.app edge; then fail "passed without keys"; fi
said "aws needs its access key (AISHIE_S3_ACCESS_KEY)" || fail "said: $(cat "$FAKE/out")"
if AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage s3 --s3-endpoint http://minio.example.edu --s3-bucket files test.aishie.app edge; then
  fail "took an http:// endpoint"
fi
said "refuse to send it to an http:// address" || fail "said: $(cat "$FAKE/out")"
if AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage aws --s3-region mars-north-1 --s3-bucket files test.aishie.app edge; then
  fail "took the region mars-north-1"
fi
said "not an AWS region's name" || fail "said: $(cat "$FAKE/out")"
if [ -s "$CALLS" ] || [ -e "$AISHIE_ETC" ]; then fail "did something for mars-north-1"; fi

# Keys that may not set the bucket's CORS rules: the rule, where to set it,
# and a step of what is left; the rest goes on.
setup cors-refused
S3_CORS_PUT=403 AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK setup_server --storage r2 --r2-account-id "$R2" --s3-bucket files test.aishie.app edge ||
  fail "exit $?: $(cat "$FAKE/out")"
said "these keys may not set one (HTTP 403)" || fail "said: $(cat "$FAKE/out")"
said '"AllowedOrigins": \["https://test.aishie.app"\]' || fail "no rule: $(cat "$FAKE/out")"
said "R2 Object Storage, files, Settings, CORS" || fail "no R2 dashboard steps: $(cat "$FAKE/out")"
said "Give the bucket the CORS rule above" || fail "not in what is left: $(cat "$FAKE/out")"
[ "$(setting core.env BLOB_STORE)" = s3 ] || fail "BLOB_STORE=$(setting core.env BLOB_STORE)"
grep -q "^CORE_REF=" "$AISHIE_STATE/images.env" || fail "stopped before the first update"

# Not root, or wrong arguments: nothing is done.
setup not-root
if NOT_ROOT=1000 setup_server test.aishie.app edge; then fail "ran as a user"; fi
said "run this as root" || fail "said: $(cat "$FAKE/out")"
[ ! -s "$CALLS" ] || fail "ran something: $(head -n 3 "$CALLS")"
for args in "" "test.aishie.app" "test.aishie.app dev" "bad_name edge" "a b c" "--storage aws" \
  "test.aishie.app edge --bogus x" "test.aishie.app edge --storage" "-x test.aishie.app edge"; do
  setup usage
  # shellcheck disable=SC2086 # the arguments, split
  if setup_server $args; then fail "took «$args»"; fi
  said "usage: setup-server.sh HOSTNAME edge|stable" || fail "said for «$args»: $(cat "$FAKE/out")"
  if [ -s "$CALLS" ] || [ -e "$AISHIE_ETC" ]; then fail "did something for «$args»"; fi
done

[ "$failed" = 0 ] && echo "setup-server.sh: ok"
exit "$failed"
