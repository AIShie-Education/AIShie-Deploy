# AIShie-Deploy

How an AIshie server runs: one Docker Compose stack per server, which the
server keeps up to date itself by pulling images from GitHub's registry.

The stack is five containers on one network:

| Service | Image | Listens |
| --- | --- | --- |
| `caddy` | `caddy:2` | 80 and 443 on every interface: HTTPS for the server's name |
| `core` | `ghcr.io/aishie-education/aishie-core` | 8080, published on 127.0.0.1 only |
| `runtime` | `ghcr.io/aishie-education/aishie-agent-runtime` | 9090 on 127.0.0.1 only; 9091 (its API, coming with M2) to Caddy |
| `web` | `ghcr.io/aishie-education/aishie-frontend` | 8080, published on 127.0.0.1:8081 only |
| `postgres` | `postgres:18` | 5432, on the stack's network alone |

Caddy sends `/v1/*`, `/mcp`, `/mcp/*` and `/healthz` to Core (not
compressed: MCP streams), `/runtime/api/*` to the runtime's API without the
browser's `Cookie` header, and everything else to the web front end. The
runtime's own `/healthz`, `/metrics` and `/status` are never routed.

Updates are pulled, not pushed: `aishie-update`, on a systemd timer every
five minutes, looks at the tag each service follows, and deploys a new image
by a safe sequence (a backup, the migrations, the switch, the health check,
and a rollback if it fails). An edge server, such as test.aishie.app,
follows `:edge`, the tip of each repository's `main` once its checks pass; a
stable one, a school's site, follows releases, changed by hand. No workflow of GitHub's reaches the server.

## What is where

In this repository, and where `setup-server.sh` puts it:

