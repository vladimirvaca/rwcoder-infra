# rwcoder-infra

Deployment infrastructure for all of `rwcoder.com`'s apps, running on a single
AWS Lightsail instance behind Traefik (HTTPS + subdomain routing) with
Watchtower auto-updating containers as new images land on GHCR.

See [CLAUDE.md](CLAUDE.md) for the architecture and the reasoning behind each
decision. **This file is the operational runbook** — what to type, in order.

## What runs where

| URL | What | Defined in |
|---|---|---|
| `https://traefik.rwcoder.com` | Traefik dashboard (basic auth) | `docker-compose.yml` |
| `https://books.rwcoder.com` | book-reservation app | `apps/book-reservation/` |
| — | Watchtower (no UI; polls GHCR hourly) | `docker-compose.yml` |

> **Heads-up on invisible files.** Almost every file you need to create here
> starts with a dot — `.env`, `.gitattributes` — and plain `ls` hides those.
> Use **`ls -a`**. `.env` and `traefik/dashboard-users.htpasswd` are also
> gitignored, so they won't appear in `git status` either. "I don't see it"
> is not evidence it's missing *or* that you created it — check with `ls -a`.

---

# Part 1 — One-time host setup

Done once per instance, before anything else in this repo. These steps are
host-level and deliberately not automated here: this repo owns *how containers
run*, not how the box is built.

## 1. Lightsail instance

- Launch an **Ubuntu** instance (1 GB plan recommended; 512 MB works with the
  swap file from step 4).
- Attach a **static IP**. Do this before configuring DNS — without it the
  address changes on stop/start and every DNS record goes stale.
- In the instance's **Networking** tab, open **TCP 80** and **TCP 443**.
  Neither is open by default.

Port 80 is not optional even though everything redirects to HTTPS — Let's
Encrypt's HTTP-01 challenge is served on it. Closing 80 breaks certificate
issuance *and* renewal.

## 2. DNS for rwcoder.com

Wherever `rwcoder.com`'s DNS is managed (your registrar, or a Lightsail DNS
zone if you delegated nameservers there), create:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `*` | `<your Lightsail static IP>` | 300 |
| A | `@` | `<your Lightsail static IP>` | 300 |

**The wildcard is the important one.** It's what makes every future app
zero-DNS-work: `traefik.rwcoder.com`, `books.rwcoder.com`, and anything you
add later all resolve through that single record. Adding an app never means
touching DNS again.

Three things that catch people:

- `*.rwcoder.com` does **not** cover the apex `rwcoder.com`. That's the
  separate `@` record, and you only need it if you want the bare domain to
  serve something. Skip it otherwise.
- A wildcard covers exactly **one** label. `books.rwcoder.com` ✓,
  `api.books.rwcoder.com` ✗ (that needs its own record).
- **Check for leftover records** for `traefik` or `books` — parking pages and
  old hosts often leave them behind. A specific record always beats the
  wildcard, so a stale one silently sends traffic somewhere else.

Use TTL 300 while setting up so mistakes are cheap to correct.

### Verify DNS before starting Traefik

Do this first. Nearly every confusing TLS failure traces back to skipping it:

```bash
dig +short traefik.rwcoder.com
dig +short books.rwcoder.com
# both must print your static IP, and nothing else
```

If they print nothing, wait for propagation — **do not start Traefik yet**.
Let's Encrypt allows only 5 failed validations per hostname per hour, and a
wrong DNS answer burns through them in minutes.

## 3. Docker Engine + Compose plugin

Install from Docker's official script (the distro's `docker.io` package is
usually too old and ships no `compose` plugin):

```bash
# https://docs.docker.com/engine/install/ubuntu/
curl -fsSL https://get.docker.com | sh

# Run docker without sudo, then log out and back in for it to take effect
sudo usermod -aG docker "$USER"
newgrp docker

docker --version && docker compose version
```

`docker compose version` (space, not hyphen) must work — everything here uses
Compose v2 syntax.

## 4. Host tuning (log rotation + swap)

Two separate measures with different urgency — don't treat them as one step:

