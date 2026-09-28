# shellcheck shell=bash
# Stand-ins for the programs aishie-update and aishie call, for the tests:
# docker (and docker compose), curl, flock, sleep and logger. Each records
# its command line in $CALLS, and keeps what it plays in $FAKE:
#
#   registry/tags          "REF HEX" lines: the image a tag names now, by
#                          its digest's hex; the last line for a tag wins
#   registry/img/HEX/      an image: version (what `version` prints), labels
#                          ("name=value" lines), unhealthy (a marker: its
#                          health check never passes)
#   local                  "REF HEX" lines: what this Docker has pulled
#   running/SERVICE        the image each service's container runs
#   oneoff/ID/             a one-off container: its exit code and output
#   journal                what logger was given
#
# Knobs, in the environment: PULL_FAIL, MIGRATE_FAIL, SEED_FAIL, CHECK_FAIL,
# BACKUP_FAIL, POSTGRES_FAIL and FLOCK_FAIL make that step fail.

# make_fakes DIR: the stand-ins, in DIR, to put first on PATH.
make_fakes() {
  mkdir -p "$1"
  cat > "$1/docker" <<'EOF'
#!/usr/bin/env bash
set -u
reg=$FAKE/registry
prefix=
for v in CORE_REF RUNTIME_REF WEB_REF; do [ -z "${!v:-}" ] || prefix+="$v=${!v} "; done
echo "${prefix}docker $*" >> "$CALLS"
mkdir -p "$FAKE/running" "$FAKE/oneoff"
touch "$FAKE/local" "$reg/tags"

# hex_of REF: the digest's hex REF names in the registry now.
hex_of() {
  case $1 in
    *@sha256:*) [ -d "$reg/img/${1##*@sha256:}" ] && echo "${1##*@sha256:}" ;;
    *) awk -v r="$1" '$1 == r { h = $2 } END { if (h == "") exit 1; print h }' "$reg/tags" ;;
  esac
}
# local_hex REF: the same, in what this Docker has.
local_hex() { awk -v r="$1" '$1 == r { h = $2 } END { if (h == "") exit 1; print h }' "$FAKE/local"; }
repo_of() { r=${1%%@*}; case ${r##*/} in *:*) r=${r%:*} ;; esac; echo "$r"; }
# service_image SERVICE: what compose would run for it: the variable, when
# set, else images.env.
service_image() {
  v=${1^^}_REF
  if [ -n "${!v:-}" ]; then echo "${!v}"; else sed -n "s/^$v=//p" "$AISHIE_STATE/images.env" 2>/dev/null | tail -n 1; fi
}

compose() {
  while [ $# -gt 0 ]; do
    case $1 in --project-directory | -f) shift 2 ;; *) break ;; esac
  done
  case "$*" in
    "up -d --no-recreate --wait"*) exit "${POSTGRES_FAIL:-0}" ;;
    "up -d --no-deps "*) service_image "$4" > "$FAKE/running/$4" ;;
    "rm -s -f "*) rm -f "$FAKE/running/$4" ;;
    "run -d --no-deps "*)
      svc=$4
      shift 4
      id=oneoff-$svc-$(date +%s%N)
      mkdir -p "$FAKE/oneoff/$id"
      code=0
      case "$*" in
        "migrate up") code=${MIGRATE_FAIL:-0} ;;
        seed) code=${SEED_FAIL:-0} ;;
        check) code=${CHECK_FAIL:-0} ;;
      esac
      echo "$code" > "$FAKE/oneoff/$id/code"
      echo "$svc $* with $(service_image "$svc"): exit $code" > "$FAKE/oneoff/$id/out"
      echo "$id" ;;
    "run --rm --no-deps -T "*)
      svc=$5
      shift 5
      cat > "$FAKE/stdin"
      echo "$svc $* with $(service_image "$svc")" ;;
    "exec -T postgres pg_dump"*)
      echo "PGDMP a dump of ${*: -1}"
      exit "${BACKUP_FAIL:-0}" ;;
    "logs"*) echo "a log line" ;;
    "ps -q "*) [ -e "$FAKE/running/$3" ] && echo "container-of-$3" ;;
    "ps"*) ls "$FAKE/running" ;;
  esac
  exit 0
}

