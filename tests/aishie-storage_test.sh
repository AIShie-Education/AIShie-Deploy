#!/usr/bin/env bash
# aishie storage (bin/aishie-storage) against the stand-ins of
# tests/fakes.sh: an S3 service played by curl, rclone's container by
# docker, with the bucket a directory ($FAKE/bucket), and Core's health
# check by curl. Its pure parts are sourced with AISHIE_STORAGE_LIB=1, in
# sh as the server runs them; the migrations run whole, both ways, as root
# would run them, with chown and id played below. No network is reached.
#
#   make test
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
. "$here/fakes.sh"
make_fakes "$work/bin"
# The tests are not root: chown is recorded, and id says 0 (or NOT_ROOT).
cat > "$work/bin/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$CALLS"
EOF
cat > "$work/bin/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -u ]; then echo "${NOT_ROOT:-0}"; else exec /usr/bin/id "$@"; fi
EOF
chmod +x "$work/bin"/*

REG=ghcr.io/aishie-education
A=$(printf 'a%.0s' $(seq 64))
AK=AKIAFAKEACCESSKEY0001
# A secret with a $ in it, which core.env must quote.
# shellcheck disable=SC2016 # the $ is the secret's
SK='fake/Secret+Key$0123456789abcdefghijklmno'
C1=0192f3c1-0000-7000-8000-00000000c001
U1=0192f3c1-0000-7000-8000-00000000f001
U2=0192f3c1-0000-7000-8000-00000000f002
U3=0192f3c1-0000-7000-8000-00000000f003
U4=0192f3c1-0000-7000-8000-00000000f004
U5=0192f3c1-0000-7000-8000-00000000f005

failed=0
fail() { echo "FAIL aishie-storage $case: $*" >&2; failed=1; }

# setup CASE: a server set up, Core deployed and running on the disk, with
# three files people uploaded (each with its .meta, as Core writes them) and
# one upload that stopped before its .meta.
setup() {
  case=$1
  export FAKE=$work/$case CALLS=$work/$case/calls
  mkdir -p "$FAKE/etc" "$FAKE/state" "$FAKE/srv/core" "$FAKE/running" "$FAKE/bucket"
  : > "$CALLS"
  export AISHIE_ETC=$FAKE/etc AISHIE_STATE=$FAKE/state AISHIE_APP=$root AISHIE_DATA=$FAKE/srv \
    AISHIE_LOCK_FILE=$FAKE/lock AISHIE_HEALTH_TRIES=3
  unset S3_LIST S3_HEAD S3_CORS_GET S3_CORS_PUT S3_DOWN RCLONE_PULL_FAIL RCLONE_FAIL RCLONE_CORRUPT RCLONE_ATTACH FLOCK_FAIL NOT_ROOT \
    AISHIE_STORAGE AISHIE_S3_BUCKET AISHIE_S3_REGION AISHIE_S3_ENDPOINT AISHIE_S3_PATH_STYLE AISHIE_R2_ACCOUNT_ID \
    AISHIE_R2_JURISDICTION AISHIE_S3_ACCESS_KEY AISHIE_S3_SECRET_KEY
  image core "$A" v0.2.0 abc1234
  echo "CORE_REF=$REG/aishie-core@sha256:$A" > "$FAKE/state/images.env"
  echo "$REG/aishie-core@sha256:$A" > "$FAKE/running/core"
  printf 'HOST=test.aishie.app\nENVIRONMENT=edge\n' > "$FAKE/etc/aishie.env"
  cat > "$FAKE/etc/core.env" <<EOF
# AIshieCore's settings.
DATABASE_URL=postgres://aishie_core:pw@postgres:5432/aishie_core?sslmode=disable
SIGNING_KEY=$(printf 's%.0s' $(seq 64))
BLOB_STORE=fs
BLOB_FS_ROOT=/data/blobs
EOF
  chmod 600 "$FAKE/etc/core.env"
  blobs=$FAKE/srv/core/blobs
  blob "courses/$C1/$U1" "%PDF-1.7 lecture one" application/pdf
  blob "courses/$C1/$U2" "an essay, handed in" 'text/plain; charset=\"utf-8\"'
  blob "courses/$C1/$U3" "PK a zip of work" application/zip
  printf 'half an upload' > "$blobs/courses/$C1/$U4"
}
# blob KEY BYTES TYPE: a file on the disk as Core's store writes it, TYPE
# as it is in JSON.
blob() {
  mkdir -p "$(dirname "$blobs/$1")"
  printf '%s' "$2" > "$blobs/$1"
  printf '{"Size":%d,"ContentType":"%s","Checksum":"sha256:%s"}' "${#2}" "$3" "$(printf '%s' "$2" | sha256sum | cut -d ' ' -f 1)" > "$blobs/$1.meta"
}
# storage ARGS...: the command, whole, as root, with standard input from
# STDIN when it names a file, else nothing.
storage() { PATH="$work/bin:$PATH" "$root/bin/aishie-storage" "$@" < "${STDIN:-/dev/null}" > "$FAKE/out" 2>&1; }
# lib CODE: some of it, in sh.
lib() { PATH="$work/bin:$PATH" AISHIE_STORAGE_LIB=1 sh -c '. "$0"; eval "$1"' "$root/bin/aishie-storage" "$1"; }
called() { grep -q -- "$1" "$CALLS"; }
said() { grep -q -- "$1" "$FAKE/out"; }
setting() { sed -n "s/^$2=//p" "$AISHIE_ETC/$1" | tail -n 1; }
sums() { (cd "$AISHIE_ETC" && sha256sum core.env); }
line() { grep -n -- "$1" "$CALLS" | head -n 1 | cut -d: -f1; }
# aws ARGS...: aishie storage ARGS..., to the bucket aishie-files of AWS
# in ap-east-1, with the keys in the environment.
aws() { AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK storage "$@" --storage aws --s3-region ap-east-1 --s3-bucket aishie-files; }
no_secret() {
  for f in "$FAKE/out" "$CALLS" "$FAKE/s3-requests"; do
    [ -f "$f" ] || continue
    if grep -qF -- "$SK" "$f"; then fail "the secret key is in $(basename "$f")"; fi
    if grep -qF -- "$AK" "$f"; then fail "the access key is in $(basename "$f")"; fi
  done
}

# How a value is written to core.env: bare when it can be, else in single
# quotes, which Compose takes as they are ($ and all).
case=quoting
[ "$(lib 'st_q abc/DEF+g=h')" = 'abc/DEF+g=h' ] || fail "quoted a plain value: $(lib 'st_q abc/DEF+g=h')"
# shellcheck disable=SC2016 # a $, for the quoting
[ "$(lib 'st_q "a\$b"')" = "'a\$b'" ] || fail "a value with a \$ is not in single quotes: $(lib 'st_q "a\$b"')"

# Each kind of bucket: the endpoint, the region Core signs with, and the
# URL the check reaches it by, as Core's S3 client addresses it.
case=kinds
resolve() { lib "ST_AK=$AK ST_SK=abc; $1; st_resolve; echo \"\$ST_ENDPOINT \$ST_REGION \$(st_bucket_url)\""; }
[ "$(resolve 'ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=files')" = "s3.ap-east-1.amazonaws.com ap-east-1 https://files.s3.ap-east-1.amazonaws.com" ] ||
  fail "aws: $(resolve 'ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=files')"
[ "$(resolve 'ST_KIND=aws ST_REGION=cn-north-1 ST_BUCKET=files')" = "s3.cn-north-1.amazonaws.com.cn cn-north-1 https://files.s3.cn-north-1.amazonaws.com.cn" ] ||
  fail "aws in China: $(resolve 'ST_KIND=aws ST_REGION=cn-north-1 ST_BUCKET=files')"
[ "$(resolve 'ST_KIND=aws ST_REGION=eu-west-1 ST_BUCKET=files.example.edu')" = "s3.eu-west-1.amazonaws.com eu-west-1 https://s3.eu-west-1.amazonaws.com/files.example.edu" ] ||
  fail "aws, a name with dots, by path: $(resolve 'ST_KIND=aws ST_REGION=eu-west-1 ST_BUCKET=files.example.edu')"
R2=0123456789abcdef0123456789abcdef
[ "$(resolve "ST_KIND=r2 ST_R2_ACCOUNT=$R2 ST_BUCKET=files")" = "$R2.r2.cloudflarestorage.com auto https://$R2.r2.cloudflarestorage.com/files" ] ||
  fail "r2: $(resolve "ST_KIND=r2 ST_R2_ACCOUNT=$R2 ST_BUCKET=files")"
[ "$(resolve "ST_KIND=r2 ST_R2_ACCOUNT=$R2 ST_R2_JURISDICTION=eu ST_BUCKET=files")" = "$R2.eu.r2.cloudflarestorage.com auto https://$R2.eu.r2.cloudflarestorage.com/files" ] ||
  fail "r2 in the EU: $(resolve "ST_KIND=r2 ST_R2_ACCOUNT=$R2 ST_R2_JURISDICTION=eu ST_BUCKET=files")"
[ "$(resolve 'ST_KIND=b2 ST_REGION=us-west-004 ST_BUCKET=files')" = "s3.us-west-004.backblazeb2.com us-west-004 https://s3.us-west-004.backblazeb2.com/files" ] ||
  fail "b2: $(resolve 'ST_KIND=b2 ST_REGION=us-west-004 ST_BUCKET=files')"
[ "$(resolve 'ST_KIND=b2 ST_ENDPOINT=s3.eu-central-003.backblazeb2.com ST_BUCKET=files')" = "s3.eu-central-003.backblazeb2.com eu-central-003 https://s3.eu-central-003.backblazeb2.com/files" ] ||
  fail "b2, the region from the endpoint: $(resolve 'ST_KIND=b2 ST_ENDPOINT=s3.eu-central-003.backblazeb2.com ST_BUCKET=files')"
[ "$(resolve 'ST_KIND=s3 ST_ENDPOINT=https://minio.example.edu:9000/ ST_BUCKET=files')" = "minio.example.edu:9000 us-east-1 https://minio.example.edu:9000/files" ] ||
  fail "s3: $(resolve 'ST_KIND=s3 ST_ENDPOINT=https://minio.example.edu:9000/ ST_BUCKET=files')"
[ "$(resolve 'ST_KIND=s3 ST_ENDPOINT=s3.example.com ST_REGION=nl-ams ST_PATH_STYLE=yes ST_BUCKET=files')" = "s3.example.com nl-ams https://s3.example.com/files" ] ||
  fail "s3 with a region: $(resolve 'ST_KIND=s3 ST_ENDPOINT=s3.example.com ST_REGION=nl-ams ST_PATH_STYLE=yes ST_BUCKET=files')"
# What is refused, and why.
refused() {
  if out=$(resolve "$1" 2>&1); then fail "took «$1»: $out"; fi
  [[ $out == *"$2"* ]] || fail "for «$1», said: $out"
}
refused 'ST_KIND=disk' "fs, aws, r2, b2 or s3"
refused 'ST_KIND=aws ST_REGION=mars-north-1 ST_BUCKET=files' "not an AWS region Core's S3 client knows"
refused 'ST_KIND=aws ST_BUCKET=files' "not an AWS region"
refused 'ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=-files' "is not a bucket's name"
refused 'ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=a..b' "is not a bucket's name"
refused 'ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=ab' "3 to 63 characters"
refused 'ST_KIND=r2 ST_R2_ACCOUNT=my-account ST_BUCKET=files' "not a Cloudflare account ID"
refused "ST_KIND=r2 ST_R2_ACCOUNT=$R2 ST_R2_JURISDICTION=mars ST_BUCKET=files" "default, eu or fedramp"
refused 'ST_KIND=b2 ST_BUCKET=files' "B2's region is in the bucket's endpoint"
refused 'ST_KIND=s3 ST_ENDPOINT=http://minio.example.edu ST_BUCKET=files' "refuse to send it to an http:// address"
refused 'ST_KIND=s3 ST_ENDPOINT=s3.example.com/path ST_BUCKET=files' "HOST or HOST:PORT"
refused 'ST_KIND=s3 ST_ENDPOINT=s3.example.com ST_PATH_STYLE=no ST_BUCKET=files' "no setting for virtual-hosted addressing yet"
refused "ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=files; ST_SK='a b'" "has a space, a quote, a backslash"
refused "ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=files; ST_SK=\"a'b\"" "has a space, a quote, a backslash"
refused "ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=files; ST_SK=''" "the secret key is empty"
refused "ST_KIND=aws ST_REGION=ap-east-1 ST_BUCKET=files; ST_AK=a:b" "has a colon in it"

# Where things are, before anything moves.
setup status
storage || fail "exit $?: $(cat "$FAKE/out")"
said "on this server's disk (BLOB_STORE=fs): $FAKE/srv/core/blobs" || fail "said: $(cat "$FAKE/out")"
said "On this disk: 3 files" || fail "said: $(cat "$FAKE/out")"
if NOT_ROOT=1000 storage status; then fail "ran as a user"; fi
said "run this as root" || fail "as a user, said: $(cat "$FAKE/out")"
storage help || fail "help: exit $?"
said "aishie storage migrate --to s3" || fail "help said: $(cat "$FAKE/out")"
said -- "--storage r2 --r2-account-id ID" || fail "help does not say the bucket options: $(cat "$FAKE/out")"
if storage sideways; then fail "took a command it has not"; fi

# A dry run to AWS: what would be copied, and nothing done. One file is in
# the bucket already, the same size, from a run that stopped.
setup dry-run
mkdir -p "$FAKE/bucket/courses/$C1"
cp "$blobs/courses/$C1/$U1" "$FAKE/bucket/courses/$C1/$U1"
before=$(sums)
aws migrate --to s3 --dry-run || fail "exit $?: $(cat "$FAKE/out")"
said "on this disk: 3 files" || fail "said: $(cat "$FAKE/out")"
said "in the bucket already, the same size: 1" || fail "said: $(cat "$FAKE/out")"
said "to copy: 2 files" || fail "said: $(cat "$FAKE/out")"
said "left out: 1 without their .meta" || fail "did not say what it leaves out: $(cat "$FAKE/out")"
said "A dry run: nothing was copied" || fail "said: $(cat "$FAKE/out")"
said "the bucket has no CORS rule yet" || fail "did not say the bucket's CORS rule is missing: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "changed core.env"
! called "rclone copy" || fail "copied: $(grep 'rclone copy' "$CALLS")"
! called "compose .* stop core" || fail "stopped Core"
! grep -q '^PUT ' "$FAKE/s3-requests" || fail "wrote to the bucket: $(grep '^PUT ' "$FAKE/s3-requests")"
[ "$(find "$FAKE/bucket" -type f | wc -l)" = 1 ] || fail "the bucket changed: $(find "$FAKE/bucket" -type f)"
called "docker pull -q rclone/rclone:1.75.1@sha256:" || fail "rclone's image not pinned by digest: $(grep 'docker pull' "$CALLS")"
# The keys: to curl on its standard input, to rclone in a file of its own.
grep -qxF "user = \"$AK:$SK\"" "$FAKE/s3-keys" || fail "curl was not given the keys"
called "rclone lsf -R --files-only --format ps dst:aishie-files/courses" || fail "listed: $(grep 'rclone' "$CALLS")"
no_secret
[ -z "$(find "$FAKE/state" -name 'storage.*' -type d)" ] || fail "left its directory, with rclone.conf: $(find "$FAKE/state" -name 'storage.*')"

# The move to AWS, whole.
setup to-aws
before=$(cat "$AISHIE_ETC/core.env")
cat > "$FAKE/on-stop" <<EOF
#!/bin/sh
# An upload that came in while the first copy ran.
mkdir -p "$blobs/courses/$C1"
printf 'late' > "$blobs/courses/$C1/$U5"
printf '{"Size":4,"ContentType":"image/png","Checksum":"sha256:x"}' > "$blobs/courses/$C1/$U5.meta"
EOF
chmod +x "$FAKE/on-stop"
aws migrate --to s3 || fail "exit $?: $(cat "$FAKE/out")"
# Every file, under its key, with its bytes and its content type; not the
# .meta, nor the file without one.
for u in "$U1" "$U2" "$U3" "$U5"; do
  cmp -s "$blobs/courses/$C1/$u" "$FAKE/bucket/courses/$C1/$u" || fail "courses/$C1/$u is not in the bucket as it is on the disk"
done
[ "$(cat "$FAKE/bucket-types/courses/$C1/$U1")" = application/pdf ] || fail "U1's type: $(cat "$FAKE/bucket-types/courses/$C1/$U1")"
[ "$(cat "$FAKE/bucket-types/courses/$C1/$U2")" = 'text/plain; charset="utf-8"' ] || fail "U2's type: $(cat "$FAKE/bucket-types/courses/$C1/$U2")"
[ "$(cat "$FAKE/bucket-types/courses/$C1/$U5")" = image/png ] || fail "the late upload's type: $(cat "$FAKE/bucket-types/courses/$C1/$U5" 2>&1)"
[ -z "$(find "$FAKE/bucket" -name '*.meta')" ] || fail "copied a .meta"
[ ! -e "$FAKE/bucket/courses/$C1/$U4" ] || fail "copied the upload without a .meta"
# The disk keeps its copy.
if [ ! -f "$blobs/courses/$C1/$U1" ] || [ ! -f "$blobs/courses/$C1/$U1.meta" ]; then fail "the disk's copy is gone"; fi
# The CORS rule, set by the S3 API since the bucket had none.
grep -qF '<AllowedOrigin>https://test.aishie.app</AllowedOrigin>' "$FAKE/s3-cors" || fail "no CORS rule for the site: $(cat "$FAKE/s3-cors" 2>&1)"
grep -qF '<AllowedMethod>PUT</AllowedMethod>' "$FAKE/s3-cors" || fail "the CORS rule lets no PUT"
called "curl .*-X PUT .*-H Content-MD5: " || fail "PutBucketCors without its MD5"
# The copy while Core ran, then Core stopped under aishie-update's lock for
# what came in meanwhile, the check, the switch, and Core started on it.
[ "$(line 'rclone copy')" -lt "$(line 'flock -w 600 9')" ] || fail "the first copy was not before the lock"
[ "$(line 'flock -w 600 9')" -lt "$(line 'compose .* stop core')" ] || fail "Core was stopped outside the lock"
[ "$(line 'compose .* stop core')" -lt "$(grep -n "rclone copy .*/work/group" "$CALLS" | tail -n 1 | cut -d: -f1)" ] || fail "no copy with Core stopped"
called "rclone check --one-way --checkers 16 --files-from /work/check.keys /data/blobs dst:aishie-files" || fail "no check by checksum: $(grep 'rclone check' "$CALLS")"
called "compose .* up -d --no-deps core" || fail "Core not started again"
[ "$(setting core.env BLOB_STORE)" = s3 ] || fail "BLOB_STORE=$(setting core.env BLOB_STORE)"
[ "$(setting core.env S3_ENDPOINT)" = s3.ap-east-1.amazonaws.com ] || fail "S3_ENDPOINT=$(setting core.env S3_ENDPOINT)"
[ "$(setting core.env S3_BUCKET)" = aishie-files ] || fail "S3_BUCKET=$(setting core.env S3_BUCKET)"
[ "$(setting core.env S3_REGION)" = ap-east-1 ] || fail "S3_REGION=$(setting core.env S3_REGION)"
[ "$(setting core.env S3_USE_SSL)" = true ] || fail "S3_USE_SSL=$(setting core.env S3_USE_SSL)"
[ "$(setting core.env S3_ACCESS_KEY)" = "$AK" ] || fail "S3_ACCESS_KEY is not the key given"
[ "$(setting core.env S3_SECRET_KEY)" = "'$SK'" ] || fail "S3_SECRET_KEY is not the secret given, in single quotes for its \$"
[ "$(setting core.env BLOB_FS_ROOT)" = /data/blobs ] || fail "BLOB_FS_ROOT=$(setting core.env BLOB_FS_ROOT)"
grep -q '^DATABASE_URL=postgres://aishie_core:pw@' "$AISHIE_ETC/core.env" || fail "DATABASE_URL lost"
grep -q '^SIGNING_KEY=s' "$AISHIE_ETC/core.env" || fail "SIGNING_KEY lost"
[ "$(stat -c %a "$AISHIE_ETC/core.env")" = 600 ] || fail "core.env is $(stat -c %a "$AISHIE_ETC/core.env")"
backup=$(ls "$AISHIE_ETC"/core.env.before-storage-*)
[ "$(cat "$backup")" = "$before" ] || fail "the core.env kept is not the one before"
[ "$(stat -c %a "$backup")" = 600 ] || fail "the core.env kept is $(stat -c %a "$backup")"
said "all 4 files, .* are on both sides, the same size, and the same by checksum" || fail "said: $(cat "$FAKE/out")"
said "Core reports healthy" || fail "said: $(cat "$FAKE/out")"
said "rm -r $blobs" || fail "did not say how to free the disk: $(cat "$FAKE/out")"
no_secret