| | Needed? | Why |
|---|---|---|
| **Log rotation** | **Yes, always** | Docker's default never rotates. Unbounded growth eventually fills the disk and takes the whole host down. |
| **Swap** | **Depends on your plan** | Required on 512 MB, cheap insurance on 1 GB, skippable at 2 GB+. |

### Log rotation — do this

Docker's default `json-file` driver never rotates.
On a ~20–40 GB SSD one chatty container eventually fills the disk and takes
every app down with it. Setting it at the daemon level means every current and
future container inherits it — no per-service `logging:` block needed:

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
sudo systemctl restart docker
```

There's a per-service `logging:` block alternative, but it has to be repeated
in every compose file and every future app will forget it. Daemon-level is
strictly better here.

### Swap — depends on your plan

Lightsail's Ubuntu images ship with **no swap at all**, so this is genuinely
absent unless you add it. Whether that matters:

- **512 MB plan — do it.** The per-container limits alone (Traefik 192M +
  Watchtower 128M + book-reservation 320M = 640M) already exceed the RAM.
  You're relying on apps not hitting their ceilings simultaneously, and swap
  is what keeps the moment they do from being an OOM-kill.
- **1 GB plan — recommended, cheap.** 640M of limits plus ~200M for Ubuntu
  leaves little headroom. The tightest moment is a Watchtower update: it
  pulls the new image while the old container is still serving, then swaps
  them. Not the double-memory spike it's sometimes described as, but real,
  and it happens unattended at 3am.
- **2 GB or larger — skip it.** You have genuine headroom; swap on a busy box
  can hurt latency more than it helps.

Cost either way is 2 GB of a 40 GB SSD, and `vm.swappiness=10` means it stays
unused until there's real pressure — hot app pages stay in RAM.

Check what you currently have:

```bash
free -h                          # "Swap:" row — 0B means none
grep MemTotal /proc/meminfo      # confirms your actual plan size
```

To add it:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

sudo sysctl -w vm.swappiness=10
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf

free -h    # confirm a 2.0Gi swap line
```

## 5. Shared Docker network

Every stack in this repo joins `traefik-public` as an **external** network, so
it must exist before the first `docker compose up`:

```bash
docker network create traefik-public
```

---

# Part 2 — First deployment

## 1. Get the repo onto the host

```bash
ssh ubuntu@<STATIC_IP>
git clone https://github.com/vladimirvaca/rwcoder-infra.git
cd rwcoder-infra
ls -a          # confirm .env.example is there (plain `ls` hides it)
```

If the repo is private, either use the SSH remote
(`git@github.com:vladimirvaca/rwcoder-infra.git`, needs a deploy key on the
box) or a PAT over HTTPS.

## 2. Configure the core stack

```bash
cp .env.example .env
nano .env
```

`DOMAIN=rwcoder.com` and `ACME_EMAIL` are already filled in. `TZ` and the
Watchtower interval can stay at their defaults.

**Strongly consider uncommenting `ACME_CASERVER`** (the staging line) for the
first boot. Your browser will warn the certificate is untrusted — that is
expected and correct. It means a DNS or firewall mistake costs you nothing
instead of a one-hour lockout from the real Let's Encrypt.

Then the dashboard password. **Traefik will not start without this file** —
it's a bind mount, so a missing file is a hard startup error, not a warning:

```bash
cp traefik/dashboard-users.htpasswd.example traefik/dashboard-users.htpasswd
docker run --rm httpd:alpine htpasswd -nbB admin 'your-strong-password' \
  >> traefik/dashboard-users.htpasswd
nano traefik/dashboard-users.htpasswd   # delete the commented example lines, keep only the real one
```

The credentials live in a mounted file rather than `.env` on purpose: a bcrypt
hash is full of literal `$`, and Compose's `${VAR}` interpolation silently
mangles it.

## 3. Start the core stack

```bash
docker compose up -d
docker compose logs -f traefik      # watch for the cert being issued; Ctrl-C to stop
```

Visit **https://traefik.rwcoder.com** — you should get a padlock and a
basic-auth prompt. If the certificate looks untrusted for a minute, that's
Let's Encrypt still issuing; give it ~60s.

