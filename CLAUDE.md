# rwcoder-infra

## Purpose

This repo is the deployment infrastructure for all of `vladimirvaca`'s personal
apps, hosted together on a single **AWS Lightsail** VM. It is intentionally
separate from any individual app's repo — apps own their Dockerfile and CI
(build + push image to GHCR); this repo only owns *how those images get run
in production*.

Goals driving every decision here:

- **One entrypoint, many apps.** A single Traefik instance terminates HTTPS
  and routes to each app by subdomain (`books.example.com`,
  `nextapp.example.com`, ...). Apps don't publish ports directly.
- **Automatic HTTPS.** Traefik gets certificates from Let's Encrypt
  (HTTP-01 challenge) with zero manual cert management.
- **Apps update themselves.** Watchtower polls for new image digests on the
  tags already running and redeploys them — no SSH-and-`docker pull` per
  release. Each app's CI already pushes `latest` (and versioned tags) to
  GHCR on every merge/release; Watchtower is what turns that into a live
  deploy.
- **Apps are independent stacks.** Each app is its own Compose file/folder
  under `apps/`, deployable and restartable without touching the others.
  They only share the Traefik network and, by convention, environment
  variable naming.
- **Low resource footprint.** Target instance is a small Lightsail plan
  (e.g. 512MB–1GB RAM), so images/apps here are expected to be lean (this
  is why `book_reservation` uses SQLite + 2 gunicorn workers, not a
  separate DB server per app).

## Architecture

```
                         ┌─────────────────────────┐
  Internet (443/80) ───► │        traefik           │  core/docker-compose.yml
                         │  (TLS termination,       │
                         │   subdomain routing)      │
                         └───────────┬───────────────┘
                                     │ traefik-public (external docker network)
                     ┌───────────────┼───────────────────┐
                     ▼               ▼                    ▼
              book-reservation   next-app             watchtower
              apps/book-         apps/next-app/...    (core, polls all
              reservation/                             labeled containers,
                                                        pulls+recreates on
                                                        new image)
```

- **Core stack** (`docker-compose.yml` at repo root): Traefik + Watchtower.
  Deployed once per host. Owns the `traefik-public` Docker network and the
  Let's Encrypt certificate storage (named volume).
- **App stacks** (`apps/<app-name>/docker-compose.yml`): one per
  application, each declaring `traefik-public` as an **external** network
  and Traefik routing rules via container labels. `apps/book-reservation`
  is the first/reference implementation.
- Routing, TLS, and update policy are entirely **label-driven** — an app's
  own Dockerfile/image never needs to know about Traefik or Watchtower.

## Reverse proxy: Traefik

- Two entrypoints: `web` (80, redirects to 443) and `websecure` (443).
- Docker provider with `exposedByDefault=false` — only containers with
  `traefik.enable=true` are ever routed to. This means adding a new app is
  opt-in and safe by default.
- Certificate resolver `letsencrypt` uses the HTTP-01 challenge (no DNS
  provider API keys needed). Requires ports 80/443 open on the Lightsail
  firewall and DNS `A` records (ideally a wildcard `*.DOMAIN`) pointing at
  the instance's static IP.
- Shared dynamic middlewares (gzip compression, HSTS/security headers,
  per-IP rate limiting) live in `traefik/dynamic/middlewares.yml` and are
  opt-in per router via
  `...middlewares=compress@file,secure-headers@file,rate-limit@file`
  labels, so apps don't repeat that config. Traefik watches that directory
  (`providers.file.watch=true`), so edits apply live without a restart.
- `rate-limit@file` caps each client IP at 50 req/s (burst 100). On a
  single shared VM the goal isn't DDoS protection — that has to happen
  upstream — but preventing one scraper or login brute-forcer from
  starving every other app of CPU. Traefik is directly internet-facing, so
  the TCP peer address is the real client IP and the default
  `sourceCriterion` is correct as-is.
- The Traefik dashboard is exposed at `traefik.DOMAIN`, behind HTTP basic
  auth — never exposed unauthenticated. Credentials live in
  `traefik/dashboard-users.htpasswd` (a mounted file, gitignored, copied
  from `.htpasswd.example`), **not** a compose env var: a bcrypt hash is
  full of literal `$` characters, and routing that through `.env` →
  `${VAR}` interpolation is fragile — compose can re-parse those `$`
  sequences as (undefined) variable references and silently strip parts
  of the hash. A mounted file sidesteps the problem entirely.

## Auto-updates: Watchtower

- Runs in the core stack, polling on `WATCHTOWER_POLL_INTERVAL` (seconds,
  default 3600 = hourly). Hourly is deliberate: 5-minute polling means
  ~288 registry checks/day per image, needless CPU wakeups, and GHCR
  rate-limit exposure, for no real benefit on personal apps. Lower it only
  if you want near-immediate rollouts.
- `WATCHTOWER_LABEL_ENABLE=true` — Watchtower **only** manages containers
  explicitly labeled `com.centurylinklabs.watchtower.enable=true`. This is
  deliberate: Traefik and Watchtower itself are excluded, so infra
  components never restart themselves unexpectedly. Every app service
  must add that label to opt in.