| Here | On the server | What |
| --- | --- | --- |
| `compose.yaml`, `stack.yaml` | `/opt/aishie/` | the stack; `compose.yaml` names the project and the two files it reads |
| `caddy/Caddyfile` | `/opt/aishie/caddy/` | Caddy's routes, for `HOST` |
| `postgres/initdb/10-aishie.sh` | `/opt/aishie/postgres/initdb/` | the two databases and their roles, made once |
| `env/*.env.example` | `/opt/aishie/env/` | every setting, explained |
| `examples/runtime/` | | a runtime document with [the school's AI plan](#the-schools-ai-plan), and a price table |
| `README.md`, `docs/` | `/opt/aishie/` | this, and [when something goes wrong](docs/troubleshooting.md) |
| | `/etc/aishie/aishie.env` | the operator's settings: `HOST`, `ENVIRONMENT`, the channels, the network |
| | `/etc/aishie/core.env`, `runtime.env`, `postgres.env` | each service's settings and secrets, root's (0600) |
| | `/etc/aishie/runtime/agents/` | the operator's agents' YAML, mounted read-only at `/config` |
| | `/etc/aishie/runtime/secrets/` | their secrets, `kek/v1`, and `core/agent_runtime`, [the runtime's credential for Core](#the-runtimes-credential-for-core); mounted read-only at `/secrets` |
| | `/var/lib/aishie/images.env` | what each service runs, by digest; `aishie-update` writes it |
| | `/srv/aishie/core/` | the files people upload to Core, when it keeps them on this disk ([Where uploaded files are kept](#where-uploaded-files-are-kept)) |
| | `/var/backups/aishie/` | the database backups |
| | `/var/log/aishie-update.log` | one line per update outcome |
| `bin/aishie-update` | `/usr/local/bin/` | the updater |
| `bin/aishie` | `/usr/local/bin/` | one-off commands, logs, backups |
| `bin/aishie-storage` | `/usr/local/bin/` | `aishie storage`: where Core keeps uploaded files, and moving them |
| `systemd/` | `/etc/systemd/system/` | `aishie-update.timer` (every 5 minutes), `aishie-backup.timer` (nightly) |
| `setup-server.sh` | | sets a server up, and updates the above on it |

## A new server

A fresh Ubuntu server, 24.04 or later, with 2 CPUs, 4 GB of memory and 40 GB
of disk to start with, and ports 80 and 443 open to the internet (the
provider's firewall; `setup-server.sh` opens them in ufw when ufw is on). It
keeps grades and students' work, so pick a provider and a region your
institution allows for that.

1. Give the server a copy of this repository, as root, in root's home:

   ```
   git clone https://github.com/AIShie-Education/AIShie-Deploy.git
   ```

   The repository and the three images are public: the server reads this
   repository, and pulls the images from ghcr.io, with no key, token or
   login of its own. `git -C AIShie-Deploy pull` takes a newer copy later
   (Day to day).

2. Run the set-up as root, with the server's DNS name and its environment:

   ```
   sh AIShie-Deploy/setup-server.sh test.aishie.app edge
   ```

   When someone is at the terminal, it first asks where Core keeps the
   files people upload: this server's disk (Enter), or a bucket of Amazon
   S3, Cloudflare R2, Backblaze B2 or another S3-compatible service, with
   its keys ([Where uploaded files are kept](#where-uploaded-files-are-kept)
   says how to choose, and the options for a run nobody answers). A bucket
   is checked with the keys before anything is written.

   It installs Docker Engine and the compose plugin if they are missing.
   On Ubuntu 24.04 that is Ubuntu's own `docker.io` and `docker-compose-v2`
   (compose 2.24 or later is needed); where Ubuntu's packages are older, or
   Docker's own `docker-ce` is installed already, it adds Docker's apt
   repository and installs `docker-ce` and `docker-compose-plugin` from
   there. It says which. It writes `/etc/aishie` with generated database
   passwords, `SIGNING_KEY`, `SECRETS_KEY` and the runtime's key
   (`kek/v1`); installs the stack, the scripts and the timers; starts
   PostgreSQL and Caddy; checks that the server can pull the three images;
   and runs the first update, which deploys Core, the runtime and the web in
   that order. Then Core, migrated, issues the runtime its credential for
   Core, which goes into `/etc/aishie` too, printed nowhere, and the runtime
   is recreated with it
   ([The runtime's credential for Core](#the-runtimes-credential-for-core)).
   It ends by printing what is left, which is what follows.

   If it stops, fix what it names and run it again: it never overwrites a
   setting, a secret or data.

3. Point the name at the server (an A record, and AAAA if it has IPv6).
   Caddy gets a certificate as soon as the name resolves there:
   `curl https://test.aishie.app/healthz`.

4. The first administrator: the account you sign in to the site with. It
   asks for a name, an email and a password (twice, not shown), makes the
   account, and restarts Core, so that its background jobs start as the
   system actor it makes too:

   ```
   aishie admin
   ```

   Then sign in at `https://test.aishie.app` with that email and password.
   People have no API tokens, the administrator included: only agents do.
   An mcp agent's owner issues its tokens in the site; a runtime agent's one
   token is issued to this server's runtime, and nobody sees it
   ([Hosting agents](#hosting-agents)). A Core from before that still
   makes one for the administrator at bootstrap; `aishie admin` does not
   show it, and nothing keeps it. The long form, for a script: the password
   on standard input to
   `aishie core bootstrap --name … --email … --password-stdin >/dev/null`
   (the `>/dev/null` for that token), then `aishie compose restart core`.

5. Copy `/etc/aishie` somewhere safe, apart from the database backups
   ([What to keep off the server](#what-to-keep-off-the-server)).

6. The day after, check that the nightly backup ran:
   `ls -l /var/backups/aishie/*-daily-*`.

For stable, the same with `stable`. Its channels start empty: set
each to a release in `/etc/aishie/aishie.env`, such as
`CORE_IMAGE=ghcr.io/aishie-education/aishie-core:1.2.3`, then run
`aishie-update`.

## How updates happen

`aishie-update.timer` runs `aishie-update` every five minutes (with up to a
minute's random delay; a run missed while the server was off happens at
boot). One run takes a lock, then, for Core, the runtime and the web in
that order:

1. It pulls the tag the service's channel names (`CORE_IMAGE`,
   `RUNTIME_IMAGE`, `WEB_IMAGE` in `aishie.env`) and reads the digest of that
   repository it names now.
2. The digest that runs already: nothing to do. A digest recorded as failed:
   nothing either, said once in the log, until the channel names another
   digest or someone runs `aishie-update --retry SERVICE`.
3. Anything else is deployed:
   - **Core:** the image must be of `ghcr.io/aishie-education/aishie-core`
     by name, and its `org.opencontainers.image.source` label must be
     AIShie-Core's repository. Its `version` gives the version and commit,
     and its `migrate version` where its migrations stop (see 4). The
     database `aishie_core` is dumped to
     `/var/backups/aishie/core-deploy-<UTC time>.dump` (written as `.part`,
     renamed once whole; the last ten kept). A dump that fails stops the run
     with nothing changed. `migrate up` and `seed` run in one-off
     containers of the new image. Core is recreated on it, and `/healthz`
     on 127.0.0.1:8080 must report status `ok` with the new version and
     commit within a minute.
   - **The runtime:** the same, with `aishie runtime check` of the agents'
     configuration, by the new image with the same mounts, before the
     backup; its own database `aishie_runtime`; `migrate up` and no seed;
     and its `/healthz` on 127.0.0.1:9090.
   - **The web:** the same checks of its name and label; recreated; its
     `/version.json` on 127.0.0.1:8081 must report the commit of its
     `org.opencontainers.image.revision` label.
4. A new version that does not report healthy is replaced by the one before
   it, which is waited for in turn, and its digest is recorded as failed.
   The version before can take over because the migrations went in before
   the switch and every migration leaves the release before it working
   (Core's and the runtime's `CONTRIBUTING.md`, Migrations), every one but
   Core's migration 0027. Nothing here ever migrates down. A Core whose
   migrations stop before 0027 does not work on a schema that has it, so
   `aishie-update` does not start one there: a new Core with 0027 that is
   not healthy is left running, and a Core from before it is refused
   ([Rolling back past Core's migration 0027](#rolling-back-past-cores-migration-0027)).
5. After a deploy, the images of the three repositories that no container
   uses are removed (by their source label), and no other image.

A run stops at the first failure; up to the recreate, the version that ran
goes on running. What runs is recorded by digest in
`/var/lib/aishie/images.env`, which `compose.yaml` reads: a reboot, or
`docker compose up -d` in `/opt/aishie`, starts the same images and follows
no tag. Each image is also pulled by its digest before it is deployed, so
it keeps a name on the server when its tag moves on (with Docker's
containerd image store it would lose it): a rollback to it, or a start
after a reboot, needs no registry. Every outcome is a line in
`/var/log/aishie-update.log` and in the journal. Secrets stay in the env
files, which only Docker reads.

On a fresh server there is no state yet, and the first run deploys all
three in order: Core's `migrate up` and `seed` make its schema.

## Day to day

As root on the server:

| | |
| --- | --- |
| `aishie-update --status` | per service: the image it runs, its channel, the last check and its result, failed digests, a pin |
| `aishie-update --dry-run` | what a run would do now, changing nothing |
| `aishie-update` | a run now, instead of in five minutes |
| `journalctl -u aishie-update` | every run, with each step's output |
| `aishie ps` | the stack's containers |
| `aishie logs core` | a service's log, followed (`runtime`, `web`, `caddy`, `postgres`) |
| `aishie core …` | Core's commands with the image that runs: `migrate version`, `token issue --actor AGENT_ID --label L --days 90` (an mcp agent's token), `secrets rewrap` ([Rotating secrets](#rotating-secrets)), `help` |
| `aishie runtime …` | the runtime's: `check --live`, `migrate version`, `help` |
| `aishie runtime-status` | the runtime's `/status`: agents, seats, spend (it answers its own loopback only, which is what this reaches) |
| `aishie runtime-credential` | the runtime's credential for Core issued anew, the ones before revoked, and the runtime recreated with it ([The runtime's credential for Core](#the-runtimes-credential-for-core)) |
| `aishie compose …` | `docker compose` for the stack, with its settings files |
| `aishie storage` | where Core keeps uploaded files; `check`, `cors`, and `migrate`, which moves them ([Where uploaded files are kept](#where-uploaded-files-are-kept)) |

`curl -s 127.0.0.1:8080/healthz`, `curl -s 127.0.0.1:9090/healthz` and
`curl -s 127.0.0.1:8081/version.json` say what each runs.

**Changing a setting:** edit the env file, then recreate that service with
the image it runs: `aishie compose up -d core` (or `runtime`, or `web` for
`FRAME_ANCESTORS`). A restart does not read the file again. Each file is one
`NAME=value` per line, with no `export` and no comment after a value.
Docker Compose reads them, not `docker run --env-file`, and that differs
from what Core's own docs say: Compose takes a value as written, spaces
included, but a `$` in it starts a variable, which Compose puts in its
place (and names in a warning). A value with a `$` in it, such as a
secret someone gives you, goes in single quotes, `'like$this'`, which
Compose takes as it is. `env/*.env.example` explains every setting; the
ones `stack.yaml` sets from `aishie.env` (`PUBLIC_URL`, `TRUSTED_PROXIES`,
`HTTP_ADDR`, `CORE_BASE_URL_ALLOWLIST`, …) win over the files.

**Updating this repository's files on the server** (the compose files,
`aishie-update`, `aishie`, the units; images update themselves): as root,
`git -C AIShie-Deploy pull`, then `sh AIShie-Deploy/setup-server.sh
<name> <environment>` again. It installs the new files and leaves the
settings, the secrets and the data as they are, with two exceptions: a
`core.env` from before `SECRETS_KEY` is given one, as a line at its end,
and nothing else in it changes ([Single sign-on](#single-sign-on)); and a
runtime with no credential for Core, its file missing or empty, is issued
one once Core runs
([The runtime's credential for Core](#the-runtimes-credential-for-core)).
It says so when it does: copy `/etc/aishie` off the server again then.

**Changing the host name:** `HOST` in `aishie.env`, then
`aishie compose up -d`: Core, the runtime and Caddy are recreated with the
new name, and Caddy gets a certificate for it.

## Rolling back

Edge rolls itself back: a new version that does not report healthy is
replaced by the one before (not past Core's migration 0027, below). By
hand, pin a service to an image, by digest or by tag, and it is deployed
by the same sequence (backup, `migrate up`, the switch, the health check):

```
aishie-update --pin core sha256:<digest>                  # the digest from the log or --status
aishie-update --pin core ghcr.io/aishie-education/aishie-core:1.2.2
```

A pinned service is left alone by the runs after, whatever its channel
says, until `aishie-update --unpin core`. The new schema stays, and the
release before works with it, but for Core's migration 0027; going back
further than one release means restoring a backup. Never run
`migrate down`: it deletes data. The one exception is going back past
Core's migration 0027, below.

### Rolling back past Core's migration 0027

Core's migration 0027 (AIShie-Core's PR #61) is the one migration that does
not leave the release before it working: it drops columns that release
reads and writes. A Core whose migrations stop before 0027, started on a
schema that has it, reports healthy (its `/healthz` asks only that the
schema be no older than its own) and fails every authenticated call that
reads an actor or a document's version. So `aishie-update` asks each
Core image `migrate version` before it runs it on the schema, and:

- **A new Core with 0027 that does not report healthy is not rolled back**
  to one from before it. It goes on running, nothing is recorded as
  failed, and the log says `not rolled back: sha256:…'s
  migrations stop at 26, before Core's migration 0027`. `aishie logs core`
  says why it is not healthy; once that is fixed (an env file, say),
  `aishie compose up -d core`. If it cannot be, go back by hand (below).
- **A Core whose migrations stop before 0027 is refused** on a schema that
  has it, whether pinned (`aishie-update --pin core` with the release
  before) or named by its channel (`CORE_IMAGE` on stable set back to the
  release before, or `:edge` once Core's `main` has gone back past 0027).
  It is refused before the backup: nothing is changed, the Core that runs
  goes on running, nothing is recorded as failed, and the log says
  `refused: sha256:…'s migrations stop at 26`. A pin stops there. A
  channel's Core is refused at every run, logged once, and the run goes on
  with the runtime and the web, as for a digest that failed before. Once
  the schema is migrated down, the same image goes ahead by itself. A
  schema left dirty at 27 by a failed `migrate up` does not have 0027:
  that is [A migration failed](docs/troubleshooting.md#a-migration-failed).
- **A new Core with 0027 whose seed fails** leaves the Core before it
  running, as any failed seed does, but on a schema that by then has 0027,
  where it does not work. The log says so, and the new digest is recorded
  as failed. Fix what the seed says and `aishie-update --retry core`, or go
  back by hand (below), naming the image with 0027.

Going back past 0027 is by hand, as root, as Core's `docs/deploying.md`
says for its own servers: stop Core, take the schema down one migration
with the image that has 0027 (the one that runs, which `aishie core` uses),
then deploy the release before. The Core with 0027 must not run on the
schema the down puts back (it fails to record or purge a version with
files), so the site is down from the stop until the release before is up,
which includes the backup `aishie-update` takes first:

```
aishie compose stop core
aishie core migrate down --yes      # says: schema version 26 (embedded latest 27)
aishie-update --pin core ghcr.io/aishie-education/aishie-core:<the release before>
```

On stable, setting `CORE_IMAGE` to the release before and `aishie-update`
does the last step instead of the pin. The down puts back what the release
before reads, from each version's files and each runtime agent's token,
but not the type and size of a purged version's file, which 0027 dropped.
Run nothing but this one `migrate down`: each further one deletes data. On
edge, `aishie-update --unpin core` follows `:edge` again once its cause is
fixed, and migrates up again.

After a failed seed, the Core that runs, which `aishie core` uses, is the
one before 0027 already, and its `migrate down` cannot take 0027 out (`no
migration found for version 27`). Name the image with 0027 for the down,
by the digest the log gives, then start the one before again, which
`aishie-update` left in place:

```
aishie compose stop core
CORE_REF=ghcr.io/aishie-education/aishie-core@sha256:<the digest with 0027> \
  docker compose --project-directory /opt/aishie -f /opt/aishie/compose.yaml \
  run --rm --no-deps -T core migrate down --yes
aishie compose up -d core
```

The digest with 0027 stays recorded as failed, so the runs after leave it
be; on stable, set `CORE_IMAGE` back to the release that runs.

## Upgrading stable

Stable follows releases. To upgrade, try the release on edge first
(edge runs `:edge`, which a release's commit has been), then set it in
the stable server's `/etc/aishie/aishie.env`:

```
CORE_IMAGE=ghcr.io/aishie-education/aishie-core:1.3.0
```

and run `aishie-update` (or wait five minutes). A channel on stable must be
a release, `X.Y.Z`, or a digest: `aishie-update` refuses `:edge`, `:1.3`,
`:latest` or `:stable` there, which move by themselves, so that an upgrade,
and the migrations that come with it, is somebody's decision. To go back,
set the release before and run `aishie-update`, or `aishie-update --pin`;
from the release with Core's migration 0027, migrate down first
([Rolling back past Core's migration 0027](#rolling-back-past-cores-migration-0027)).

## Renaming the settings

Edge and stable were called staging and production. A server set up before
the rename says `ENVIRONMENT=staging` (or `production`) in
`/etc/aishie/aishie.env`, and goes on as it did: `aishie-update` takes the
old names as `edge` and `stable` until a later release, which removes this,
and says so once in its log and in `--status`. `setup-server.sh` takes
`staging` and `production` as its argument too, with a notice, and writes
`edge` or `stable` into a new server's `aishie.env`; one that is there it
leaves as it is, and says what to change. To rename, as root, on each server
that says an old name, once this copy's `aishie-update` is there
(`setup-server.sh` run again, as in [Day to day](#day-to-day)): an older
one knows `production` alone, and would not hold a server that says
`stable` to releases.

```
sed -i 's/^ENVIRONMENT=staging$/ENVIRONMENT=edge/' /etc/aishie/aishie.env   # or production, stable
aishie-update --status                                                    # test.aishie.app (edge), and no notice
```

Nothing else changes: the channels (`:edge`, or the releases), what runs
and the data stay as they are, and nothing is restarted. This repository's
workflow deploys nothing and has no GitHub settings to rename; Core's, the
runtime's and the web front end's Deploy workflows do, and each of their
READMEs says how, under the same heading.

## Backups

- Before each deploy of Core or the runtime, `aishie-update` dumps its
  database: `/var/backups/aishie/core-deploy-<time>.dump` and
  `runtime-deploy-<time>.dump`, the last ten of each.
- Every night at about three, `aishie-backup.timer` runs `aishie backup`:
  `core-daily-N.dump` and `runtime-daily-N.dump`, N the day of the week, so
  seven of each. `aishie backup` takes one now.

Each is `pg_dump -Fc` in PostgreSQL's container, written as `.part` and
renamed once whole, root's alone.

**Restoring a backup.** Everything written after the backup is lost. Stop
the service, recreate its database from the dump, then run the image that
was running when the backup was taken (the log says which), pinned:

```
aishie compose stop core
aishie compose exec postgres dropdb -U postgres aishie_core
aishie compose exec postgres createdb -U postgres -O aishie_core aishie_core
aishie compose exec -T postgres pg_restore -U postgres --exit-on-error --no-owner --role=aishie_core -d aishie_core < /var/backups/aishie/<file>.dump
aishie-update --pin core sha256:<the digest from then>
aishie compose up -d core      # starts it again when that digest is the one deployed already
```

The runtime's is the same with `runtime` and `aishie_runtime`. Answers the
runtime had already posted to Core stay there; the runtime, missing their
attempts, may find their keys taken and move on to the next attempt.

## Hosting agents

Every agent in Core is hosted one way, chosen when it is made and never
changed afterwards:

- **Runtime** (站內託管): run by this server's agent runtime, and by nothing
  else. Its owner has the runtime host it from the site, choosing its model
  and key; the runtime asks Core whether that person owns that agent and
  whether it is a runtime agent, and is then issued the agent's one token,
  by the agent's id, which it keeps sealed and nobody sees. Owners no longer
  paste a token into the runtime, and hold none for a runtime agent: Core
  refuses to issue them one. People ask the agent in the site while the
  runtime hosts it.
- **MCP** (MCP 存取): used from its owner's own tools (Claude Desktop, an
  editor, a script) over MCP, with tokens the owner issues and revokes in
  the site (`aishie core token issue --actor ID --label L --days 90` does
  it from here). Nobody asks it in the site.

Only this site's own runtime hosts agents. Core has one `agent_runtime`
service for the site, whose credentials the operator issues here and the
site's root and administrators in the site, and nothing but a token issued
through it makes an agent answer in the site: a runtime set up elsewhere, a
school's own, say, cannot connect to the site and host agents there. An
agent used from elsewhere is an mcp agent, reached over MCP.

### The runtime's credential for Core

In Core the runtime is a site service, `agent_runtime`, as its transcriber
is `document_text`, and it calls Core with a credential of its own, an
`aissvc_…` token. With it, and with nothing else, it checks an agent's
owner and is issued and revokes the agents' tokens. Without it, or with one
Core has revoked, the runtime hosts nothing by agent id; revoking it does
not revoke the agents' tokens.

- **Made at setup.** Once Core runs, and so has migrated, `setup-server.sh`
  runs `aishie runtime-credential`: Core's
  `service issue agent_runtime --label runtime --replace`, in a one-off
  container of the image Core runs, whose standard output, the credential
  alone, goes straight into `/etc/aishie/runtime/secrets/core/agent_runtime`,
  0600, the runtime's user's (65532), in a directory of root's and the
  runtime's group's, mounted read-only at `/secrets`. The runtime reads it
  as `secret://core/agent_runtime` (`CORE_SERVICE_CREDENTIAL` in
  `runtime.env`, whose default that is). It is printed and logged nowhere:
  what is shown is Core's standard error, which credential it issued (its
  id and public prefix, as the site lists it) and how many it revoked. The
  runtime is then recreated, to take it.
- **Run again,** `setup-server.sh` leaves a file that is there as it is,
  and issues a new one only when the file is missing or empty, `--replace`
  revoking the one that was lost. With no Core deployed yet, or a Core from
  before migration 0025, which has no such service, it says so, and what is
  left has a step for `aishie runtime-credential`.
- **Kept with the other secrets,** in `/etc/aishie`: back it up with it
  ([What to keep off the server](#what-to-keep-off-the-server)). A lost one
  is no loss: issue another. A copy put back from before a rotation holds a
  credential Core has revoked, and needs `aishie runtime-credential` too.
- **Rotating it:** `aishie runtime-credential`, at any time. Core issues a
  new one and revokes the service's others, the file is replaced whole
  (never half written; a refusal leaves it as it was), and the runtime is
  recreated with it; the agents it hosts keep their tokens. Root and the
  platform's administrators see the service's credentials in the site
  (`service.list_credentials`) and may revoke one there; the runtime then
  hosts nothing until `aishie runtime-credential`.

### An operator's own agents

An agent the operator configures, rather than its owner in the site, is a
YAML file in `/etc/aishie/runtime/agents` (the runtime's
`docs/deploying.md` and `examples/` say what goes in it). It is a runtime
agent in Core, made with that hosting (in the site, or by an administrator,
whose `actor.register` of an agent names its hosting), and its YAML names
it by its `agent_id`, its actor id in Core, and holds no token: the runtime
is issued its token with its credential, as for every runtime agent. Each
secret the file refers to (a model's key, `secret://keys/tutor`, say) is a
file in `/etc/aishie/runtime/secrets` (`keys/tutor` there). Both are
root's, readable by group 65532, the runtime's user; the runtime cannot
write them.

```
install -g 65532 -m 640 tutor.yaml /etc/aishie/runtime/agents/
aishie runtime check --live
aishie compose kill -s HUP runtime
```

`check --live` loads the configuration as the runtime will, connects each
agent to Core and tries its model's key; `HUP` makes the runtime read its
configuration again. Its `core.base_url` is `https://HOST`, the only Core
the runtime here may connect to; inside the stack's network that name is
Caddy ([The network, and HOST inside it](#the-network-and-host-inside-it)),
so the agents reach Core without leaving the server. An agent's token file
from before (`/etc/aishie/runtime/secrets/agents/<name>/core_token`) is not
needed any more: remove it once the runtime hosts the agent by its id.

### Core's migration 0025: one hosting for each agent

When `aishie-update` deploys a Core with migration 0025, every agent is
given its hosting, for good:

- an agent whose runtime had it answer in the site, with a token still
  live, becomes a **runtime** agent. That token is taken as the runtime's,
  so people ask it as before, and **every other live token of the agent is
  revoked**: an owner's own tool connected to it (Claude Desktop, say) stops
  working, and needs an mcp agent of its own;
- every other agent becomes an **mcp** agent, its tokens as they were. One
  the runtime ran that did not answer in the site, such as an operator's
  YAML agent nobody owns, is not hosted here any more: make a runtime agent
  in its place, and name that one in the YAML.

The runtime needs its credential as soon as Core runs that release. On
edge, the timer deploys Core and then the runtime in one run: run
`setup-server.sh` again with this copy then
([Day to day](#day-to-day)), or `aishie runtime-credential`. On stable,
set Core's release first, `aishie-update`, `aishie runtime-credential`,
then the runtime's release that hosts by agent id, and `aishie-update`
again. That runtime issues each agent it hosts a token of its own on its
first start, which revokes the one it was handed before.

## The school's AI plan

The school may offer the people who host their agents here a model on its
own key, so that they need no API key of their own: the `school:` section
of the runtime's settings, a `runtime:` document in
`/etc/aishie/runtime/agents` (at most one there in all).
[`examples/runtime/runtime.yaml`](examples/runtime/runtime.yaml) is one to
start from; the runtime's `docs/deploying.md` (The school's AI plan) says
what each setting does. Without it, hosted agents run on their owners' own
keys alone.

Each offer's key is a file under `/etc/aishie/runtime/secrets/school/keys/`,
which its `key_ref: secret://school/keys/<name>` names, root's and readable
by group 65532, the runtime's user (`user: "65532:65532"` in
`stack.yaml`): the file `0640 root:65532`, the directories `school` and
`school/keys` `0750 root:65532`. The key never leaves the server: the
runtime reads it when it calls the model, and it is not stored in the
database, shown, audited or sent to a browser.

```
install -d -m 750 -g 65532 /etc/aishie/runtime/secrets/school /etc/aishie/runtime/secrets/school/keys
install -m 640 -g 65532 /dev/stdin /etc/aishie/runtime/secrets/school/keys/anthropic-main
    (paste the key, Enter, Ctrl-D)
install -g 65532 -m 640 runtime.yaml /etc/aishie/runtime/agents/
aishie runtime check --live
aishie compose kill -s HUP runtime
```

`check` lists the offers and the quotas; `HUP` puts them in force, and the
front end offers 「學校方案」 / "School plan" once the runtime's
`/runtime/api/v1/info` says `school_key: true`. The quotas count answers
from 00:00 UTC: per person across all of their agents (`per_owner_day`, 100
unless set), per person who asks (`per_asker_day`, 20 unless set), and,
optionally, across the school (`per_day`). A person may put their own key
behind the plan, which answers once their allowance is spent; without one,
the asker is told the school's allowance is used up for the day.

Quotas in dollars (`usd:`) need a price table that prices every offer, or
the runtime does not start. It goes in a subdirectory of the agents' (a
`.yaml` beside them would be read as an agent's):
`/etc/aishie/runtime/agents/prices/prices.yaml`, named by `prices_ref:
prices/prices.yaml` in the runtime document, or by
`PRICES=/config/prices/prices.yaml` in `runtime.env`
([`examples/runtime/prices/prices.yaml`](examples/runtime/prices/prices.yaml)).
Without one, costs are unknown and answers alone are counted.

The runtime's administrators (Core's root and admins, or those
`ADMIN_ACTOR_IDS` names) read today's use of the plan per person at
`https://HOST/runtime/api/v1/admin/school-plan/usage`.

## Where uploaded files are kept

Core keeps the files people upload (lecture notes, submissions, marked
work) in one of two places, chosen when the server is set up and moved
later with `aishie storage migrate`:

- **This server's disk** (`BLOB_STORE=fs`, the default): under
  `/srv/aishie/core/blobs`. Every upload and every download goes through
  the server, over its bandwidth, and the disk must grow with the files.
- **A bucket of an S3 service** (`BLOB_STORE=s3`): Core gives each browser
  a link it signs, good for minutes, and the browser uploads to the bucket
  and downloads from it directly. The bytes never pass through the server,
  so uploads and downloads go as fast as the bucket's region allows, and
  the server's disk holds none of them.

### Choosing a provider

| `--storage` | Service | What setup-server.sh asks for | Core's `S3_ENDPOINT` |
| --- | --- | --- | --- |
| `fs` | this server's disk | nothing | none |
| `aws` | Amazon S3 | region (any, of any partition), bucket, access key and secret | `s3.<region>.amazonaws.com` (`.com.cn` in China, the partition's own domain elsewhere) |
| `r2` | Cloudflare R2 | account ID, bucket, an R2 API token's access key and secret | `<account>.r2.cloudflarestorage.com`, region `auto` |
| `b2` | Backblaze B2 | region (from the bucket's endpoint, `s3.<region>.backblazeb2.com`), bucket, keyID and applicationKey | `s3.<region>.backblazeb2.com` |
| `s3` | another S3-compatible service | endpoint (`HOST[:PORT]`, HTTPS), region (`us-east-1` unless given), bucket, path-style (`yes`, `no`, or as Core's S3 client chooses), keys | as given |

**Near the people who use it.** Browsers talk to the bucket's region
directly, so what matters most is that it is close to them: for a school in
Hong Kong, AWS's `ap-east-1` (Hong Kong; an AWS account turns it on before
using it) or `ap-southeast-1` (Singapore), or an R2 bucket made with the
location hint Asia-Pacific. B2 picks its region when the account is made:
check that it is near your users. Core, on the server, reaches the bucket
too, when a file is attached (a copy and a delete in the bucket) and when
its sweep runs; signing a link needs no request. So a bucket far from the
server makes attaching a file a little slower, and nothing else.

**What it costs**, in a sentence each (each provider's pricing page has
the numbers, for the region):

- *This server's disk*: nothing beyond the server itself, but every byte
  up and down uses its bandwidth, and a bigger disk, and its backups, cost
  what the server's provider charges for them.
- *Amazon S3*: storage by the gigabyte-month, each request (uploads,
  downloads, lists), and data transferred out to the internet, which is
  every download people make.
- *Cloudflare R2*: storage by the gigabyte-month and each operation (writes
  and lists, reads), and nothing for data transferred out.
- *Backblaze B2*: storage by the gigabyte-month; downloads are free up to a
  multiple of what is stored, and charged beyond it; its pricing page says
  which API calls cost what.
- *Another service*: storage, requests and data out, each in its own way.

A move to a bucket costs one upload per file; a move back downloads what
the disk lacks (everything, once its copy is removed), which AWS charges
as data out.

**Limits of Core today.** The endpoint must be HTTPS: browsers upload
from the site's `https://` pages, and refuse to send to `http://`. A bucket
whose name has a dot is named in the path, since no certificate covers
`https://NA.ME.HOST`: setup-server.sh refuses one with `--s3-path-style
no`, and one at AWS in a region newer than the table of regions of Core's
S3 client (minio-go 7.3.0), whose requests Core sends to the region by a
means that takes no such name (`ST_AWS_CLIENT_REGIONS` in
`bin/aishie-storage`). A bucket without a dot works in any region.

**The Core it needs.** A service that takes only virtual-hosted requests
(`--s3-path-style no`, which core.env says to Core as
`S3_BUCKET_LOOKUP=dns`), and an AWS region newer than that table, need a
Core from its main since its PR #46 (merge d8f256c, 30 September 2026
UTC), which reads `S3_BUCKET_LOOKUP` and sends a request to `S3_REGION`
whatever its S3 client's table says; an older Core addresses the bucket
by its path, and sends a request for a region it does not know to
us-east-1, which refuses it. Such a Core names `S3_BUCKET_LOOKUP` in
`aishie core help`. setup-server.sh and `aishie storage migrate` check
that the Core the server runs is one before they change anything, and say
so when none is deployed yet: on edge the first update deploys one; on
stable, set `CORE_IMAGE` to such a release, as setup-server.sh's last
steps say (`docker run --rm IMAGE help` names `S3_BUCKET_LOOKUP`):
`aishie-update` does not check it, and an older Core fails its first
start. Any other bucket works with any Core.

### Setting it up

Asked when setup-server.sh runs at a terminal; for a run nobody answers,
options (before or after the name and environment) or their variables,
with the keys in the environment, where no command line, and no shell
history, has them (in bash, root's shell; or from wherever your automation
keeps secrets):

```
read -r AISHIE_S3_ACCESS_KEY; read -rs AISHIE_S3_SECRET_KEY; export AISHIE_S3_ACCESS_KEY AISHIE_S3_SECRET_KEY
sh AIShie-Deploy/setup-server.sh test.aishie.app edge --storage aws --s3-region ap-east-1 --s3-bucket aishie-files
sh AIShie-Deploy/setup-server.sh test.aishie.app edge --storage r2 --r2-account-id <32 hex digits> --s3-bucket aishie-files
sh AIShie-Deploy/setup-server.sh test.aishie.app edge --storage b2 --s3-region us-west-004 --s3-bucket aishie-files
sh AIShie-Deploy/setup-server.sh test.aishie.app edge --storage s3 --s3-endpoint s3.example.com --s3-region nl-ams --s3-bucket aishie-files
sh AIShie-Deploy/setup-server.sh test.aishie.app edge --storage s3 --s3-endpoint s3.example.com --s3-bucket aishie-files --s3-path-style no
```

With `--storage s3`, `--s3-path-style` says how a request names the
bucket, and core.env says it to Core in `S3_BUCKET_LOOKUP`: `yes` after the
endpoint (`path`, `https://HOST/BUCKET/KEY`); `no` in the host name
(`dns`, `https://BUCKET.HOST/KEY`), for a service that takes nothing else;
not given (Enter, when asked) as Core's S3 client chooses (`auto`: in the
host name at AWS, Google and Aliyun, after the endpoint anywhere else).
AWS, R2 and B2 are always `auto`. The check (and `aishie storage check`
later) and rclone, in a migration, name the bucket the same way.

The variables are `AISHIE_STORAGE`, `AISHIE_S3_BUCKET`, `AISHIE_S3_REGION`,
`AISHIE_S3_ENDPOINT`, `AISHIE_S3_PATH_STYLE`, `AISHIE_R2_ACCOUNT_ID` and
`AISHIE_R2_JURISDICTION` (`eu` or `fedramp`, for an R2 bucket in one).
With none of them, and nobody to answer, it is this server's disk, as
before. On a server set up already, `core.env` is left as it is, and
setup-server.sh says so when the options name another place:
`aishie storage migrate` moves the files.

The bucket is made beforehand, private (links Core signs need no public
access), with keys that may do what Core does and no more:

- *AWS*: an IAM user or role whose policy allows `s3:ListBucket` on
  `arn:aws:s3:::BUCKET`, and `s3:GetObject`, `s3:PutObject` and
  `s3:DeleteObject` on `arn:aws:s3:::BUCKET/*`; with `s3:GetBucketCORS` and
  `s3:PutBucketCORS` on the bucket as well, setup-server.sh sets the CORS
  rule itself. Outside the aws partition the ARNs name the region's:
  `arn:aws-cn:s3:::` in China, `arn:aws-us-gov:s3:::` in GovCloud,
  `arn:aws-eusc:s3:::` in the European Sovereign Cloud, and so on.
- *R2*: an R2 API token with Object Read & Write, for that bucket alone.
  The account ID is in the bucket's S3 API address,
  `https://<account>.r2.cloudflarestorage.com/<bucket>`.
- *B2*: an application key for that bucket alone, with read and write
  access. The bucket's page shows its endpoint, `s3.<region>.backblazeb2.com`.

**The check.** Before it writes anything, setup-server.sh reaches the
bucket with the keys, as Core will, by reading alone: it lists at most one
key and asks for an object that is not there (Core does the same when it
starts). A write-and-delete of a probe object would also prove that the
keys may write, but it can fail half way and leave the probe behind, and
in a bucket with versioning or object lock it leaves a version or a delete
marker that stays; reading cannot harm anything. The first upload, or
`aishie storage migrate`, shows that the keys may write. Refused keys, a
wrong region or a missing bucket stop the run with the service's own
reason (its code and message, not its whole answer, which names the key),
and nothing is written. `aishie storage check` does it again at any time.

**The keys** are never on a command line and never printed: curl reads
them on its standard input, rclone from a file of root's that is removed
when it ends, and `core.env` (0600, like the other env files) keeps them
for Core, a secret with a `$` in it in single quotes.

### The CORS rule

The site's pages upload to the bucket with a `PUT` carrying a
`Content-Type`, which the browser first asks the bucket about, and may
read from it with a `GET`; the bucket must allow the site's origin:

```
[
  {
    "AllowedOrigins": ["https://test.aishie.app"],
    "AllowedMethods": ["GET", "HEAD", "PUT"],
    "AllowedHeaders": ["content-type"],
    "MaxAgeSeconds": 3600
  }
]
```

setup-server.sh (and `aishie storage migrate`) sets it through the S3 API
(`PutBucketCors`, which R2 and B2 take too) when the bucket has no CORS
rules and the keys may set them. A bucket with rules of its own is left
alone, since that call replaces them all. Otherwise it prints the rule for
the site's `HOST`, and where to set it:

- *AWS console*: S3, Buckets, the bucket, Permissions, Cross-origin
  resource sharing (CORS), Edit: paste it (beside any rules there), Save
  changes.
- *Cloudflare dashboard*: R2 Object Storage, the bucket, Settings, CORS
  Policy, Add CORS policy: paste it in the JSON tab, Save.
- *Backblaze*: the web console's CORS settings are presets; this rule goes
  through the S3 API, with a key that may change the bucket (writeBuckets),
  such as the master application key, below.
- *Anywhere*: `aishie storage cors --apply --ask-keys` sets it with keys
  that may, typed when asked and not kept. `aishie storage cors` says
  whether the bucket has it.

Until it has it, uploads from the site fail in the browser (its console
says CORS). Downloads are links, which need no rule.

### Moving the files: `aishie storage migrate`

```
aishie storage migrate --to s3 --dry-run --storage aws --s3-region ap-east-1 --s3-bucket aishie-files
aishie storage migrate --to s3 --storage aws --s3-region ap-east-1 --s3-bucket aishie-files
```

with the keys in `AISHIE_S3_ACCESS_KEY` and `AISHIE_S3_SECRET_KEY`, or
typed when asked. The dry run checks the bucket, lists both sides and says
how many files there are, how many are in the bucket already, and how many
it would copy, and changes nothing. The move then:

1. checks the bucket, and sets or checks its CORS rule (it stops here,
   before copying, when the rule is missing and it cannot set it);
2. copies every file under the key Core reads it by: a file's path under
   `/data/blobs` is its object's key (`courses/<course>/<upload>`, and
   `attached/courses/…` after a move back), with the content type its
   `.meta` says; not the `.meta` files, nor a file without one (an upload
   or a delete that stopped half way, which Core does not serve);
3. checks every file on both sides, by size and by checksum (the MD5 of the
   bytes against the object's ETag), while Core runs;
4. takes aishie-update's lock, stops Core, copies what was uploaded
   meanwhile, and checks again: a few minutes in which the site is down;
5. writes `BLOB_STORE=s3` and the bucket's settings in `core.env`, keeping
   the one before as `core.env.before-storage-<time>`, and starts Core,
   which must report healthy within a minute; if it does not, `core.env` is
   put back and Core started on it again.

It copies with rclone 1.75.1 in its container (`rclone/rclone`, pinned by
digest in `bin/aishie-storage`), which is pulled the first time; nothing
is installed on the server. Stopped part way, or failing a check, it
changes nothing, starts Core again if it had stopped it, and goes on from
where it was when it is run again: it copies only what the bucket lacks.
For a bucket whose ETags are not MD5s (one encrypted with SSE-KMS, say),
`--size-only` checks sizes alone.

The disk keeps its copy, which nothing reads once Core is on the bucket:
remove it (`rm -r /srv/aishie/core/blobs`) when you are sure, or keep it
until then. `aishie storage` says where the files are, and how many the
disk holds.

### Going back

- *Core does not come up on the bucket*: the move puts `core.env` back by
  itself (above), and the disk still has every file.
- *Later*: `aishie storage migrate --to fs` (a `--dry-run` first) copies
  from the bucket what the disk lacks, which is what was uploaded since,
  writes each file's `.meta` as Core's disk store does (its size, its
  content type, its SHA-256), gives them to Core's user, checks both sides
  the same way, and switches `core.env` back to `BLOB_STORE=fs`, with the
  same stop, check and put-back. The bucket's settings stay in `core.env`,
  where Core reads them only with `BLOB_STORE=s3`, for a move there again,
  which then needs no options; the bucket keeps its objects until you
  empty it.
- *By hand*, only if nothing was uploaded since the move: copy
  `core.env.before-storage-<time>` over `core.env`, then
  `aishie compose up -d core`. A file uploaded to the bucket since would be
  missing from the disk: `migrate --to fs` is the way that loses nothing.

Files deleted while Core used the bucket are still in the disk's old copy
after a move back; nothing points at them, and Core's sweep removes those
under `courses/` in time.

## Single sign-on

Core signs people in through OpenID Connect identity providers of two
kinds (Core's README, Single sign-on). Register
`https://HOST/v1/auth/sso/callback` (HOST as in `aishie.env`) with each as
the redirect URI: it is the same for all of them.

**The site's providers** are set up, tested and switched on by root and
the platform's administrators from the front end; Core keeps them in its
database, and a change is in force at the next sign-in, with no restart.
Each provider's client secret is kept sealed there (AES-256-GCM) under
`SECRETS_KEY` in `/etc/aishie/core.env`: 32 random bytes in base64, which
`setup-server.sh` writes on a new server, and adds to a `core.env` from
before it when run again. Without it, Core sets up no provider
(`secrets_key_missing`), and the operator's works as before. What it
sealed opens with nothing else, so `SECRETS_KEY` is kept like
`SIGNING_KEY`, which Core needs beside it: copied off the server
([What to keep off the server](#what-to-keep-off-the-server)), never lost,
and never changed but by a rotation, with the old key kept until
everything is sealed again under the new one
([Rotating secrets](#rotating-secrets)). A provider whose secret no key of
Core's opens is not offered (`secret_unavailable`) until an administrator
gives it its secret again. A Core since its PR #62 reaches the site's
providers at public addresses only: a provider on the school's own network
(an ADFS whose name resolves to a `10.` address), or a server that reaches
the internet through a proxy, needs `SSO_ALLOW_PRIVATE_ISSUERS=true` in
`/etc/aishie/core.env` and `aishie compose up -d core`; until then
`sso.test` says why, and a sign-in through it fails
(`sso_provider_unavailable`, `aishie logs core` says why). Core's README,
Single sign-on, has the addresses it refuses. A Core from before that PR
reaches a provider wherever it is and does nothing with the setting, so it
can be set ahead of the upgrade.

**The operator's provider** is on exactly when `OIDC_ISSUER` is set in
`/etc/aishie/core.env`; administrators see it read-only. Set what the
identity provider gives you:

```
OIDC_ISSUER=https://adfs.example.edu/adfs
OIDC_CLIENT_ID=<the client's id>
OIDC_CLIENT_SECRET=<its secret, in single quotes if it has a $ in it>
OIDC_PROVIDER_NAME=school-adfs
OIDC_DISPLAY_NAME=School NetID
```

and `aishie compose up -d core`. `OIDC_PROVIDER_NAME` is the provider's
id, which every account linked to it is recorded under: give it one of your
own before anyone is linked, and never change it after, or nobody linked
can sign in. A server that has had single sign-on without it is on Core's
default, `polyu-adfs`, and keeps it: leave it unset there.
`OIDC_DISPLAY_NAME` is the provider's name on the sign-in page's button: at
most 64 printable characters, or Core refuses to start (`aishie logs core`
says why); unset, the page uses words of its own. `env/core.env.example`
has the rest (`OIDC_SUBJECT_CLAIM`, `OIDC_SCOPES`), and Core's README,
Single sign-on, what they do.

Nothing about single sign-on is built into the web image, which is the same
for every server. The sign-in page asks Core, at `GET /v1/auth/methods`,
which buttons to show and what each says:
`{"password": true, "sso": null}` without single sign-on,
`{"password": true, "sso": {"label": "School NetID", "start": "/v1/auth/sso/start"}}`
with it; a Core with the site's providers also lists, in `sso_providers`,
each one a sign-in may go through now, the operator's first. The route is
under `/v1`, which Caddy already sends to Core; it says nothing of a
provider but its id, its label and where a sign-in through it starts. A
browser may keep the answer for a minute, so a change reaches the sign-in
page within a minute of taking effect. (A Core from before that route
answers 404, and the page then shows no button.) To see what it says:
`curl -s 127.0.0.1:8080/v1/auth/methods`.

## Frames

Framing goes two ways, and this stack allows both.

- **AIshie showing another site in a frame**, such as a similarity
  checker's viewer (Turnitin's, say): nothing limits it. It is governed by
  the page's own `frame-src`, and neither the web image's header (only
  `frame-ancestors`) nor `index.html`'s policy (only `img-src`) sets it.
  Keep it that way for such a viewer to work.
- **Another site showing AIshie in a frame**, such as an LMS that opens it
  in an iframe (an LTI launch, say): governed by
  `Content-Security-Policy: frame-ancestors`, which only a header can set
  and which the web image sends with every answer. By default only
  AIshie's own pages may frame it, `frame-ancestors 'self'`. To let other
  sites, set `FRAME_ANCESTORS` in `/etc/aishie/aishie.env`, in double
  quotes, because CSP's keywords carry single quotes of their own (without
  the double quotes Docker cuts the value at the first one):

  ```
  FRAME_ANCESTORS="'self' https://canvas.example.edu"   # AIshie, and that LMS
  FRAME_ANCESTORS="'none'"                              # no page at all
  ```

  then `aishie compose up -d web`, and check what a browser is told:
  `curl -sI https://HOST/ | grep -i content-security-policy`. Unset or
  empty, it is `'self'`: `stack.yaml` always gives the web a value, because
  the image lets no page frame it when the variable is set but empty. A
  value Caddy cannot read (one on more than one line) stops the web from
  starting, and `aishie logs web` says why; until it is fixed, every new
  web image fails its health check and is rolled back. There is no
  `X-Frame-Options`: `frame-ancestors` supersedes it, and it cannot name
  another site.

  Inside another site's frame, Core's session cookie is a third-party
  cookie, which the browser sends only when it is `SameSite=None`: set
  `COOKIE_SAMESITE=none` in `core.env` too (`aishie compose up -d core`), or
  a sign-in inside the frame does not hold. Even then Safari, and every
  browser on iOS, refuses third-party cookies, as can people in other
  browsers; there AIshie works only in a tab of its own. Single sign-on
  inside a frame takes the frame to the provider's page, which most
  providers do not let be framed.

## Rotating secrets

- **The database passwords** are in `postgres.env` and in the
  `DATABASE_URL` of `core.env` (or `runtime.env`). PostgreSQL read them
  once, when its volume was made, so a new one is set in the database and in
  both files:

  ```
  aishie compose exec postgres psql -U postgres -c '\password aishie_core'   # asks for it twice, and logs nothing
  ```

  then write it in `AISHIE_CORE_DB_PASSWORD` in `postgres.env` and in
  `DATABASE_URL` in `core.env`, and `aishie compose up -d core`. Hex
  (`openssl rand -hex 24`) needs no escaping in the URL.
- **`SIGNING_KEY`** must not change in the normal course: every upload and
  download link Core has given out, and every single sign-on in progress,
  stops working. If it has leaked, change it anyway (`openssl rand -hex 32`
  in `core.env`, then `aishie compose up -d core`) and accept that.
- **`SECRETS_KEY`** seals the client secrets of the site's single sign-on
  providers, which open with nothing else: it is never simply replaced. A
  rotation, when a copy of it may have leaked, keeps the old key beside the
  new one until every secret is sealed again. In `core.env`, give
  `SECRETS_KEY` a new key and the old one to `SECRETS_KEY_PREVIOUS`:

  ```
  SECRETS_KEY=<a new one: openssl rand -base64 32>
  SECRETS_KEY_PREVIOUS=<the one SECRETS_KEY had>
  ```

  then:

  ```
  aishie compose up -d core      # Core seals with the new key, and opens with either
  aishie core secrets rewrap     # seals every client secret again, under the new key
  ```

  `secrets rewrap` says how many it sealed again. Once it has succeeded,
  remove the `SECRETS_KEY_PREVIOUS` line, `aishie compose up -d core`
  again, and copy `/etc/aishie` off the server again. If it fails, naming
  providers whose secrets open with neither key, put the key that sealed
  them in `SECRETS_KEY_PREVIOUS` too (several keys go comma separated),
  recreate Core and run it again, or give each its secret again from the
  front end. The database's backups from before the rotation hold secrets
  the old key sealed: keep that key, apart from them, for as long as they
  are kept, since restoring one needs it back in `SECRETS_KEY_PREVIOUS`
  and a `secrets rewrap`. A key that is not 32 bytes in base64 stops Core
  from starting, and `aishie logs core` says which.
- **The runtime's credential for Core**
  (`runtime/secrets/core/agent_runtime`): `aishie runtime-credential` has
  Core issue a new one and revoke the others, replaces the file whole, and
  recreates the runtime with it
  ([The runtime's credential for Core](#the-runtimes-credential-for-core)).
  Then copy `/etc/aishie` off the server again.
- **The runtime's key, `kek/v1`** (M2) wraps the secrets the runtime's API
  stores. It is never replaced in place: every file in `kek/` is kept for
  unwrapping, so a new key is added as `kek/v2`, `KMS_KEY_ID` in
  `runtime.env` points at it, the runtime rewraps its secrets
  (`aishie runtime keys rewrap`, once M2 has it), and only then is `v1`
  retired.
- **The bucket's keys** (`S3_ACCESS_KEY`, `S3_SECRET_KEY` in `core.env`):
  make a new key with the provider, write it in `core.env` (a secret with a
  `$` in single quotes), `aishie compose up -d core` and
  `aishie storage check`, then delete the old key. Upload and download
  links given out before, which the old key signed, stop working then;
  they last minutes.

## What to keep off the server

The backups above sit on the same disk as the database. Copy these
somewhere else, regularly:

- `/etc/aishie/`, encrypted: `SIGNING_KEY`, `SECRETS_KEY`, the runtime's
  key `runtime/secrets/kek/v1`, the database passwords, the runtime's
  credential for Core (`runtime/secrets/core/agent_runtime`), and the
  models' keys of the school's plan and of the operator's agents. No backup
  of the database can bring back `SIGNING_KEY`, `SECRETS_KEY` or the
  runtime's key; the credential, lost, is issued again
  (`aishie runtime-credential`). Without
  `SECRETS_KEY`, the client secrets of the site's single sign-on providers,
  which Core's database holds sealed with it, cannot be opened; without the
  runtime's key, the secrets the runtime stores cannot be read. Keep this
  copy apart from the database dumps: together, they are every secret the
  runtime holds, and every provider's client secret. Copy it again after a
  run of `setup-server.sh` that says it added `SECRETS_KEY` or issued the
  runtime its credential, and after a rotation.
- `/var/backups/aishie/`, the databases.
- `/srv/aishie/core/`, the files people upload, while Core keeps them on
  this disk. A bucket is kept by its provider, not by `aishie backup`:
  turn on its versioning (or replication), with a lifecycle rule that
  removes old versions after a while, since Core deletes objects in the
  normal course (an upload once it is attached, and uploads nothing
  attached).

## PostgreSQL's major version

`stack.yaml` pins PostgreSQL 18, the version Core's and the runtime's CI
test against, and nothing updates it: a new major version cannot read an
older one's files. A new minor version of 18 is
`aishie compose pull postgres && aishie compose up -d postgres`.

A new major version, when this repository moves to it, is a dump and a
restore, by hand, with everything stopped, and with the new copy of this
repository on the server:

```
systemctl stop aishie-update.timer
aishie compose stop core runtime web
aishie compose exec -T postgres pg_dumpall -U postgres > /var/backups/aishie/all-before-19.sql
aishie compose down                        # the containers; the volumes stay
docker run --rm -v aishie_postgres:/from:ro -v /var/backups/aishie:/to postgres:18 \
  tar -C /from -czf /to/postgres-18-volume.tgz .   # the old files, while the disk allows
docker volume rm aishie_postgres           # only with the dump in hand, and a copy of it elsewhere
install -m 644 AIShie-Deploy/stack.yaml /opt/aishie/   # the new copy's, which names the new version
aishie compose up -d --wait postgres       # empty, on the new version; the init script makes the roles and databases
aishie compose exec -T postgres psql -U postgres -d postgres < /var/backups/aishie/all-before-19.sql
aishie compose up -d
sh AIShie-Deploy/setup-server.sh <name> <environment>   # the rest of the new copy; it turns the timer on again
```

The restore says that the roles and the two databases exist already: the
init script made them, with the passwords in `postgres.env`, which the dump
sets again, and the rest goes into them. So the env files stay as they are.
setup-server.sh comes last: it turns the timer on, and nothing may deploy
to the empty database before the restore. Keep the dump, and the old
volume's files, until the new version has run for a while.

## The network, and HOST inside it

The stack's network has a subnet of its own, `AISHIE_SUBNET` in
`aishie.env` (172.30.83.0/24), and Caddy a fixed address in it,
`AISHIE_CADDY_IP` (172.30.83.10). That address is Core's
`TRUSTED_PROXIES`: Core takes a client's address from the
`X-Forwarded-For` of Caddy and of nothing else. If the subnet collides with
another network on the server, change both, then
`aishie compose down && aishie compose up -d`.

Caddy also has `HOST` as an alias on the network. Docker's embedded DNS
server, which every container on a user-defined network asks first, answers
a name that is a container's alias on that network with the container's
address, before it asks any DNS server outside. So the runtime, calling
Core at `https://HOST`, reaches Caddy directly, gets the same certificate a
browser gets, and does not go out to the server's public address and back
in (which some providers do not route). Checked with Docker 29.3.1
(compose 5.1.1, the containerd image store): from the runtime's own network
namespace, `HOST` resolves to Caddy's fixed address, and `https://HOST/healthz`
is answered by Core through Caddy, with a certificate that verifies for the
name. For a name that is an alias on the network, Docker's DNS answers an
IPv6 (AAAA) query itself, with no address, and does not pass it on (checked
with a public name that has one), so nothing tries the public address first
on this IPv4-only network. CI's end to end checks the first part on every
run (`tests/e2e.sh`, with `HOST=aishie.internal`).

## The runtime's API (M2)

The runtime's API is on its way (M2), and the stack is ready for it:
Caddy already routes `/runtime/api/*` to the runtime's port 9091, without
the `Cookie` header, and answers 502 until the runtime serves it;
`stack.yaml` already sets `API_ADDR=:9091`, `API_AUDIENCE`, `CORE_BASE_URL`
and `API_TRUSTED_PROXIES` for the runtime, and `RUNTIME_AUDIENCES` for Core;
`runtime.env` has `KMS_KEY_ID=local:/secrets/kek/v1`; and `setup-server.sh`
makes `kek/v1`. Until the images read them, nothing does.

## The images

The stack relies on each image doing the following:

- **Core** (`ghcr.io/aishie-education/aishie-core`): `serve` by default; the
  commands `migrate up`, `seed`, `version` (`vX.Y.Z (commit, date)`),
  `bootstrap`, `token issue`,
  `service issue agent_runtime --label L --replace` (from migration 0025),
  which prints the runtime's credential alone on standard output and
  nothing of it on standard error, and `secrets rewrap` for a rotation of
  `SECRETS_KEY`, which it reads with `SECRETS_KEY_PREVIOUS` from its env
  file; distroless, user 65532; `/healthz` answers
  JSON with `status`, `version` and `commit`; `GET /v1/auth/methods` says
  whether it offers single sign-on, and as what (a Core from before that
  route answers 404, and the sign-in page then offers none).
- **The runtime** (`ghcr.io/aishie-education/aishie-agent-runtime`): `run`
  by default; `check [--live]`, `migrate up`, `version`; user 65532;
  `/healthz` on `HTTP_ADDR` answers `status` `ok`, `version` and `commit`;
  it starts with no agent configured; it reads its credential for Core
  where `CORE_SERVICE_CREDENTIAL` says, `secret://core/agent_runtime` by
  default, and hosts agents by their ids with it.
- **The web** (`ghcr.io/aishie-education/aishie-frontend`): tags `:edge`
  (main's tip), `:sha-<7 hex>`, and `:X.Y.Z` and `:X.Y` from releases, with
  `:latest` and `:stable` on the highest stable one; the
  labels `org.opencontainers.image.source`
  (`https://github.com/AIShie-Education/AIShie-Frontend`), `.revision` (the
  full commit) and `.version`; Caddy as a static server on :8080, plain
  HTTP, as user 65532, writing nothing, so that `stack.yaml` runs it
  read-only with every capability dropped and no new privileges; serving
  the build: `/assets/*` immutable for a year and a 404 when missing,
  anything else `no-cache` with the app's `index.html` as the fallback,
  compressed; `Content-Security-Policy: frame-ancestors` on every answer,
  from `FRAME_ANCESTORS`, `'self'` while it is unset ([Frames](#frames));
  `GET /version.json` answers `{"version":"…","commit":"<7 hex>"}`
  (no-cache), the commit of its `sha-` tag, and is the image's own
  `HEALTHCHECK` (a `wget`). The build is the same for every server: the
  API is on the same origin, and single sign-on is Core's to say.

Each image's `org.opencontainers.image.source` label names its repository
under `https://github.com/AIShie-Education/`: `aishie-update` refuses an
image whose label names another, and prunes by it.

## Working on this repository

```
make ci        # shellcheck, actionlint, the tests, compose config, caddy validate
make test      # tests/*_test.sh: aishie-update, aishie, aishie-storage and setup-server.sh against stand-ins
make config    # docker compose config against env/*.example; caddy validate and Caddy's routes
make e2e       # the whole stack for real: as root, on a machine that can be thrown away
```

`make test` runs the scripts against stand-ins for docker, curl, flock,
apt and systemctl (`tests/fakes.sh`), which play a registry, a Docker,
the services' health checks, Core's `service issue`, an S3 service and
rclone's container, whose bucket is a directory; nothing reaches the
network. `make config` needs no Docker daemon for
compose; it validates the Caddyfile with a `caddy` on `PATH` (or `CADDY`),
else with Caddy's image, and checks the routes Caddy reads from it.

`.github/workflows/ci.yml` runs the same, every day as well as on each
push, and an end to end (`tests/e2e.sh`) on a runner it then throws away:
`setup-server.sh aishie.internal edge`, as root, with the real `:edge`
images, then, through Caddy with its local certificate authority, that
`/healthz` is Core's, `/` is the web's `index.html` with
`frame-ancestors 'self'`, `/v1/…` answers as Core (and
`/v1/auth/methods` says there is no single sign-on), the first
administrator can be made, sign in with their email and password, and
use the API with that session, as a bearer token and as the web's
cookie, `/runtime/api/` and no other
path reaches the runtime's 9090, nothing but Caddy is published beyond the
loopback, Core is given the `SECRETS_KEY` `setup-server.sh` wrote, the
runtime reaches Core at `https://HOST` through Caddy's alias, the runtime
is given its credential for Core (with a Core that has the
`agent_runtime` service), printed nowhere, which Core takes, and
`aishie runtime-credential` replaces it, Core refusing the one before,
the backups can be restored from, and a second `aishie-update` (and a
`docker compose up -d`, as after a reboot) changes nothing.
`aishie.internal`, not `localhost`: both get their certificate from Caddy's
local authority, but inside a container `localhost` is the container
itself, so the runtime's way to Core could not be checked with it.

The end to end pulls the three images as a server does, from ghcr.io, where
they are public packages, with no login. To run it elsewhere
against images of your own, `AISHIE_REGISTRY` names another registry, and
the `AISHIE_` paths at the top of each script move where it writes.

The scripts are POSIX sh, as the server runs them, and shellcheck-clean;
the tests are bash. Comments say what is true and why.
Examples, comments and tests name no real school: `school-adfs`,
`School NetID` and `example.edu` stand for one. Core's default provider id,
`polyu-adfs`, is named only where that default is described.

## License

AIshie Deploy is copyright 2026 XIE Hanming, and source-available under the [Elastic License 2.0](LICENSE) (ELv2), governed by the laws of Hong Kong. You may use, copy, change and redistribute it on the terms in LICENSE, which include that you may not offer it to others as a hosted or managed service.

For clarity: an educational institution that runs its own installation for its own staff and students is not providing the software to third parties as a hosted or managed service.

（補充說明：教育機構自行架設、供其教職員及學生使用，不視為向第三方提供託管服務。）
