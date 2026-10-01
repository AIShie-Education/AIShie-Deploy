# shellcheck shell=bash
# Stand-ins for the programs aishie-update, aishie and aishie-storage call,
# for the tests: docker (and docker compose, and rclone's container), curl
# (and an S3 service), flock, sleep and logger. Each records its command
# line in $CALLS, and keeps what it plays in $FAKE:
#
#   registry/tags          "REF HEX" lines: the image a tag names now, by
#                          its digest's hex; the last line for a tag wins
#   registry/img/HEX/      an image: version (what `version` prints), labels
#                          ("name=value" lines), unhealthy (a marker: its
#                          health check never passes)
#   local                  "REF HEX" lines: what this Docker has pulled
#   running/SERVICE        the image each service's container runs
#   oneoff/ID/             a one-off container: its exit code and output
#   issued                 each credential Core's `service issue` printed,
#                          one per line
#   journal                what logger was given
#
#   compose-version        what `docker compose version --short` says
#                          (else COMPOSE_VERSION, else 2.27.0)
#   volumes/NAME           a volume Docker has
#   on-stop                run by `docker compose stop` (a test's hook: an
#                          upload while Core stops, say)
#
#   bucket/KEY             the S3 bucket's objects, which rclone's container
#                          lists, copies and checks (tests/rclone-fake)
#   bucket-types/KEY       the content type each object was given
#   s3-keys                the curl configuration curl read on its standard
#                          input, with the keys it signed with
#   s3-requests            "METHOD URL" of each request to the bucket
#   s3-cors                the bucket's CORS rules, as PUT
#
# Knobs, in the environment: PULL_FAIL, MIGRATE_FAIL, SEED_FAIL, CHECK_FAIL,
# BACKUP_FAIL, POSTGRES_FAIL, CADDY_FAIL, COMPOSE_PULL_FAIL and FLOCK_FAIL make
# that step fail. The S3 service answers a listing with S3_LIST (200, or
# 301, 400, 403, 404), a HEAD with S3_HEAD (404), GET ?cors= with S3_CORS_GET
# (the rules PUT, else 404; "other" for rules of another site's; or a
# status) and PUT ?cors= with S3_CORS_PUT (200); S3_DOWN has it not answer.
# RCLONE_PULL_FAIL fails the pull of rclone's image, RCLONE_FAIL every rclone,
# RCLONE_CORRUPT=KEY has a copy of KEY arrive with other bytes of the same
# size, and RCLONE_ATTACH is below. BOOTSTRAP_TOKEN has a one-off bootstrap print it as a Core
# from before people held no API tokens prints root's: under a heading on
# standard error, the token alone on standard output. A one-off `service
# issue` prints a new aissvc_ credential as Core does, or SERVICE_TOKEN;
# ISSUE_FAIL fails it, as a Core from before the agent_runtime service does.

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
    "version --short") cat "$FAKE/compose-version" 2>/dev/null || echo "${COMPOSE_VERSION:-2.27.0}" ;;
    "pull -q "*) exit "${COMPOSE_PULL_FAIL:-0}" ;;
    "up -d --no-recreate --wait"*) exit "${POSTGRES_FAIL:-0}" ;;
    "up -d --no-deps "*) s=${*: -1}; service_image "$s" > "$FAKE/running/$s"; rm -f "$FAKE/stopped-$s" ;;
    "stop "*)
      touch "$FAKE/stopped-$2"
      if [ -x "$FAKE/on-stop" ]; then "$FAKE/on-stop"; fi ;;
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
      if [ "$svc ${1:-} ${2:-}" = "core service issue" ]; then
        # Core's `service issue SCOPE --label L [--replace]`: the
        # credential alone on standard output, what it is on standard
        # error.
        if [ -n "${ISSUE_FAIL:-}" ]; then
          echo "aishie-core: service issue: no site service \"$3\": agent_runtime or document_text" >&2
          exit 1
        fi
        prefix=$(tr -dc 'a-z2-7' < /dev/urandom | head -c 12)
        tok=${SERVICE_TOKEN:-aissvc_${prefix}_$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')}
        revoked=0
        if [[ " $* " == *" --replace "* ]] && [ -f "$FAKE/issued" ]; then revoked=$(wc -l < "$FAKE/issued"); fi
        echo "$tok" >> "$FAKE/issued"
        echo "credential 0192f3c1-0000-7000-8000-00000000000$revoked ($prefix) for the site service $3, $revoked other(s) revoked, shown once:" >&2
        echo "$tok"
        exit 0
      fi
      echo "$svc $* with $(service_image "$svc")"
      if [ "$1" = bootstrap ] && [ -n "${BOOTSTRAP_TOKEN:-}" ]; then
        printf 'root actor   0192f3c1-0000-7000-8000-000000000001\nsystem actor 0192f3c1-0000-7000-8000-000000000002\n\nAPI token for root, shown once:\n' >&2
        echo "$BOOTSTRAP_TOKEN"
      fi
      exit "${RUN_FAIL:-0}" ;;
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
    case $ref in
      rclone/rclone:*@sha256:*)
        if [ -n "${RCLONE_PULL_FAIL:-}" ]; then echo "Error response from daemon: toomanyrequests: rate limit" >&2; exit 1; fi
        echo "$ref"
        exit 0 ;;
    esac
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
  version) echo 29.0.0 ;;
  volume) [ "$2" = inspect ] && [ -e "$FAKE/volumes/$3" ] || exit 1 ;;
  run)
    # aishie-storage: rclone, in its image.
    case "$*" in *" rclone/rclone:"*) exec "$(dirname "$0")/rclone-fake" "$@" ;; esac
    # aishie runtime-status: a wget in the runtime's network namespace.
    case "$*" in *"--entrypoint wget"*) echo '{"worker":"w","agents":[]}'; exit 0 ;; esac
    # setup-server.sh: caddy validate of the Caddyfile, in Caddy's image.
    case "$*" in *" caddy validate "*) exit "${CADDY_FAIL:-0}" ;; esac
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
# The health checks, as the image each service runs would answer them; and
# a request signed for S3 (--aws-sigv4), as a bucket would answer it.
set -u
echo "curl $*" >> "$CALLS"
if [[ " $* " == *" --aws-sigv4 "* ]]; then
  cat > "$FAKE/s3-keys"
  args=("$@")
  method=GET out=/dev/null fmt='' body=''
  for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
      -X) method=${args[i + 1]} ;;
      -I) method=HEAD ;;
      -o) out=${args[i + 1]} ;;
      -w) fmt=${args[i + 1]} ;;
      --data-binary) body=${args[i + 1]#@} ;;
    esac
  done
  url=${args[${#args[@]} - 1]}
  echo "$method $url" >> "$FAKE/s3-requests"
  if [ -n "${S3_DOWN:-}" ]; then
    [[ $fmt != *http_code* ]] || printf 000
    echo "curl: (6) Could not resolve host: ${url#https://}" >&2
    exit 6
  fi
  # An error as S3 writes one, with the access key in it, as AWS's do.
  error() {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>%s</Code><Message>%s</Message>%s<AWSAccessKeyId>%s</AWSAccessKeyId></Error>\n' \
      "$1" "$2" "${3:-}" "$(sed -n 's/^user = "\([^:]*\):.*/\1/p' "$FAKE/s3-keys")"
  }
  : > "$out"
  case "$method $url" in
    "GET "*"?cors=")
      code=${S3_CORS_GET:-}
      if [ -z "$code" ] && [ -f "$FAKE/s3-cors" ]; then
        code=200
        cat "$FAKE/s3-cors" > "$out"
      elif [ -z "$code" ]; then
        code=404
        error NoSuchCORSConfiguration "The CORS configuration does not exist" > "$out"
      elif [ "$code" = other ]; then
        code=200
        echo '<CORSConfiguration><CORSRule><AllowedOrigin>https://elsewhere.example</AllowedOrigin><AllowedMethod>GET</AllowedMethod></CORSRule></CORSConfiguration>' > "$out"
      else
        error AccessDenied "Access Denied" > "$out"
      fi ;;
    "PUT "*"?cors=")
      code=${S3_CORS_PUT:-200}
      if [ "$code" = 200 ]; then cp "$body" "$FAKE/s3-cors"; else error AccessDenied "Access Denied" > "$out"; fi ;;
    "GET "*"?list-type=2&max-keys=1&prefix=courses%2F")
      code=${S3_LIST:-200}
      case $code in
        200) echo '<ListBucketResult><KeyCount>0</KeyCount></ListBucketResult>' > "$out" ;;
        301) error PermanentRedirect "The bucket you are attempting to access must be addressed using the specified endpoint." > "$out" ;;
        400) error AuthorizationHeaderMalformed "The authorization header is malformed; the region 'us-east-1' is wrong; expecting 'eu-west-1'" '<Region>eu-west-1</Region>' > "$out" ;;
        403) error SignatureDoesNotMatch "The request signature we calculated does not match the signature you provided. Check your key and signing method." > "$out" ;;
        404) error NoSuchBucket "The specified bucket does not exist" > "$out" ;;
      esac ;;
    "HEAD "*) code=${S3_HEAD:-404} ;;
    *) code=400 ;;
  esac
  [[ $fmt != *http_code* ]] || printf '%s' "$code"
  exit 0