case $1 in
  compose) shift; compose "$@" ;;
  pull)
    ref=${*: -1}
    if [ "${PULL_FAIL:-0}" != 0 ]; then echo "Error response from daemon: denied: denied" >&2; exit 1; fi
    h=$(hex_of "$ref") || { echo "Error response from daemon: manifest unknown" >&2; exit 1; }
    printf '%s %s\n%s@sha256:%s %s\n' "$ref" "$h" "$(repo_of "$ref")" "$h" "$h" >> "$FAKE/local"
    echo "$ref" ;;
  image)
    case $2 in
      inspect)
        ref=${*: -1} fmt=$4
        h=$(local_hex "$ref") || { echo "Error: No such image: $ref" >&2; exit 1; }
        case $fmt in
          *RepoDigests*) echo "$(repo_of "$ref")@sha256:$h" ;;
          *Labels*)
            name=$(printf '%s\n' "$fmt" | sed 's/.*"\(.*\)".*/\1/')
            v=$(sed -n "s|^$name=||p" "$reg/img/$h/labels")
            echo "${v:-<no value>}" ;;
        esac ;;
      prune) : ;;
    esac ;;
  run)
    # aishie runtime-status: a wget in the runtime's network namespace.
    case "$*" in *"--entrypoint wget"*) echo '{"worker":"w","agents":[]}'; exit 0 ;; esac
    # aishie-update: docker run --rm --network none IMAGE version
    ref=${*: -2:1}
    h=$(local_hex "$ref") || exit 125
    cat "$reg/img/$h/version" ;;
  wait) cat "$FAKE/oneoff/$2/code" ;;
  logs) cat "$FAKE/oneoff/$2/out" ;;
  rm) rm -rf "$FAKE/oneoff/${*: -1}" ;;
esac
exit 0
EOF
  cat > "$1/curl" <<'EOF'
#!/usr/bin/env bash
# The health checks, as the image each service runs would answer them.
set -u
echo "curl $*" >> "$CALLS"
url=${*: -1}
case $url in
  *:8080/*) svc=core ;;
  *:9090/*) svc=runtime ;;
  *:8081/*) svc=web ;;
  *) exit 7 ;;
esac
img=$(cat "$FAKE/running/$svc" 2>/dev/null) || exit 7
h=${img##*@sha256:}
dir=$FAKE/registry/img/$h
[ ! -e "$dir/unhealthy" ] || exit 22
label() { sed -n "s|^$1=||p" "$dir/labels"; }
rev=$(label org.opencontainers.image.revision)
case $svc in
  web) printf '{"version":"%s","commit":"%s"}\n' "$(label org.opencontainers.image.version)" "${rev:0:7}" ;;
  *) printf '{"status":"ok","version":"%s","commit":"%s","schema_version":4}\n' "$(label org.opencontainers.image.version)" "${rev:0:7}" ;;
esac
EOF
  cat > "$1/flock" <<'EOF'
#!/bin/sh
echo "flock $*" >> "$CALLS"
exit "${FLOCK_FAIL:-0}"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$1/sleep"
  cat > "$1/logger" <<'EOF'
#!/bin/sh
echo "logger $*" >> "$FAKE/journal"
EOF
  chmod +x "$1"/*
}

# image SERVICE HEX VERSION COMMIT [SOURCE]: an image of SERVICE's repository
# in the registry, labelled as its publish workflow labels it (with SOURCE
# for its source, when given).
image() {
  local dir=$FAKE/registry/img/$2 src
  mkdir -p "$dir"
  case $1 in
    core) src=https://github.com/AIShie-Education/AIShie-Core; echo "$3 ($4, 2026-09-25T04:10:07Z)" > "$dir/version" ;;
    runtime) src=https://github.com/AIShie-Education/AIShie-Agent-Runtime; echo "aishie-runtime $3 ($4, 2026-09-25T04:10:07Z)" > "$dir/version" ;;
    web) src=https://github.com/AIShie-Education/AIShie-Frontend; : > "$dir/version" ;;
  esac
  printf 'org.opencontainers.image.source=%s\norg.opencontainers.image.revision=%s\norg.opencontainers.image.version=%s\n' \
    "${5:-$src}" "$4$(printf '0%.0s' $(seq 33))" "$3" > "$dir/labels"
}
# tag REF HEX: REF names that image in the registry from now on.
tag() { mkdir -p "$FAKE/registry"; echo "$1 $2" >> "$FAKE/registry/tags"; }
unhealthy() { touch "$FAKE/registry/img/$1/unhealthy"; }
healthy_again() { rm -f "$FAKE/registry/img/$1/unhealthy"; }
logger_lines() { if [ -f "$FAKE/journal" ]; then wc -l < "$FAKE/journal" | tr -d ' '; else echo 0; fi; }