# Once there: nothing more to move there, and the check and the CORS rule
# of the bucket core.env names.
aws migrate --to s3 && fail "moved to a bucket again"
said "in a bucket already" || fail "said: $(cat "$FAKE/out")"
storage check || fail "check: exit $?: $(cat "$FAKE/out")"
said "the bucket aishie-files of Amazon S3, in ap-east-1 (s3.ap-east-1.amazonaws.com) answers" || fail "check said: $(cat "$FAKE/out")"
said "nothing was written" || fail "check said: $(cat "$FAKE/out")"
storage cors || fail "cors: exit $?: $(cat "$FAKE/out")"
said "the bucket's CORS rules let https://test.aishie.app upload to it" || fail "cors said: $(cat "$FAKE/out")"
storage || fail "status: exit $?"
said "Core keeps the files people upload in the bucket aishie-files of Amazon S3" || fail "status said: $(cat "$FAKE/out")"
no_secret

# And back: what came to the bucket since (attached, as Core's S3 store
# keeps what a document points at) is copied to the disk, with the .meta
# Core's disk store would have written.
case=back-to-disk
mkdir -p "$FAKE/bucket/attached/courses/$C1" "$FAKE/bucket-types/attached/courses/$C1"
printf 'a new version' > "$FAKE/bucket/attached/courses/$C1/$U4"
echo 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' > "$FAKE/bucket-types/attached/courses/$C1/$U4"
storage migrate --to fs --dry-run || fail "dry run: exit $?: $(cat "$FAKE/out")"
said "in the bucket: 5 objects" || fail "said: $(cat "$FAKE/out")"
said "to copy: 1 files" || fail "said: $(cat "$FAKE/out")"
[ ! -e "$blobs/attached" ] || fail "the dry run copied"
[ "$(setting core.env BLOB_STORE)" = s3 ] || fail "the dry run switched"
AISHIE_STORAGE=r2 AISHIE_S3_BUCKET=elsewhere storage migrate --to fs --dry-run || fail "the variables a set-up left stopped --to fs: $(cat "$FAKE/out")"
said "now: the bucket aishie-files of Amazon S3" || fail "not from the bucket core.env names: $(cat "$FAKE/out")"
: > "$CALLS"
storage migrate --to fs || fail "exit $?: $(cat "$FAKE/out")"
f=$blobs/attached/courses/$C1/$U4
cmp -s "$f" "$FAKE/bucket/attached/courses/$C1/$U4" || fail "the new version is not on the disk"
want="{\"Size\":13,\"ContentType\":\"application/vnd.openxmlformats-officedocument.wordprocessingml.document\",\"Checksum\":\"sha256:$(sha256sum < "$f" | cut -d ' ' -f 1)\"}"
[ "$(cat "$f.meta" 2>&1)" = "$want" ] || fail "its .meta: $(cat "$f.meta" 2>&1), not $want"
called "chown 65532:65532 -- attached/courses/$C1/$U4 attached/courses/$C1/$U4.meta" || fail "not given to Core's user: $(grep chown "$CALLS")"
called "rclone copy --files-from /work/keys .* dst:aishie-files /data/blobs" || fail "copied: $(grep 'rclone copy' "$CALLS")"
[ "$(setting core.env BLOB_STORE)" = fs ] || fail "BLOB_STORE=$(setting core.env BLOB_STORE)"
# The bucket's settings stay, for a move there again, which then needs no
# options.
[ "$(setting core.env S3_BUCKET)" = aishie-files ] || fail "the bucket's settings were not kept"
[ "$(setting core.env S3_SECRET_KEY)" = "'$SK'" ] || fail "the secret was not kept as it was"
said "The bucket keeps its objects" || fail "said: $(cat "$FAKE/out")"
storage migrate --to s3 --dry-run || fail "a dry run to the bucket core.env names: exit $?: $(cat "$FAKE/out")"
said "the bucket core.env names already: the bucket aishie-files" || fail "said: $(cat "$FAKE/out")"
said "in the bucket already, the same size: 5" || fail "said: $(cat "$FAKE/out")"
if storage migrate --to fs --storage aws; then fail "took bucket options for --to fs"; fi
said "takes no bucket options" || fail "said: $(cat "$FAKE/out")"
no_secret

