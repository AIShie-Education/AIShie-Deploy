#!/bin/sh
# Sets up an Ubuntu server (24.04 or later) to run the AIshiestack, or
# brings one set up before up to date. Run as root, with this repository
# copied to the server (README.md, A new server):
#
#   sh setup-server.sh test.aishie.app staging
#
# The name is the server's DNS name, where people and agents will reach it.
# Staging follows each image's :edge; production follows releases, set by
# hand in /etc/aishie/aishie.env.
#
# It asks where Core keeps the files people upload, when someone is there to
# answer: this server's disk, as before, or a bucket of Amazon S3,
# Cloudflare R2, Backblaze B2 or another S3-compatible service, which
# browsers then upload to and download from directly. Options say it for a
# run nobody answers, with the keys in AISHIE_S3_ACCESS_KEY and
# AISHIE_S3_SECRET_KEY (bin/aishie-storage says each; README.md, Where
# uploaded files are kept):
#
#   sh setup-server.sh test.aishie.app staging --storage aws --s3-region ap-east-1 --s3-bucket aishie-files
#
# Without them, and with nobody to ask, it is the disk. A bucket is checked
# with the keys before anything is written, by reading alone, and given the
# CORS rule the site's uploads need when the keys may set it; else the rule
# is printed, with where to set it.
#
# It installs Docker Engine and its compose plugin where they are missing:
# Ubuntu's own packages (docker.io and docker-compose-v2) when those give
# compose 2.24 or later, as 24.04's do, and Docker's apt repository
# otherwise. It writes /etc/aishie: the settings, and the env files with
# generated database passwords and SIGNING_KEY. It makes the directories for
# the runtime's agents and secrets, with the key that will wrap the secrets
# the runtime stores (kek/v1), Core's files, aishie-update's state and the
# backups. It installs the stack in /opt/aishie, aishie-update, aishie and
# aishie-storage in /usr/local/bin, and the timers; opens 80 and 443 in ufw
# when ufw is on; checks that the server can pull the three images; starts
# PostgreSQL and Caddy; runs the first update; and says what is left to do.
#
# Run again, it installs this copy's files over the old ones, and leaves the
# rest as it is: the settings, the secrets and the data, and where Core
# keeps its files (`aishie storage migrate` moves them). That is how a newer
# aishie-update, or a change to the stack, reaches the server.
#
# tests/setup-server_test.sh sources it with AISHIE_SETUP_LIB=1, which
# defines the functions and runs nothing, and moves the paths below;
# tests/e2e.sh runs it whole. AISHIE_REGISTRY is for a registry of their own,
# as it is for aishie-update.
set -eu
# The settings and the secrets are root's alone.
umask 077

ETC=${AISHIE_ETC:-/etc/aishie}
STATE=${AISHIE_STATE:-/var/lib/aishie}
APP=${AISHIE_APP:-/opt/aishie}
DATA=${AISHIE_DATA:-/srv/aishie}
BACKUPS=${AISHIE_BACKUPS:-/var/backups/aishie}
BIN=${AISHIE_BIN:-/usr/local/bin}
UNITS=${AISHIE_UNITS:-/etc/systemd/system}
LOCK_FILE=${AISHIE_LOCK_FILE:-/run/aishie-update.lock}
REGISTRY=${AISHIE_REGISTRY:-ghcr.io/aishie-education}
# The images' nonroot user (distroless), which Core and the runtime run as.
APP_UID=65532
# compose 2.24 or later: `include` with env_file, and what aishie-update asks
# of `up`, `run` and `config`.
COMPOSE_MIN=2.24

# compose.yaml reads these from aishie.env and images.env, and the same
# names in this process's environment would win over both files, as they
# would for aishie-update, which clears them too.
unset HOST ENVIRONMENT CORE_IMAGE RUNTIME_IMAGE WEB_IMAGE CORE_REF RUNTIME_REF WEB_REF \
  AISHIE_SUBNET AISHIE_CADDY_IP RUNTIME_STOP_GRACE FRAME_ANCESTORS