- **The label namespace is `com.centurylinklabs`** (Watchtower's original
  authors at CenturyLink Labs) — not `centurylabs`. Getting it wrong fails
  *silently*: with label-scoping on, a mistyped label simply doesn't match,
  the container is skipped forever, and nothing logs an error. This repo
  shipped that exact typo, so `.github/workflows/validate.yml` now greps
  for it on every push.
- Watchtower's own image is **pinned**, not `:latest`. It is the one
  container with the power to restart every other container on the host,
  and nothing is watching *it* — an upstream regression arriving
  unannounced could take all the apps down. Bump it by hand.
- `WATCHTOWER_CLEANUP=true` removes stale images after a successful
  update, keeping a small disk footprint.
- This assumes apps redeploy via a **mutable tag** (`:latest`, or a
  `:stable` style tag) that CI re-pushes on release — Watchtower detects a
  new digest under the same tag and recreates the container. Pinning an
  app to an immutable version tag (`:v1.2.3`) opts it out of
  auto-updates until the tag in the app's `.env` is bumped manually.
- **Private GHCR images**: `book_reservation`'s GHCR package is private by
  default. Both the host's `docker pull` and Watchtower need registry
  auth to see new versions — see "Private images" below.

## Repo layout

```
rwcoder-infra/
├── CLAUDE.md                      # this file
├── README.md                      # human runbook (incl. host prerequisites)
├── .env.example                   # core stack config (DOMAIN, ACME_EMAIL, ...)
├── .gitattributes                 # forces LF — scripts are authored on Windows, run on Ubuntu
├── docker-compose.yml             # core stack: traefik + watchtower
├── .github/workflows/
│   └── validate.yml               # CI: compose/YAML parse, shellcheck, label check
├── traefik/
│   ├── dashboard-users.htpasswd.example  # basic-auth creds template for the dashboard
│   └── dynamic/
│       └── middlewares.yml        # shared middlewares (compress, secure headers, rate limit)
├── apps/
│   ├── _template/                 # copy this to start a new app stack
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   └── book-reservation/
│       ├── docker-compose.yml     # one service (web), joins traefik-public
│       └── .env.example
└── scripts/
    ├── deploy-app.sh              # pull/recreate helper for one app
    └── backup-volumes.sh          # tar app data volumes, prune old archives
```

Host setup (Docker install, log rotation, swap, the `traefik-public`
network) is a **documented prerequisite in README.md**, not a script. It is
one-time, machine-level, and mostly vendor/OS-specific — keeping it as prose
means the repo's scripts stay about *running apps*, and there's no
half-abandoned bootstrap script drifting out of sync with Docker's own
install docs.

## Conventions for adding a new app