# Back from a bucket where an upload is attached while the first copy runs:
# Core moves it under attached/, rclone passes over it where it was, and
# the copy with Core stopped finds it where it went.
setup attached-meanwhile
aws migrate --to s3 || fail "exit $?: $(cat "$FAKE/out")"
mkdir -p "$FAKE/bucket/courses/$C1" "$FAKE/bucket-types/courses/$C1"
printf 'staged, then attached' > "$FAKE/bucket/courses/$C1/$U5"
echo image/png > "$FAKE/bucket-types/courses/$C1/$U5"
RCLONE_ATTACH=courses/$C1/$U5 storage migrate --to fs || fail "exit $?: $(cat "$FAKE/out")"
f=$blobs/attached/courses/$C1/$U5
cmp -s "$f" "$FAKE/bucket/attached/courses/$C1/$U5" || fail "the upload attached meanwhile is not on the disk"
grep -q '"ContentType":"image/png"' "$f.meta" 2>/dev/null || fail "its .meta: $(cat "$f.meta" 2>&1)"
[ ! -e "$blobs/courses/$C1/$U5" ] || fail "a copy of it where it was"
[ "$(setting core.env BLOB_STORE)" = fs ] || fail "BLOB_STORE=$(setting core.env BLOB_STORE)"

# A copy that arrives with other bytes: the check says so, and nothing is
# switched; Core was never stopped.
setup corrupt
before=$(sums)
if RCLONE_CORRUPT=courses/$C1/$U2 aws migrate --to s3; then fail "passed with a file that differs"; fi
said "not the same on both sides" || fail "said: $(cat "$FAKE/out")"
said "md5 differ" || fail "did not show rclone's check: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "changed core.env"
! called "compose .* stop core" || fail "stopped Core"
# ... or one uploaded while Core was stopped: Core is started again, as it
# was.
setup corrupt-while-stopped
before=$(sums)
cat > "$FAKE/on-stop" <<EOF
#!/bin/sh
printf 'late' > "$blobs/courses/$C1/$U5"
printf '{"Size":4,"ContentType":"image/png","Checksum":"sha256:x"}' > "$blobs/courses/$C1/$U5.meta"
EOF
chmod +x "$FAKE/on-stop"
if RCLONE_CORRUPT=courses/$C1/$U5 aws migrate --to s3; then fail "passed with a file that differs"; fi
said "the two sides differ" || fail "said: $(cat "$FAKE/out")"
said "starting Core again, as it was" || fail "said: $(cat "$FAKE/out")"
[ "$(line 'compose .* stop core')" -lt "$(grep -n 'compose .* up -d --no-deps core' "$CALLS" | tail -n 1 | cut -d: -f1)" ] || fail "Core not started after it was stopped"
[ "$(sums)" = "$before" ] || fail "changed core.env"