### Switching from staging to real certificates

Once staging issues cleanly, comment `ACME_CASERVER` back out in `.env`, then
discard the staging state — Traefik won't replace a cert it thinks is still
valid:

```bash
docker compose exec traefik rm /letsencrypt/acme.json
docker compose up -d --force-recreate traefik
```

### How the certificates actually work

Worth understanding, because the naming misleads: **wildcard DNS does not give
you a wildcard certificate.** HTTP-01 can't issue those — that needs DNS-01
with registrar API credentials, which this setup deliberately avoids.

What happens instead is that Traefik requests a *separate* certificate per
hostname, on demand, the first time a router for that host is matched. So
`traefik.rwcoder.com` and `books.rwcoder.com` each get their own, issued and
renewed automatically, with no action from you. The wildcard DNS record exists
purely so the hostname *resolves*; the certificate side is per-host and
entirely independent of it.

## 4. (Only for private GHCR images) log the host into GHCR

`book_reservation`'s GHCR package is private by default. Either make it public
(GitHub → repo → Packages → package settings → change visibility), or
authenticate the host:

```bash
echo <YOUR_GITHUB_PAT> | docker login ghcr.io -u vladimirvaca --password-stdin
```

The PAT needs the `read:packages` scope. Then uncomment the
`~/.docker/config.json` mount on the `watchtower` service in
`docker-compose.yml` — the host login covers your manual `docker pull`, but
Watchtower runs in its own container and needs the credentials mounted in to
see new digests.

## 5. Start the book-reservation app

```bash
cp apps/book-reservation/.env.example apps/book-reservation/.env

# generate a secret key to paste into that file:
python3 -c "import secrets; print(secrets.token_urlsafe(50))"

nano apps/book-reservation/.env     # DOMAIN=rwcoder.com, BOOK_RESERVATION_SECRET_KEY
docker compose -f apps/book-reservation/docker-compose.yml up -d
```

## 6. First-run database setup (once per app)

```bash
docker compose -f apps/book-reservation/docker-compose.yml run --rm web \
  python manage.py migrate
docker compose -f apps/book-reservation/docker-compose.yml run --rm -it web \
  python manage.py createsuperuser
```

## 7. Verify

```bash
curl -sS https://books.rwcoder.com/healthz   # -> {"status": "ok", "version": "..."}
docker ps                                    # traefik, watchtower, book-reservation all "Up"
```

## 8. Schedule data backups

App data (SQLite DBs, uploaded media) lives in named Docker volumes and is not
protected by anything else in this repo:

```bash
crontab -e
# daily at 03:15
15 3 * * * /home/ubuntu/rwcoder-infra/scripts/backup-volumes.sh 2>&1 | logger -t vol-backup
```

Archives land in `~/backups` (override with `BACKUP_DIR`) and are pruned after
14 days (`RETENTION_DAYS`). They sit on the **same disk as the data they
protect** — that covers operator error, not instance loss. Copy them off-box
(S3, `rsync`) if the data matters.

---

# Part 3 — Adding a new app

**There is no DNS step.** The wildcard record from Part 1 already resolves any
subdomain you pick. Nothing about the core stack or the other apps changes
either — no restart, no downtime for anything already running.

## 1. Copy the template

```bash
cp -r apps/_template apps/my-app
```

Then in `apps/my-app/docker-compose.yml`, do the find/replace documented at
the top of that file:

| Replace | With | Example |
|---|---|---|
| `myapp` | short name — router, service and volume prefix | `blog` |
| `my-app` | folder + container name | `blog` |
| `sub` | the subdomain it answers on | `blog` → `blog.rwcoder.com` |

**The prefix rule matters more than it looks.** Router and service names are
*global* inside Traefik. Two apps both naming a router `web` will silently
collide and one will win, with no error logged anywhere. Prefixing by app name
is what keeps stacks independent.

## 2. Get three things right

1. **`loadbalancer.server.port`** — the port the app listens on *inside* the
   container. Nothing is published to the host; Traefik reaches it over the
   `traefik-public` network. This is the most common cause of a 502.