say() { printf '\n== %s\n' "$*"; }
die() { echo "setup-server.sh: $*" >&2; exit 1; }
systemd() { [ -d /run/systemd/system ]; }
# own OWNER PATH...: chown, apart so that the tests, which are not root, can
# leave it out.
own() { chown "$@"; }
# secret BYTES: that many random bytes, in hex. Hex needs no escaping in SQL,
# in a URL or in an env file.
secret() { openssl rand -hex "$1"; }

# Where Core keeps uploaded files, the bucket options and the bucket's
# check and CORS rule: bin/aishie-storage's functions (st_*), which `aishie
# storage` runs later.
storage_lib=$(dirname "$0")/bin/aishie-storage
[ -f "$storage_lib" ] || die "run the setup-server.sh of a whole copy of the repository: $storage_lib is missing"
ST_NAME=setup-server.sh
AISHIE_STORAGE_LIB=1
# shellcheck source=bin/aishie-storage
. "$storage_lib"
unset AISHIE_STORAGE_LIB

usage() {
  cat >&2 <<'EOF'
usage: setup-server.sh HOSTNAME staging|production [--storage fs|aws|r2|b2|s3 OPTIONS], e.g. test.aishie.app staging
Where Core keeps uploaded files, on a new server (the keys in AISHIE_S3_ACCESS_KEY
and AISHIE_S3_SECRET_KEY, or asked for):
EOF
  sed -n 's/^#   \(--storage .*\)/  \1/p' "$storage_lib" >&2
  exit 2
}
# check_args HOST ENVIRONMENT
check_args() {
  case $1 in '' | *[!A-Za-z0-9.-]* | .* | -* | *..*) usage ;; esac
  case $2 in staging | production) ;; *) usage ;; esac
}

# version_at_least VERSION MIN: whether VERSION (2.24.6, v2.27.0, 5.1.1,
# 2.24.6+ds1-0ubuntu1) is MIN (major.minor) or later.
version_at_least() {
  awk -v v="$1" -v min="$2" 'BEGIN {
    sub(/^v/, "", v)
    if (v !~ /^[0-9]+\.[0-9]+/) exit 1
    split(v, a, /[^0-9]/); split(min, b, /\./)
    exit !((a[1] + 0 > b[1] + 0) || (a[1] + 0 == b[1] + 0 && a[2] + 0 >= b[2] + 0))
  }'
}
compose_ok() {
  v=$(docker compose version --short 2>/dev/null) || return 1
  version_at_least "$v" "$COMPOSE_MIN"
}
# candidate: the version apt would install, from `apt-cache policy PACKAGE`
# on standard input; nothing when there is none.
candidate() { awk '$1 == "Candidate:" && $2 != "(none)" { print $2; exit }'; }

# docker_source: where Docker comes from on this server. "ubuntu VERSION"
# when Ubuntu's own docker-compose-v2 is compose 2.24 or later (24.04's is),
# "docker" otherwise: Docker's apt repository. Also "docker" when Docker's
# own docker-ce is installed already, which Ubuntu's docker.io conflicts with.
docker_source() {
  if dpkg-query -W -f '${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
    echo docker
    return 0
  fi
  v=$(apt-cache policy docker-compose-v2 2>/dev/null | candidate)
  if [ -n "$v" ] && version_at_least "$v" "$COMPOSE_MIN"; then
    echo "ubuntu $v"
  else
    echo docker
  fi
}