# Core does not come up on the bucket: core.env is put back, and Core
# started on it again.
setup unhealthy
before=$(sums)
unhealthy "$A"
if aws migrate --to s3; then fail "passed with Core unhealthy"; fi
said "Core did not report healthy on the other side" || fail "said: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "core.env not put back"
[ "$(grep -c 'compose .* up -d --no-deps core' "$CALLS")" = 2 ] || fail "Core not started again on the old core.env"

# Core not deployed yet: core.env switched, and nothing started.
setup not-deployed
echo "# nothing deployed yet" > "$FAKE/state/images.env"
aws migrate --to s3 || fail "exit $?: $(cat "$FAKE/out")"
[ "$(setting core.env BLOB_STORE)" = s3 ] || fail "BLOB_STORE=$(setting core.env BLOB_STORE)"
! called "compose .* stop core" || fail "stopped Core"
! called "compose .* up" || fail "started Core"
said "Core is not deployed yet" || fail "said: $(cat "$FAKE/out")"

# The bucket refuses: nothing copied, nothing changed, and why, from the
# answer's code and message, never the whole of it (it names the key).
setup refused
before=$(sums)
if S3_LIST=403 aws migrate --to s3; then fail "passed with the keys refused"; fi
said "the keys were refused, or may not list the bucket's objects (SignatureDoesNotMatch: The request signature" || fail "said: $(cat "$FAKE/out")"
! called "rclone" || fail "ran rclone"
[ "$(sums)" = "$before" ] || fail "changed core.env"
no_secret
if S3_LIST=400 aws migrate --to s3; then fail "passed in the wrong region"; fi
said "the bucket aishie-files is not in ap-east-1: it is in eu-west-1" || fail "said: $(cat "$FAKE/out")"
if S3_LIST=404 aws migrate --to s3; then fail "passed with no bucket"; fi
said "there is no bucket aishie-files at s3.ap-east-1.amazonaws.com" || fail "said: $(cat "$FAKE/out")"
if S3_DOWN=1 aws migrate --to s3; then fail "passed with no answer"; fi
said "no answer from s3.ap-east-1.amazonaws.com: curl: (6) Could not resolve host" || fail "said: $(cat "$FAKE/out")"
if S3_HEAD=403 aws migrate --to s3; then fail "passed with objects it may not read"; fi
said "or may not read its objects" || fail "said: $(cat "$FAKE/out")"
# No keys, and nobody to ask for them.
if storage migrate --to s3 --storage aws --s3-region ap-east-1 --s3-bucket aishie-files; then fail "passed without keys"; fi
said "aws needs its access key (AISHIE_S3_ACCESS_KEY)" || fail "said: $(cat "$FAKE/out")"
if storage migrate --to s3; then fail "passed without a bucket"; fi
said "which bucket?" || fail "said: $(cat "$FAKE/out")"
# rclone's image cannot be pulled: nothing copied.
if RCLONE_PULL_FAIL=1 aws migrate --to s3; then fail "passed without rclone"; fi
said "could not pull rclone/rclone" || fail "said: $(cat "$FAKE/out")"
[ "$(sums)" = "$before" ] || fail "changed core.env"