1. Copy `apps/_template/` to `apps/<new-app>/` and do the find/replace
   documented at the top of its compose file. (`apps/book-reservation/` is
   the worked reference implementation if you'd rather copy a real one.)
2. Set the image to the app's GHCR path and pick a subdomain
   (`traefik.http.routers.<router>.rule=Host(\`<sub>.${DOMAIN}\`)`).
   Router/service names must be unique across the whole deployment (they're
   global inside Traefik), so prefix them with the app name.
3. Add `com.centurylinklabs.watchtower.enable=true` if the app should
   auto-update (almost always yes). Copy-paste it — a typo in that
   namespace silently disables updates forever.
4. Give the service its own **named volume** for persistent data (never
   bind-mount into this repo) and its own env vars, prefixed with the app
   name in `.env.example` to avoid collisions between apps.
5. Add the DNS record for the new subdomain (or rely on the wildcard).
6. Deploy with `docker compose -f apps/<new-app>/docker-compose.yml up -d`
   — no changes to the core stack or other apps needed.

## Environment / secrets handling

- Every `.env` is **gitignored**; every folder that needs one ships an
  `.env.example` that *is* committed, documenting every variable.
- `DOMAIN` must be identical across the root `.env` and every app's
  `.env` (each Compose invocation only auto-loads the `.env` in its own
  directory, so it's duplicated by design rather than shared implicitly).
- Django-style secret keys, basic-auth hashes, etc. are generated once on
  the host and never committed.

## Private images (GHCR)

`book_reservation` (and likely future apps) publish private packages to
`ghcr.io/vladimirvaca/...`. Either:

- make the package public (GitHub → repo → Packages → package settings →
  Change visibility), simplest for personal/non-sensitive apps, or
- `docker login ghcr.io` on the host with a PAT (`read:packages` scope)
  and bind-mount `~/.docker/config.json` into the Watchtower container
  (see `docker-compose.yml`) so it can also check/pull private images.

## Target host: AWS Lightsail

- Single Ubuntu instance. Host prep — Docker Engine + the Compose plugin,
  host-wide log rotation, a swap file (see "Performance & resource
  footprint"), and the `traefik-public` network — is a manual prerequisite
  documented in README.md.
- Open ports 80 and 443 in the Lightsail networking tab (firewall).
- Attach a static IP, point DNS at it (a wildcard `*.DOMAIN` A record
  avoids editing DNS every time a new app/subdomain is added).
- Deployment order matters: `docker network create traefik-public` →
  core stack up → app stacks up.

## Performance & resource footprint

The target is a small (512MB–1GB) single VM shared by several apps, so the
defaults here optimize for *not falling over* under memory/disk pressure
rather than raw throughput. The measures, and why:

- **Host-wide container log rotation** (`/etc/docker/daemon.json`, set
  during host prep: `json-file`, `max-size=10m`, `max-file=3`). Docker's default log
  driver never rotates; on a ~20–40GB SSD a chatty container will eventually
  fill the disk and take the whole host down. Setting it at the daemon level
  means every app inherits it — no per-service `logging:` block needed.
- **Swap file** (2GB, created during host prep, `vm.swappiness=10`).
  The riskiest moment on a 512MB box is a Watchtower update: pulling a new
  image while the old container is still running spikes memory. Swap turns
  a would-be OOM-kill into a brief slowdown. `swappiness=10` keeps hot app
  pages in RAM and only leans on swap under real pressure.
- **Per-container memory limits** (`deploy.resources.limits.memory`,
  honoured by Compose v2 outside swarm): Traefik 192M, Watchtower 128M,
  book-reservation 320M. These cap the blast radius so one app can't starve
  Traefik or the host; swap is the backstop that keeps a limit-hit from
  being fatal. Tuned for ~1GB — lower them on a 512MB plan, raise the app's
  if you increase gunicorn workers. Adjust per app in its own compose file.
- **Hourly Watchtower polling** (see Auto-updates) — fewer registry calls
  and CPU wakeups.
- **Traefik**: `sendAnonymousUsage=false`; access logs left **off** (they're
  disk-IO heavy and rarely worth it here); gzip `compress@file` middleware
  cuts response bytes over the wire for every app that opts in.
- **App-level** (in `book_reservation` itself, not this repo): gunicorn runs
  2 `preload_app` workers so the interpreter/module cache is shared
  copy-on-write, and static files are collected + compressed at image build
  time and served by WhiteNoise — no separate static server process.

If you upsize the instance, the levers to revisit are: raise the memory
limits, bump gunicorn workers to 4 (per that app's `gunicorn.conf.py`
note), and optionally shorten the Watchtower poll interval.

## Backups

`scripts/backup-volumes.sh` tars every app data volume to
`~/backups/<volume>-<timestamp>.tar.gz` and prunes archives older than 14
days. Run it from cron (see README "Schedule data backups").

- **Why it exists:** all app state lives in named Docker volumes, and
  nothing else here protects it. Watchtower recreates containers freely, a
  stray `docker volume rm` is unrecoverable, and Lightsail's instance
  snapshots are whole-disk — you can't restore one app's DB without rolling
  the entire box back.
- **Containers are paused for the duration of their own tar.** SQLite is
  the reason: copying a live DB file can catch it mid-write and produce a
  torn archive. Pausing freezes the process so the `.sqlite3` + `-wal` +
  `-shm` set is captured as a mutually consistent, recoverable snapshot.
  It costs seconds of downtime per app, and only that app.
- **Traefik's `letsencrypt` volume is excluded on purpose.** Certificates
  are re-issued free on demand, so archiving them is all downside — a stale
  `acme.json` restored later just confuses the resolver.
- Archives sit on the same disk as the data they protect. That covers
  operator error, not instance loss; copy them off-box (S3, `rsync`) if the
  data matters.

## Safety rails

Small changes here have host-wide blast radius, so a few cheap guards:

- `.github/workflows/validate.yml` parses every compose file and the
  Traefik dynamic YAML, shellchecks the scripts, and greps for the
  `com.centurylinklabs.watchtower.enable` label typo — all without needing
  a host, a domain, or a secret. The failure mode it targets is discovering
  a YAML error while SSH'd into production mid-deploy.
- `.gitattributes` forces LF endings. This repo is edited on Windows and
  every file in it executes on Ubuntu; a CRLF shebang fails as
  `bad interpreter: /usr/bin/env bash\r`, and stray `\r` also corrupts
  `.env` values and htpasswd hashes.
- `security_opt: no-new-privileges:true` on every service, so a compromised
  process can't gain privileges via setuid binaries.
- Healthchecks on Traefik (`--ping`) and book-reservation (`/healthz`) so
  `docker ps` distinguishes "running" from "actually serving". Note Compose
  outside swarm won't auto-restart an unhealthy container — this is for
  visibility and for Watchtower's post-update verification.

## Non-goals (for now)

- No orchestration beyond a single host (no Swarm/Kubernetes) — Lightsail
  is one VM, so plain Compose is enough.
- No off-box/offsite backup automation — `backup-volumes.sh` writes
  locally and leaves shipping archives elsewhere to the operator.
- No Docker socket proxy in front of Traefik/Watchtower. Both read
  `/var/run/docker.sock` directly (Traefik read-only); on a single-tenant
  personal VM the extra moving part isn't worth it.
- No per-app database containers yet — `book_reservation` uses SQLite on a
  local volume. Revisit (e.g. a shared Postgres app stack) if/when an app
  needs it.
- No secrets manager — env files on the host are the trust boundary,
  consistent with "one small personal VM."