# Docker Engine and compose, where they are missing or too old.
install_docker() {
  if command -v docker >/dev/null 2>&1 && compose_ok; then
    if systemd; then systemctl enable --now docker; fi
    echo "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null || echo '(not running)') and compose $(docker compose version --short) are installed: left as they are"
    return 0
  fi
  from=$(docker_source)
  if [ "$from" != docker ]; then
    v=${from#ubuntu }
    echo "installing Docker from Ubuntu's packages: docker.io, and docker-compose-v2 $v"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -q docker.io docker-compose-v2
  else
    echo "Ubuntu's packages give no compose $COMPOSE_MIN or later: installing Docker Engine and its compose plugin from Docker's apt repository"
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod 644 /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091 # the system's
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" "$codename" > /etc/apt/sources.list.d/docker.list
    chmod 644 /etc/apt/sources.list.d/docker.list
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -q \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if systemd; then systemctl enable --now docker; fi
  compose_ok || die "docker compose $COMPOSE_MIN or later is still missing ($(docker compose version --short 2>&1)): install it, then run this again"
}

packages() {
  # A server that has just booted is often still updating itself, and
  # apt-get, unlike apt, does not wait for the lock.
  if command -v cloud-init >/dev/null 2>&1; then timeout 900 cloud-init status --wait >/dev/null 2>&1 || true; fi
  i=0
  until apt-get update -q; do
    i=$((i + 1))
    [ "$i" -lt 20 ] || die "apt-get update kept failing: run this again in a while"
    echo "apt is busy, most likely the server updating itself: trying again in 30 seconds"
    sleep 30
  done
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -q ca-certificates curl openssl
  install_docker
}

# write_settings HOST ENVIRONMENT: aishie.env, unless it is there.
write_settings() {
  f=$ETC/aishie.env
  install -d -m 700 "$ETC"
  if [ -e "$f" ]; then
    had=$(sed -n 's/^HOST=//p' "$f" | tail -n 1)
    echo "$f is there already: left as it is (HOST=$had)"
    [ "$had" = "$1" ] || echo "warning: $f says HOST=$had, not $1: edit it if $1 is meant (README.md, Changing the host name)" >&2
    return 0
  fi
  if [ "$2" = staging ]; then
    channel=edge
  else
    channel=
  fi
  cat > "$f.new" <<EOF
# The operator's settings of this server's AIshiestack; every one is
# explained in /opt/aishie/env/aishie.env.example. setup-server.sh wrote it
# once and leaves it alone: edit it by hand. One NAME=value per line, no
# quotes, no comment after a value.
HOST=$1
ENVIRONMENT=$2
EOF
  if [ "$2" = production ]; then
    cat >> "$f.new" <<'EOF'
# Production follows releases: set each to one, e.g.
# ghcr.io/aishie-education/aishie-core:1.2.3, then run aishie-update.
EOF
  fi
  cat >> "$f.new" <<EOF
CORE_IMAGE=${channel:+$REGISTRY/aishie-core:$channel}
RUNTIME_IMAGE=${channel:+$REGISTRY/aishie-agent-runtime:$channel}
WEB_IMAGE=${channel:+$REGISTRY/aishie-frontend:$channel}
AISHIE_SUBNET=172.30.83.0/24
AISHIE_CADDY_IP=172.30.83.10
RUNTIME_STOP_GRACE=30s
# Optional, and unset: FRAME_ANCESTORS, the other sites that may show AIshie
# in a frame (only its own pages may while it is unset). The example file
# says how to write it.
EOF
  chmod 600 "$f.new"
  mv "$f.new" "$f"
  echo "wrote $f"
}

# write_secrets: postgres.env, core.env and runtime.env, together, with
# generated passwords and SIGNING_KEY, unless they are there. They hold the
# same passwords, so one is never written without the others. The secrets go
# from openssl into this shell and from here into the files: they are on no
# command line, and nothing prints them.
write_secrets() {
  n=0
  for f in postgres core runtime; do [ ! -e "$ETC/$f.env" ] || n=$((n + 1)); done
  if [ "$n" = 3 ]; then
    echo "$ETC/postgres.env, core.env and runtime.env are there already: left as they are"
    return 0
  fi
  if [ "$n" != 0 ]; then
    cat >&2 <<MSG
Some of $ETC/postgres.env, core.env and runtime.env are there, but not all:
an earlier run stopped half way, or one was removed. They hold the same
database passwords, so this script writes them only together. Put back the
one that is missing from a copy of $ETC (README.md, What to keep off the
server), or, if the server holds no data yet, remove the others and the
database's volume (docker volume rm aishie_postgres), and run this again.
MSG
    exit 1
  fi
  core_pw=$(secret 24)
  runtime_pw=$(secret 24)
  cat > "$ETC/postgres.env.new" <<EOF
# PostgreSQL's passwords: see /opt/aishie/env/postgres.env.example. They are
# read when the database's volume is first made; changing one here changes
# nothing in the database (README.md, Rotating secrets).
POSTGRES_PASSWORD=$(secret 24)
AISHIE_CORE_DB_PASSWORD=$core_pw
AISHIE_RUNTIME_DB_PASSWORD=$runtime_pw
EOF
  cat > "$ETC/core.env.new" <<EOF
# AIshieCore's settings: every one is explained in
# /opt/aishie/env/core.env.example. One NAME=value per line, no quotes, no
# comment after a value. After a change: aishie compose up -d core
DATABASE_URL=postgres://aishie_core:$core_pw@postgres:5432/aishie_core?sslmode=disable
# It must never change: keep a copy off the server.
SIGNING_KEY=$(secret 32)
EOF
  st_env_block "$(storage_store)" >> "$ETC/core.env.new"
  cat > "$ETC/runtime.env.new" <<EOF
# The AIshieAgent Runtime's settings: every one is explained in
# /opt/aishie/env/runtime.env.example. One NAME=value per line, no quotes,
# no comment after a value. After a change: aishie compose up -d runtime
DATABASE_URL=postgres://aishie_runtime:$runtime_pw@postgres:5432/aishie_runtime?sslmode=disable
LOG_FORMAT=json
KMS_KEY_ID=local:/secrets/kek/v1
EOF
  unset core_pw runtime_pw
  for f in postgres core runtime; do
    chmod 600 "$ETC/$f.env.new"
    mv "$ETC/$f.env.new" "$ETC/$f.env"
  done
  echo "wrote $ETC/postgres.env, core.env and runtime.env, with generated passwords and SIGNING_KEY"
  if [ "$(storage_store)" = s3 ]; then
    echo "Core keeps the files people upload in $(st_describe), with the keys given, which core.env holds"
  else
    echo "Core keeps the files people upload on this server's disk, in $DATA/core/blobs"
  fi
}

# choose_storage: where a new server's Core keeps the files people upload:
# the options, else their variables, else asked when someone is there to
# answer, else this server's disk. Asked before the long part of the run,
# and checked once curl is installed. A server with a core.env keeps what it
# says: said, when the options name another place, with how to move them.
choose_storage() {
  st_from_env
  if [ -e "$ETC/core.env" ]; then
    storage_new=
    had=$(st_setting "$ETC/core.env" BLOB_STORE)
    had=${had:-fs}
    if [ -n "$ST_GIVEN" ] && [ "$(storage_store)" != "$had" ]; then
      echo "warning: $ETC/core.env keeps uploaded files with BLOB_STORE=$had, and is left as it is: to move them, aishie storage migrate --to $(storage_store) (README.md, Where uploaded files are kept)" >&2
    fi
    return 0
  fi
  storage_new=1
  if [ -z "$ST_KIND" ] && st_interactive; then st_choose; fi
  st_gather
  st_resolve
}
# storage_store: BLOB_STORE for the choice, fs or s3.
storage_store() { if [ "${ST_KIND:-fs}" = fs ]; then echo fs; else echo s3; fi; }

# make_dirs: the directories, each with its owner. The runtime (user 65532)
# reads the agents and the secrets through their group; root writes them.
make_dirs() {
  install -d -m 700 "$ETC" "$ETC/runtime" "$STATE" "$BACKUPS"
  for d in "$ETC/runtime/agents" "$ETC/runtime/secrets" "$ETC/runtime/secrets/kek"; do
    if [ -d "$d" ]; then
      echo "$d is there already: left as it is"
    else
      install -d -m 750 "$d"
      own "root:$APP_UID" "$d"
      echo "made $d"
    fi
  done
  # compose.yaml reads it; aishie-update fills it in.
  [ -e "$STATE/images.env" ] || echo "# Nothing deployed yet: aishie-update writes this file." > "$STATE/images.env"
  install -d -m 755 "$DATA"
  if [ ! -d "$DATA/core" ]; then
    install -d -m 750 "$DATA/core"
    own "$APP_UID:$APP_UID" "$DATA/core"
    echo "made $DATA/core, for the files people upload to Core"
  fi
}

# make_kek: kek/v1, 32 random bytes in base64, which the runtime's API (M2)
# will wrap the secrets it stores with, unless it is there. It must not be
# lost, nor changed: README.md, Rotating secrets.
make_kek() {
  f=$ETC/runtime/secrets/kek/v1
  if [ -e "$f" ]; then
    echo "$f is there already: left as it is"
    return 0
  fi
  openssl rand -base64 32 > "$f.new"
  chmod 640 "$f.new"
  own "root:$APP_UID" "$f.new"
  mv "$f.new" "$f"
  echo "made $f, the key that will wrap the runtime's stored secrets: keep a copy off the server"
}

# install_files HERE: this copy's stack, scripts and units, over the old ones.
install_files() {
  here=$1
  umask 022
  install -d -m 755 "$APP" "$APP/caddy" "$APP/postgres" "$APP/postgres/initdb" "$APP/env" "$APP/docs"
  install -m 644 "$here/compose.yaml" "$here/stack.yaml" "$here/README.md" "$APP/"
  install -m 644 "$here/caddy/Caddyfile" "$APP/caddy/"
  install -m 755 "$here/postgres/initdb/10-aishie.sh" "$APP/postgres/initdb/"
  install -m 644 "$here"/env/*.env.example "$APP/env/"
  install -m 644 "$here"/docs/*.md "$APP/docs/"
  install -d -m 755 "$BIN"
  install -m 755 "$here/bin/aishie-update" "$here/bin/aishie" "$here/bin/aishie-storage" "$BIN/"
  install -d -m 755 "$UNITS"
  install -m 644 "$here"/systemd/aishie-update.service "$here"/systemd/aishie-update.timer \
    "$here"/systemd/aishie-backup.service "$here"/systemd/aishie-backup.timer "$UNITS/"
  umask 077
  echo "installed the stack in $APP, aishie-update, aishie and aishie-storage in $BIN, and the units in $UNITS"
}

# compose: the stack's, as aishie-update runs it.
compose() { docker compose --project-directory "$APP" -f "$APP/compose.yaml" "$@"; }

# pull_check: whether this server can pull each channel's image. Prints the
# ones it cannot.
pull_check() {
  bad=
  for v in CORE_IMAGE RUNTIME_IMAGE WEB_IMAGE; do
    img=$(sed -n "s/^$v=//p" "$ETC/aishie.env" | tail -n 1)
    [ -n "$img" ] || continue
    if docker pull -q "$img" >/dev/null 2>"$STATE/pull.err"; then
      echo "can pull $img"
    else
      echo "cannot pull $img: $(tail -n 1 "$STATE/pull.err")"
      bad=1
    fi
  done
  rm -f "$STATE/pull.err"
  [ -z "$bad" ]
}

login_help() {
  cat <<EOF
   The images are private packages of the AIShie-Education organization on
   GitHub's registry, ghcr.io, and this server is not logged in there with
   an account that can read all three. GHCR takes a personal access token
   (classic), not a fine-grained one. Make one with the scope read:packages
   and nothing else, on an account that can read the three packages and
   nothing more, with a long expiry whose date you put in a calendar (once
   it expires, updates stop: docs/troubleshooting.md, GHCR login expired).
   Then, as root, paste the token when asked, then Enter and Ctrl-D:

     docker login ghcr.io -u <that account's GitHub user name> --password-stdin

   Docker keeps it in /root/.docker/config.json. Then: aishie-update
EOF
}

main() {
  # HOSTNAME and ENVIRONMENT, and the storage options, before, between or
  # after them, as --name value or --name=value.
  name='' environment='' n=0
  while [ $# -gt 0 ]; do
    case $1 in
      --*=*) st_option "${1%%=*}" "${1#*=}" || usage ;;
      --*)
        [ $# -ge 2 ] || usage
        st_option "$1" "$2" || usage
        shift
        ;;
      -*) usage ;;
      *)
        n=$((n + 1))
        case $n in
          1) name=$1 ;;
          2) environment=$1 ;;
          *) usage ;;
        esac
        ;;
    esac
    shift
  done
  [ "$n" -eq 2 ] || usage
  check_args "$name" "$environment"
  [ "$(id -u)" = 0 ] || die "run this as root (sudo -i)"
  here=$(cd "$(dirname "$0")" && pwd)
  if [ ! -f "$here/stack.yaml" ] || [ ! -f "$here/bin/aishie-update" ]; then
    die "run the setup-server.sh of a whole copy of the repository: $here has no stack.yaml or bin/aishie-update"
  fi
  choose_storage

  say "Packages"
  packages

  if [ -n "$storage_new" ] && [ "$(storage_store)" = s3 ]; then
    say "The bucket"
    # Before anything is written: refused keys stop the run here, and the
    # next run asks again.
    st_check
  fi

  say "Settings and secrets in $ETC"
  write_settings "$name" "$environment"
  if [ ! -e "$ETC/postgres.env" ] && docker volume inspect aishie_postgres >/dev/null 2>&1; then
    cat >&2 <<MSG
The database's volume aishie_postgres is there, but $ETC/postgres.env is
not: its roles have passwords this script cannot know. Put $ETC back from
a copy (README.md, What to keep off the server), or, if the server holds no
data, remove the volume (docker volume rm aishie_postgres) and run this
again.
MSG
    exit 1
  fi
  write_secrets
  make_dirs
  make_kek
  cors_left=
  if [ -n "$storage_new" ] && [ "$(storage_store)" = s3 ]; then
    say "The bucket's CORS rule"
    host=$(sed -n 's/^HOST=//p' "$ETC/aishie.env" | tail -n 1)
    st_cors "$host" apply || cors_left=1
  fi

  say "The stack, the scripts and the timers"
  install_files "$here"
  # The newest PostgreSQL 18 and Caddy 2. Caddy takes its own when it is
  # started below; PostgreSQL's waits for a person (README.md, PostgreSQL's
  # major version). Docker Hub may refuse for a while (it limits pulls): the
  # images this server has do until then, and one it lacks is pulled when it
  # is first needed, or the step that needs it says why not.
  compose pull -q postgres caddy ||
    echo "could not pull the newest postgres:18 and caddy:2 (above): going on with the ones this server has"
  # Caddy checks its configuration here before it is the one Caddy runs.
  host=$(sed -n 's/^HOST=//p' "$ETC/aishie.env" | tail -n 1)
  docker run --rm --network none -e "HOST=$host" -v "$APP/caddy:/etc/caddy:ro" caddy:2 \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>"$STATE/caddy.err" ||
    { cat "$STATE/caddy.err" >&2; die "caddy validate refused $APP/caddy/Caddyfile (above)"; }
  rm -f "$STATE/caddy.err"
  if systemd; then
    systemctl daemon-reload
    systemctl enable --now aishie-update.timer aishie-backup.timer
    echo "aishie-update.timer and aishie-backup.timer are on"
  fi

  say "Firewall"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    # One by one, so that set -e stops at one that fails.
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 443/udp >/dev/null
    echo "ufw: 80/tcp, 443/tcp and 443/udp (HTTP/3) allowed"
  else
    echo "ufw is off; a firewall of your provider's must allow 80/tcp, 443/tcp and 443/udp"
  fi
  echo "Docker publishes Caddy's 80 and 443 whatever ufw says; nothing else is published beyond 127.0.0.1"

  say "PostgreSQL and Caddy"
  # PostgreSQL is never recreated here: a change to it is for a person to
  # make (README.md, PostgreSQL's major version). Caddy takes this copy's
  # Caddyfile.
  compose up -d --no-recreate --wait --wait-timeout 180 postgres
  compose up -d --no-deps caddy
  compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true

  say "The images"
  login=
  pull_check || login=1
  failed=
  if [ "$environment" = production ] && ! grep -q '^CORE_IMAGE=.' "$ETC/aishie.env"; then
    echo "not updating: production's channels are not set yet (below)"
  else
    # Core, the runtime and the web, in that order, each by the safe
    # sequence. A run stops at the first service it cannot deploy (an image
    # it cannot pull, say), and the next one, by the timer, goes on from
    # there once the cause is gone.
    say "The first update (aishie-update)"
    "$BIN/aishie-update" || { failed=1; echo "aishie-update stopped (above): docs/troubleshooting.md" >&2; }
    # A change to stack.yaml reaches a service when it is recreated: now,
    # with the image it runs, for any whose configuration changed. Under
    # aishie-update's lock, so as not to cross a run of the timer's.
    (
      exec 9>"$LOCK_FILE"
      flock -w 600 9 || die "aishie-update has held its lock for ten minutes: run this again later"
      for s in core runtime web; do
        if grep -q "^$(echo "$s" | tr '[:lower:]' '[:upper:]')_REF=" "$STATE/images.env" 2>/dev/null; then
          compose up -d --no-deps "$s"
        fi
      done
    ) || failed=1
  fi

  say "Done. What is left"
  n=1
  if [ -n "$login" ]; then
    echo "$n. Let this server pull the images it could not (above; a package that is not"
    echo "   published yet answers the same):"
    login_help
    n=$((n + 1))
  fi
  if [ -n "$cors_left" ]; then
    cat <<EOF
$n. Give the bucket the CORS rule above: until it has it, uploads from the site
   fail in the browser. aishie storage cors says whether it has it.
EOF
    n=$((n + 1))
  fi
  if [ "$environment" = production ] && ! grep -q '^CORE_IMAGE=.' "$ETC/aishie.env"; then
    cat <<EOF
$n. Set the releases production runs, CORE_IMAGE, RUNTIME_IMAGE and WEB_IMAGE, in
   $ETC/aishie.env (e.g. $REGISTRY/aishie-core:1.2.3), then: aishie-update
EOF
    n=$((n + 1))
  fi
  cat <<EOF
$n. Point $host at this server in DNS (A, and AAAA if it has IPv6). Caddy gets
   its certificate once the name resolves here:
     curl https://$host/healthz
EOF
  n=$((n + 1))
  cat <<EOF
$n. The first administrator, once Core runs (aishie-update --status): it asks
   for a name, an email and a password, then restarts Core, and the
   administrator signs in at https://$host with that email and password:
     aishie admin
EOF
  n=$((n + 1))
  cat <<EOF
$n. Agents (README.md, Adding an agent): each one's YAML in
   $ETC/runtime/agents, and each secret it refers to as a file in
   $ETC/runtime/secrets, readable by group $APP_UID:
     install -g $APP_UID -m 640 tutor.yaml $ETC/runtime/agents/
     install -D -g $APP_UID -m 640 /dev/stdin $ETC/runtime/secrets/agents/tutor/core_token    (paste, Enter, Ctrl-D)
     aishie runtime check --live && aishie compose kill -s HUP runtime
EOF
  n=$((n + 1))
  cat <<EOF
$n. Keep a copy of $ETC somewhere else, encrypted, and apart from the
   database's backups: it holds SIGNING_KEY and the runtime's key (kek/v1),
   which no backup of the database can bring back (README.md, What to keep off
   the server).

Updates come by themselves from now on: aishie-update --status says what runs
and how the last check went; journalctl -u aishie-update has every run.
EOF
  if [ -n "$failed" ]; then exit 1; fi
}

if [ -z "${AISHIE_SETUP_LIB:-}" ]; then main "$@"; fi
