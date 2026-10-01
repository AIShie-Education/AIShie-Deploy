# When something goes wrong

Everything here is done as root on the server. Three things say what
happened:

- `aishie-update --status`: for each service, the image it runs, the
  channel it follows, the last check and what it found, the last outcome,
  and the images recorded as failed;
- `/var/log/aishie-update.log`: one line per outcome, with the time, the
  service, the digest before and after, and what happened;
- `journalctl -u aishie-update`: every run in full, with the output of each
  step (the migrations', the health checks', the new version's last log
  lines).

`aishie logs SERVICE` shows a service's own log (`core`, `runtime`, `web`,
`caddy`, `postgres`).

Whatever went wrong, the rule of a deploy holds: up to the moment the
service is recreated, the version that ran goes on running, and the run
stops at the step that failed. A run never starts the next service after a
failure; the next run, five minutes later, goes on with the others. A
digest that failed before, and a Core its channel names that is refused
for Core's migration 0027 (below), are no failure of the run: each is left
be, logged once, and the run goes on with the next service.

## A migration failed

The log says `migrate up failed`, and the journal has the migration's
error. The version that ran goes on running, and the new digest is recorded
as failed, so the runs after leave it alone. A backup was taken just before
(`/var/backups/aishie/core-deploy-*.dump`, or `runtime-deploy-*`).

Each migration runs in one transaction, so a failed one has usually left
nothing behind, but the schema is marked dirty at its number, N:

```
aishie core migrate version       # schema version N ... DIRTY
aishie runtime migrate version
```

Core: `/healthz` answers 503 while the schema is dirty, and the old version
keeps serving requests. The runtime: no version starts on a dirty schema,
though the one running keeps running.

1. Fix the cause the error names. Most often it is data the migration did
   not expect; then the fix is a new image, and the channel moves on to it
   by itself.
2. Record the migration before the failed one as the last one applied:

   ```
   aishie core migrate force <N - 1>
   aishie compose exec postgres psql -U postgres -d aishie_runtime \
     -c 'UPDATE schema_migrations SET version = <N - 1>, dirty = false'   # the runtime has no migrate force
   ```

3. Try again: `aishie-update --retry core` (or `runtime`), which forgets the
   failed digest and runs.

If you are not sure what the failed migration left, restore the backup
taken before it instead (README.md, Restoring a backup).

## Core's seed failed after migration 0027

A seed that fails leaves the version that ran running, and records the new
digest as failed. After a new Core's migration 0027, that is the one case
where the version that ran goes on running on a schema it does not work
on: 0027 is in by then. The log says `seed failed (above); sha256:… goes
on running, but sha256:…'s migrations stop at 26, before Core's migration
0027`. Fix what the seed says and `aishie-update --retry core`, or go back
by hand with the image that has 0027 (README.md, Rolling back past Core's
migration 0027).

## The new version did not report healthy

The log says `not healthy within 60 seconds`, then one of four things:

- **`rolled back: sha256:… runs again`.** The version before was started
  again and reports healthy. The new digest is recorded as failed. The
  journal has the new version's last 30 log lines: that is where the reason
  is. The new schema stays (it was migrated before the switch), and the
  version before works with it: every migration leaves the release before
  it working (Core's and the runtime's CONTRIBUTING.md, Migrations), every
  one but Core's migration 0027, which the next case is about.
- **`not rolled back: sha256:…'s migrations stop at 26, before Core's
  migration 0027`.** The new Core brought migration 0027, which the Core
  before cannot work on: started again, it would report healthy and fail
  every authenticated call that reads an actor or a document's version.
  So the new one goes on running, not healthy, and nothing is recorded as
  failed. `aishie logs core` says why; once that is fixed (most often an
  env file), `aishie compose up -d core`. To go back instead: README.md,
  Rolling back past Core's migration 0027.
- **`rolled back to sha256:…, which does not report healthy either`.**
  Neither version starts. What they share is the settings: most likely an
  env file (`/etc/aishie/core.env`, `runtime.env`) or, for the runtime, the
  agents' configuration. `aishie logs core` says which setting. Fix it,
  then `aishie compose up -d core` starts the version the state names, and
  `aishie-update --retry core` tries the new one again.
- **`nothing ran before it, and nothing runs now`.** The first deploy of the
  service did not come up. Its container was removed, so that nothing half
  started stays. Read the journal, fix what it names, then
  `aishie-update --retry SERVICE`.

What each checks: Core's `/healthz` on 127.0.0.1:8080 must answer status
`ok` with the version and commit the image's `version` prints (it answers
503 while its database cannot be reached or its schema is behind); the
runtime's on 127.0.0.1:9090 the same; the web's `/version.json` on
127.0.0.1:8081 the commit of the image's revision label.

## Core is refused: its migrations stop before 0027

The log says `refused: sha256:…'s migrations stop at 26, before Core's
migration 0027, which the schema has`. The Core named, by `--pin` or by the
channel, is from before Core's migration 0027, and the schema has 0027: it
would report healthy and fail every authenticated call. Nothing was
changed, no backup was taken, and the Core that runs goes on running. A
channel that names it is refused at every run, logged once, and the run
goes on with the runtime and the web, which update as ever.