2. **`com.centurylinklabs.watchtower.enable=true`** — copy-paste it. The
   namespace is `centurylinklabs`, and a typo means the container is silently
   never auto-updated: no error, no log line, it just never happens.
3. **`deploy.resources.limits.memory`** — keep the sum across all apps under
   the instance's RAM with headroom. This is what stops one app OOM-ing
   Traefik and taking everything down with it.

Also give the app its **own named volume** for persistent data (never a
bind-mount into this repo) so its data survives `git pull`, container
recreates, and Watchtower updates.

## 3. Configure and deploy

```bash
cp apps/my-app/.env.example apps/my-app/.env
nano apps/my-app/.env      # DOMAIN=rwcoder.com (same as root), image, secrets

./scripts/deploy-app.sh my-app
# equivalent to: docker compose -f apps/my-app/docker-compose.yml up -d
```

`DOMAIN` is duplicated into every app's `.env` by design — each
`docker compose` invocation only auto-loads the `.env` sitting next to the
file it was given, so there's no inheriting it from the root.

## 4. Verify

```bash
curl -sSI https://my-app.rwcoder.com
docker ps                              # new container "Up"
docker compose -f apps/my-app/docker-compose.yml logs --tail=50
```

Once it's live, releases need no action: your app's CI pushes `:latest` to
GHCR, and Watchtower picks up the new digest within the hour.

---

# Day to day

- **New release?** Nothing to do. Each app's CI pushes `:latest` to GHCR;
  Watchtower pulls the new digest within `WATCHTOWER_POLL_INTERVAL` (default 1
  hour) and recreates the container.
- **Force an update now / roll to a pinned version:**
  `./scripts/deploy-app.sh book-reservation` (edit the app's `.env` first if
  pinning a `:vX.Y.Z` tag). `./scripts/deploy-app.sh --list` shows what's
  deployable.
- **Back up now:** `./scripts/backup-volumes.sh`
- **Restore a volume** (stop the app first):
  ```bash
  docker compose -f apps/book-reservation/docker-compose.yml down
  docker run --rm -v book-reservation-data:/data -v ~/backups:/backup alpine \
    sh -c 'rm -rf /data/* && tar xzf /backup/<archive>.tar.gz -C /data'
  docker compose -f apps/book-reservation/docker-compose.yml up -d
  ```
- **Tune shared middlewares** (compression, security headers, rate limits):
  edit `traefik/dynamic/middlewares.yml`. Traefik watches that directory and
  applies changes live — no restart, no downtime.
- **Stop an app:** `docker compose -f apps/<app>/docker-compose.yml down`
- **Update the infra itself** after changes land in this repo — see below.

> ⚠️ **Never add `-v` to `docker compose down`** unless you intend to destroy
> that app's data. `down` removes containers and keeps volumes; `down -v`
> deletes the named volumes too — for book-reservation that's the SQLite
> database and all uploaded media, gone. Restore from backup is the only way
> back.

## Updating the infra after a `git pull`

This is for changes to *this repo* (Traefik config, middlewares, compose
files). App **releases** need none of this — Watchtower handles those.

```bash
cd ~/rwcoder-infra
git status                    # check for local edits before pulling (see below)
git pull
```

### 1. Check whether local edits are in the way

`git pull` will refuse to overwrite locally-modified tracked files. Your
`.env` files and `traefik/dashboard-users.htpasswd` are gitignored, so they're
never at risk — but **if you uncommented the `~/.docker/config.json` mount on
the `watchtower` service** (Part 2, step 4), that's an edit to a tracked file
and the pull can conflict:

```bash
git stash               # set the local edit aside
git pull
git stash pop           # replay it; resolve conflicts if it reports any
```

### 2. Reconcile `.env` against `.env.example`

A pull can introduce new variables. `.env` is gitignored, so it will **not**
pick them up — the variable silently expands to empty instead. Compare the
variable names in both:

```bash
diff <(grep -oE '^[A-Z_]+=' .env.example | sort) \
     <(grep -oE '^[A-Z_]+=' .env | sort)
```