fi
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
  cat > "$1/rclone-fake" <<'EOF'
#!/usr/bin/env bash
# rclone in its image, as aishie-storage runs it (docker run --rm -e ...
# -v HOST:PATH[:ro]... IMAGE ARGS...), with the bucket, dst:NAME, played by
# $FAKE/bucket: lsf, copy, lsjson and check, with the options aishie-storage
# gives them. As rclone does, each passes over a file --files-from names
# that the source does not have. RCLONE_ATTACH=KEY has the first copy find
# KEY moved to attached/KEY in the bucket since it was listed, as Core moves
# an upload it attaches.
set -euo pipefail
declare -A mount ro
while [ $# -gt 0 ]; do
  case $1 in
    -v)
      IFS=: read -r h c m <<< "$2"
      mount[$c]=$h
      ro[$c]=${m:-}
      shift 2 ;;
    -e) shift 2 ;;
    rclone/rclone:*) shift; break ;;
    *) shift ;;
  esac
done
echo "rclone $*" >> "$CALLS"
if [ -n "${RCLONE_FAIL:-}" ]; then echo "ERROR : failing, as the test asks" >&2; exit 1; fi
[ -f "${mount[/work]}/rclone.conf" ] || { echo "no rclone.conf in /work" >&2; exit 1; }
# here PATH: where a path in the container, or dst:BUCKET/..., is here.
here() {
  case $1 in
    dst:*) p=${1#dst:}; p=${p#*/}; [ "$p" = "${1#dst:}" ] && p=''; echo "$FAKE/bucket${p:+/$p}" ;;
    /work*) echo "${mount[/work]}${1#/work}" ;;
    /data/blobs*) [ -n "${mount[/data/blobs]:-}" ] || { echo "/data/blobs is not mounted" >&2; exit 1; }; echo "${mount[/data/blobs]}${1#/data/blobs}" ;;
    *) echo "a path rclone would not find: $1" >&2; exit 1 ;;
  esac
}
cmd=$1
shift
from='' type='' size_only='' format=p pos=()
while [ $# -gt 0 ]; do
  case $1 in
    --files-from) from=$(here "$2"); shift 2 ;;
    --header-upload) type=${2#Content-Type: }; shift 2 ;;
    --format) format=$2; shift 2 ;;
    --transfers | --checkers | --stats | --stats-log-level) shift 2 ;;
    --size-only) size_only=1; shift ;;
    -*) shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