# A bucket whose CORS rules the keys may not set: the move stops before it
# copies, with the rule and where to set it. A bucket with rules of its own
# is left alone.
setup cors
before=$(sums)
if S3_CORS_PUT=403 aws migrate --to s3; then fail "passed with no CORS rule"; fi
said "these keys may not set one (HTTP 403)" || fail "said: $(cat "$FAKE/out")"
said '"AllowedOrigins": \["https://test.aishie.app"\]' || fail "no rule: $(cat "$FAKE/out")"
said '"AllowedMethods": \["GET", "HEAD", "PUT"\]' || fail "no rule: $(cat "$FAKE/out")"
said "S3, Buckets, aishie-files, the Permissions tab, Cross-origin" || fail "no AWS console steps: $(cat "$FAKE/out")"
said "aishie storage cors --apply --ask-keys" || fail "no command: $(cat "$FAKE/out")"
! called "rclone copy" || fail "copied"
[ "$(sums)" = "$before" ] || fail "changed core.env"
rm -f "$FAKE/s3-requests"
if S3_CORS_GET=other aws migrate --to s3; then fail "passed over another site's CORS rules"; fi
said "none of which lets https://test.aishie.app upload" || fail "said: $(cat "$FAKE/out")"
! grep -q '^PUT ' "$FAKE/s3-requests" || fail "replaced the bucket's rules"
# Rules it may not read: said, and the move goes on.
S3_CORS_GET=403 aws migrate --to s3 || fail "stopped over rules it may not read: $(cat "$FAKE/out")"
said "may not read the bucket's CORS rules" || fail "said: $(cat "$FAKE/out")"
# cors --apply with other keys, asked for, for this once.
setup cors-keys
aws migrate --to s3 || fail "exit $?: $(cat "$FAKE/out")"
rm -f "$FAKE/s3-cors"
printf 'ADMINKEY\nadmin-secret\n' > "$FAKE/answers"
STDIN=$FAKE/answers storage cors --apply --ask-keys || fail "cors --apply: exit $?: $(cat "$FAKE/out")"
said "the bucket has a CORS rule now" || fail "said: $(cat "$FAKE/out")"
grep -qxF 'user = "ADMINKEY:admin-secret"' "$FAKE/s3-keys" || fail "not with the keys asked for"
! grep -q 'admin-secret' "$AISHIE_ETC/core.env" "$FAKE/out" "$CALLS" || fail "kept or showed the keys asked for"