Anything showing as `<` exists only in the example and needs adding to `.env`.
Repeat per app: `diff` the same pair inside each `apps/<app>/`.

### 3. Apply the changes

Which command depends on what actually changed:

| Changed | What to run | Downtime |
|---|---|---|
| `traefik/dynamic/middlewares.yml` | nothing — Traefik watches that directory | none |
| root `docker-compose.yml` or `.env` | `docker compose up -d` | seconds, if Traefik is recreated |
| `apps/<app>/docker-compose.yml` or its `.env` | `docker compose -f apps/<app>/docker-compose.yml up -d` | seconds, that app only |
| scripts, CI, docs | nothing | none |

```bash
docker compose up -d      # core stack; recreates ONLY services whose config changed
```

**`docker compose up -d` only touches the core stack.** It has no idea the
`apps/` stacks exist — each is a separate Compose project. After a pull that
changed an app, you must run that app's file explicitly, or
`./scripts/deploy-app.sh <app>`.

Recreating Traefik drops in-flight connections for a second or two and all
apps 502 briefly. Nothing is lost — certificates live in a named volume, not
the container.

### 4. Verify

```bash
docker compose ps                            # core: both Up
docker compose logs --tail=30 traefik        # no config-parse errors
curl -sSI https://traefik.rwcoder.com        # expect 401 (auth prompt) — proves routing works
```

A Traefik config mistake shows up as the container restart-looping, or as
routers vanishing while the container stays up. `docker compose logs traefik`
names the offending line in both cases.

# Troubleshooting

- **Can't see `.env.example` (or any config file):** it's a dotfile — plain
  `ls` hides it. Use `ls -a`. Confirm what's tracked with `git ls-files`.
- **Cert not issued / TLS errors:** ports 80 **and** 443 must be open in the
  Lightsail firewall, and DNS must resolve to this box — the HTTP-01 challenge
  needs port 80 reachable from the internet. Check
  `docker compose logs traefik` and `dig +short <host>`.
- **Locked out by Let's Encrypt rate limits:** you get 5 failed validations
  per hostname per hour. Set `ACME_CASERVER` to the staging URL in `.env`, fix
  the underlying DNS/firewall problem, confirm staging issues a cert, then
  switch back.
- **Traefik container won't start at all:** most often
  `traefik/dashboard-users.htpasswd` doesn't exist. It's a bind mount, so
  Docker fails the container outright. Check `docker compose logs traefik`.
- **404 from Traefik:** the container must be on the `traefik-public` network
  *and* carry `traefik.enable=true`, and router/service names must be unique
  across all apps. `docker network inspect traefik-public` shows who's
  attached.
- **502 from Traefik:** the router matched but Traefik can't reach the app.
  Almost always `loadbalancer.server.port` doesn't match the port the app
  actually listens on inside the container.
- **Django "DisallowedHost" / CSRF errors:** `DOMAIN` in the app's `.env` must
  match the real host; the compose file derives `DJANGO_ALLOWED_HOSTS` and
  `DJANGO_CSRF_TRUSTED_ORIGINS` from it.
- **App never auto-updates:** check the label is exactly
  `com.centurylinklabs.watchtower.enable=true` — a typo in that namespace
  means the container is skipped forever, silently. Verify with
  `docker inspect -f '{{ .Config.Labels }}' <container>` and
  `docker logs watchtower`.
- **Watchtower not updating a private image:** the host isn't logged into
  GHCR, or the `config.json` mount on the watchtower service is still
  commented out (Part 2, step 4).
- **Unexpected 429s:** the shared `rate-limit@file` middleware allows 50 req/s
  per client IP, burst 100. Raise it in `traefik/dynamic/middlewares.yml`.
- **`bad interpreter: no such file or directory` running a script:** the file
  has CRLF endings. `.gitattributes` forces LF; re-clone, or run
  `dos2unix scripts/*.sh`.
- **Host feels wedged / apps OOM-killed:** check `free -h` (is swap active?)
  and `docker stats` against the per-container memory limits. `df -h` for disk
  — if it's full, verify `/etc/docker/daemon.json` log rotation from Part 1.