case $cmd in
  lsf)
    d=$(here "${pos[0]}")
    [ -d "$d" ] || { echo "directory not found" >&2; exit 3; }
    # Each line the fields --format names, in its order: p the path, s the
    # size.
    f=$(sed 's/p/%P;/g; s/s/%s;/g; s/;$//' <<< "$format")
    (cd "$d" && find . -type f -printf "$f\n" | sort) ;;
  copy)
    src=$(here "${pos[0]}") dst=$(here "${pos[1]}")
    [ "${pos[1]}" != /data/blobs ] || [ -z "${ro[/data/blobs]:-}" ] || { echo "/data/blobs is read-only" >&2; exit 1; }
    if [ -n "${RCLONE_ATTACH:-}" ] && [ -f "$FAKE/bucket/$RCLONE_ATTACH" ]; then
      for d in bucket bucket-types; do
        mkdir -p "$(dirname "$FAKE/$d/attached/$RCLONE_ATTACH")"
        mv "$FAKE/$d/$RCLONE_ATTACH" "$FAKE/$d/attached/$RCLONE_ATTACH"
      done
    fi
    while read -r k; do
      [ -f "$src/$k" ] || continue
      mkdir -p "$(dirname "$dst/$k")"
      cp "$src/$k" "$dst/$k"
      if [[ ${pos[1]} == dst:* ]]; then
        mkdir -p "$(dirname "$FAKE/bucket-types/$k")"
        printf '%s
' "${type:-application/octet-stream}" > "$FAKE/bucket-types/$k"
      fi
      if [ "$k" = "${RCLONE_CORRUPT:-}" ]; then printf X | dd of="$dst/$k" bs=1 count=1 conv=notrunc status=none; fi
    done < "$from" ;;
  lsjson)
    echo "["
    sep=''
    while read -r k; do
      [ -f "$FAKE/bucket/$k" ] || continue
      t=$(cat "$FAKE/bucket-types/$k" 2>/dev/null || echo application/octet-stream)
      printf '%s{"Path":"%s","Name":"%s","Size":%s,"MimeType":"%s","ModTime":"","IsDir":false}' \
        "$sep" "$k" "${k##*/}" "$(stat -c %s "$FAKE/bucket/$k")" "$(printf '%s' "$t" | sed 's/[\\"]/\\&/g')"
      sep=$',\n'
    done < "$from"
    printf '\n]\n' ;;
  check)
    src=$(here "${pos[0]}") dst=$(here "${pos[1]}")
    n=0
    while read -r k; do
      if [ ! -f "$src/$k" ]; then continue
      elif [ ! -f "$dst/$k" ]; then n=$((n + 1)); echo "ERROR : $k: file not in the destination" >&2
      elif [ -n "$size_only" ]; then [ "$(stat -c %s "$src/$k")" = "$(stat -c %s "$dst/$k")" ] || n=$((n + 1))
      elif ! cmp -s "$src/$k" "$dst/$k"; then n=$((n + 1)); echo "ERROR : $k: md5 differ" >&2
      fi
    done < "$from"
    echo "NOTICE: $n differences found" >&2
    [ "$n" = 0 ] ;;
  *) echo "rclone $cmd: not played here" >&2; exit 1 ;;
esac
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