# Another S3 service, R2 and B2: each one's endpoint, and rclone told how
# to reach it.
for kind in r2 b2 s3; do
  setup "to-$kind"
  case $kind in
    r2) set -- --storage r2 --r2-account-id "$R2" --s3-bucket files ;;
    b2) set -- --storage b2 --s3-region us-west-004 --s3-bucket files ;;
    s3) set -- --storage s3 --s3-endpoint minio.example.edu:9000 --s3-bucket files ;;
  esac
  AISHIE_S3_ACCESS_KEY=$AK AISHIE_S3_SECRET_KEY=$SK storage migrate --to s3 "$@" || fail "exit $?: $(cat "$FAKE/out")"
  case $kind in
    r2) want="$R2.r2.cloudflarestorage.com auto" ;;
    b2) want="s3.us-west-004.backblazeb2.com us-west-004" ;;
    s3) want="minio.example.edu:9000 us-east-1" ;;
  esac
  [ "$(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION)" = "$want" ] ||
    fail "S3_ENDPOINT and S3_REGION: $(setting core.env S3_ENDPOINT) $(setting core.env S3_REGION)"
  [ -f "$FAKE/bucket/courses/$C1/$U3" ] || fail "not copied"
  no_secret
done

[ "$failed" = 0 ] && echo "aishie-storage: ok"
exit "$failed"