A schema left dirty at 27 by a failed `migrate up` of 0027 does not have
it: a Core from before it is not refused there, and its own `migrate up`
fails on the dirty schema ([A migration failed](#a-migration-failed)).

- To go back past 0027, migrate down first (README.md, Rolling back past
  Core's migration 0027), then `--pin` again; a channel's Core goes ahead
  at the next run.
- To stay on 0027: on stable, set `CORE_IMAGE` back to the release that
  runs; on edge, where `:edge` has gone back past 0027, pin the Core that
  runs (`aishie-update --pin core sha256:<its digest>`, from
  `aishie-update --status`) until `:edge` has 0027 again.

## The updater keeps skipping a failed digest

`aishie-update --status` shows the digest under `failed:`, and the log has
one line: `skipped: it failed before`. That is on purpose: a digest that
failed is not tried every five minutes. It is left alone until either

- the channel names another digest (a fix pushed to main, for edge; a
  new release set in `aishie.env`, for stable), which is deployed as
  usual; or
- you run `aishie-update --retry SERVICE`, once the cause is fixed on the
  server (an env file, the agents' configuration, a migration forced back).
  It forgets that service's failed digests and runs.

A service pinned by hand (`aishie-update --pin`) is not updated at all
until `aishie-update --unpin SERVICE`; `--status` shows `pinned:`.

## An image cannot be pulled

The log says `could not pull …`, once, and every run after fails the same
way without logging it again (the journal has each). Nothing is changed:
what runs goes on running. The three images are public packages on
ghcr.io, which a server pulls with no login, so the error says which of
these it is:

- **`denied` or `unauthorized`:** the server still has a login to ghcr.io
  from before the images were public, in `/root/.docker/config.json`, and
  its token has expired or been revoked. Docker sends it with every pull,
  and GHCR refuses the pull rather than ignore it. Forget it, as root:

  ```
  docker logout ghcr.io
  ```

  With no login left, the same error means a package is not public (any
  more): an owner of the AIShie-Education organization sets it back to
  public in the package's settings.

- **`not found` or `manifest unknown`:** the channel in
  `/etc/aishie/aishie.env` (`CORE_IMAGE`, `RUNTIME_IMAGE`, `WEB_IMAGE`) names
  an image or a tag that is not published, or not yet: a release that is
  still building, or a typo. `docker pull` of it by hand says the same.
- **Anything else** (a timeout, `connection refused`, a TLS error): this
  server cannot reach ghcr.io (DNS, a firewall, a proxy), or GHCR is having
  trouble ([githubstatus.com](https://www.githubstatus.com)).

Then `aishie-update` runs now instead of in five minutes.

## Other things

- **`another aishie-update … has held the lock`.** A deploy (or the nightly
  backup) is running, or a run was killed and its process lingers:
  `journalctl -u aishie-update -u aishie-backup`, and `ps -ef | grep
  aishie`.
- **`CORE_IMAGE refused`.** The channel in `aishie.env` is not an image of
  its repository, or, on stable, not a release (`X.Y.Z`) nor a digest.
- **`PostgreSQL is not up and healthy`.** `aishie logs postgres`. A full disk
  is the usual cause: `df -h /var/lib/docker /var/backups`.
- **`the backup of the database … failed`.** Nothing was changed, and the
  next run tries again. Usually the disk is full.
- **The runtime's `check` refused the configuration.** The new version does
  not accept the agents' YAML as it is. `aishie runtime check` shows why with
  the running version; the journal has what the new one said. Fix the YAML
  (it must pass both), `aishie compose kill -s HUP runtime`, then
  `aishie-update --retry runtime`.
- **`the runtime was not given its credential for Core`** (from
  `setup-server.sh`), or `Core issued no credential` (from
  `aishie runtime-credential`). Core is not deployed yet, or runs a release
  from before migration 0025, which has no `agent_runtime` service: Core
  says `no site service "agent_runtime"`, or does not know `service` at
  all. Nothing was written, and nothing revoked. Once
  `aishie-update --status` shows Core on a release that has it:
  `aishie runtime-credential` (README.md, The runtime's credential for
  Core).
- **The runtime hosts nothing, and its log says Core refused its
  credential (401).** The credential in
  `/etc/aishie/runtime/secrets/core/agent_runtime` was revoked: by an
  administrator in the site, or a copy of `/etc/aishie` from before the
  last rotation was put back. `aishie runtime-credential` has Core issue
  another and recreates the runtime with it. Never edit or empty the file
  by hand: a run of `setup-server.sh` issues a new one into an empty file,
  but leaves anything else as it is.
- **An owner's own tool (Claude Desktop, say) stopped working with an
  agent's token after Core was updated.** Core's migration 0025 made the
  agent a runtime agent, hosted here alone, and revoked its other tokens.
  Nothing on the server brings them back: the owner makes an mcp agent for
  that tool, and issues it a token in the site (README.md, Core's migration
  0025).
- **Caddy has no certificate.** `aishie logs caddy`. The DNS name must
  resolve to this server, and 80 and 443 must be open to the internet (the
  provider's firewall; ufw does not matter for Docker's published ports).
- **An LMS cannot show AIshie in its frame.** The browser's console says the
  page refused to be framed. `curl -sI https://HOST/ | grep -i
  content-security-policy` shows what the web sends: the LMS's origin must
  be in it. `FRAME_ANCESTORS` in `aishie.env` must be in double quotes,
  `FRAME_ANCESTORS="'self' https://lms.example.edu"`: without them Docker
  cuts the value at the first single quote and the header says
  `frame-ancestors self`, which lets nothing frame the app. Then
  `aishie compose up -d web` (README.md, Frames).
- **In the LMS's frame, a sign-in does not hold.** The next page finds
  nobody signed in. Core's session cookie is a third-party cookie there:
  `COOKIE_SAMESITE=none` in `core.env`, then `aishie compose up -d core`.
  Safari, and every browser on iOS, refuses it whatever Core says; so may a
  browser whose owner turned third-party cookies off. There the app works
  in a tab of its own.
- **The web does not start after FRAME_ANCESTORS was changed.**
  `aishie logs web` has Caddy's error: a value on more than one line stops
  it. Fix the line in `aishie.env`, then `aishie compose up -d web`. While
  the value is wrong, every new web image fails its health check too and is
  rolled back to the one before, which fails the same way: the log says
  `which does not report healthy either`.
- **The single sign-on button does not show.**
  `curl -s 127.0.0.1:8080/v1/auth/methods` says what the sign-in page is
  told: `"sso": null` means no provider is offered: `OIDC_ISSUER` is not
  set in the `core.env` Core runs with (after an edit, `aishie compose up -d
  core`), and no provider of the site's is switched on (the front end says
  each one's status). The page may keep the old answer for a minute. A 404
  is a Core from before that route: the web image then shows no button
  until Core is updated.
- **A single sign-on provider cannot be set up from the site:
  `secrets_key_missing`.** `core.env` has no `SECRETS_KEY`, which seals the
  providers' client secrets, or has it with no value. Run `setup-server.sh`
  again, as in README.md, Day to day: it adds one to a `core.env` that has
  no `SECRETS_KEY` line, and recreates Core with it. A line with no value
  it leaves as it is, and says so: write a key there by hand
  (`openssl rand -base64 32`), then `aishie compose up -d core`. Either way,
  copy `/etc/aishie` off the server again.
- **A provider of the site's says `secret_unavailable`.** Its client secret
  was sealed with a key Core no longer holds: the old key removed before
  `aishie core secrets rewrap` had run, a database restored from before a
  rotation, or a `core.env` put back from a copy older than its
  `SECRETS_KEY`. Put the key that sealed it, from a copy of `/etc/aishie`,
  in `SECRETS_KEY_PREVIOUS`, then `aishie compose up -d core` and
  `aishie core secrets rewrap` (README.md, Rotating secrets). If no copy
  has it, an administrator gives the provider its client secret again from
  the front end.
- **Core does not start, and `aishie logs core` names `SECRETS_KEY` or
  `SECRETS_KEY_PREVIOUS`.** A key in `core.env` is not 32 bytes in base64,
  as `openssl rand -base64 32` makes it (one cut short when pasted, or one
  in hex), or `SECRETS_KEY_PREVIOUS` is there without `SECRETS_KEY`. Fix
  `core.env`, then `aishie compose up -d core`.
- **Uploads fail in the browser, and its console says CORS.** Core keeps
  its files in a bucket, and the bucket does not let the site upload:
  `aishie storage cors` says whether it has the rule the site needs, prints
  it, and says where to set it; `aishie storage cors --apply --ask-keys`
  sets it with keys that may (README.md, Where uploaded files are kept).
  The rule names `https://HOST`: after a change of host name it needs the
  new one.
- **Core does not start: `the S3 bucket is not reachable`** (in
  `aishie logs core`). Core asks the bucket for an object when it starts.
  `aishie storage check` reaches it with the keys in `core.env` and says
  why it refuses: keys deleted or mistyped, the wrong region, a bucket that
  is gone. Fix `core.env`, then `aishie compose up -d core`.
- **`aishie storage migrate` stopped.** Nothing was switched: `core.env`
  is as it was, and if it had stopped Core it started it again. Fix what it
  names and run it again; it copies only what is not there yet. `the two
  sides differ` on every file, with a bucket encrypted with SSE-KMS (whose
  ETags are not MD5s): run it with `--size-only`. `could not pull
  rclone/rclone`: Docker Hub limits pulls for a while; run it later.
- **`Core did not report healthy on the other side`** (from `aishie storage
  migrate`). `core.env` was put back and Core started on it: nothing was
  lost, and the files are on both sides. `aishie logs core` says why Core
  would not start on the other one.
- **`could not pull the newest postgres:18 and caddy:2`** (from
  `setup-server.sh`). Docker Hub limits how often a server may pull, and
  refused for a while (`429 Too Many Requests`). The set-up goes on with
  the images the server has; run it again later for the newest ones.
