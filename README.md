# rwcoder-infra

Deployment infrastructure for all apps, running on a single AWS Lightsail
instance behind Traefik (HTTPS + subdomain routing) with Watchtower
auto-updating containers as new images land on GHCR.

See [CLAUDE.md](CLAUDE.md) for the full architecture, conventions for
adding new apps, and rationale. This file is the operational runbook.

## Prerequisites

These are assumed to be done before anything in this repo is used. They're
one-time, host-level, and deliberately *not* automated here — this repo owns
how containers run, not how the box is built.

### 1. Lightsail instance (AWS console)

- Launch an **Ubuntu** instance (1 GB plan recommended; 512 MB works with the
  swap file configured below).
- Attach a **static IP**.
- In the instance's **Networking** tab, open **TCP 80** and **TCP 443** —
  they are not open by default, and Let's Encrypt's HTTP-01 challenge needs
  port 80 reachable from the internet.
- In your DNS provider, add an **A record** pointing at the static IP. A
  wildcard `*.<DOMAIN>` is strongly recommended so every new app subdomain
  (`books.`, `traefik.`, ...) resolves with no further DNS edits.

### 2. Docker Engine + Compose plugin

Install from Docker's official repository (the distro's `docker.io` package
is usually too old and ships no `compose` plugin):

```bash
# https://docs.docker.com/engine/install/ubuntu/
curl -fsSL https://get.docker.com | sh

# Run docker without sudo, then log out and back in for it to take effect
sudo usermod -aG docker "$USER"
newgrp docker

docker --version && docker compose version
```

### 3. Host tuning (log rotation + swap)

Both matter more than they look on a small shared VM — skipping them is how
this host falls over.

**Container log rotation.** Docker's default `json-file` driver never
rotates. On a ~20–40 GB SSD one chatty container eventually fills the disk
and takes every app down with it. Setting it at the daemon level means every
current and future container inherits it:

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

**Swap file (2 GB).** The riskiest moment on a 512 MB box is a Watchtower
update: pulling a new image while the old container is still running spikes
memory. Swap turns a would-be OOM-kill into a brief slowdown.
`vm.swappiness=10` keeps hot app pages in RAM and only leans on swap under
real pressure:

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

### 4. Shared Docker network

Every stack in this repo joins `traefik-public` as an **external** network,
so it has to exist before the first `docker compose up`:

```bash
docker network create traefik-public
```

## First-time deployment

With the prerequisites done, on the instance:

### 1. Get the repo onto the host

```bash
ssh ubuntu@<STATIC_IP>
git clone https://github.com/<owner>/rwcoder-infra.git
cd rwcoder-infra
```

### 2. (Only if using private GHCR images) log the host into GHCR

`book_reservation`'s GHCR package is private by default. Either make it
public (GitHub → repo → Packages → package settings → change visibility),
or authenticate the host:

```bash
echo <YOUR_GITHUB_PAT> | docker login ghcr.io -u <github-username> --password-stdin
```

Then uncomment the `~/.docker/config.json` mount in the `watchtower`
service in `docker-compose.yml` so Watchtower can pull private images too.

### 3. Configure the core stack (Traefik + Watchtower)

```bash
cp .env.example .env
nano .env            # set DOMAIN, ACME_EMAIL, TZ (leave others at defaults)

cp traefik/dashboard-users.htpasswd.example traefik/dashboard-users.htpasswd
docker run --rm httpd:alpine htpasswd -nbB admin 'your-strong-password' \
  >> traefik/dashboard-users.htpasswd
nano traefik/dashboard-users.htpasswd   # delete the commented example lines, keep only the real one
```

> **First time on a new domain?** Consider uncommenting `ACME_CASERVER` in
> `.env` to use Let's Encrypt **staging** for the first boot. Production has a
> limit of 5 failed validations per hostname per hour — a closed port 80 or a
> stale DNS record burns through it fast and then blocks you for an hour.
> Staging certs are untrusted in the browser (expected). To switch to real
> certs once staging issues cleanly:
>
> ```bash
> # comment ACME_CASERVER back out in .env, then discard the staging state
> docker compose exec traefik rm /letsencrypt/acme.json
> docker compose up -d --force-recreate traefik
> ```

### 4. Start the core stack

```bash
docker compose up -d
docker compose logs -f traefik      # watch for the ACME cert being issued; Ctrl-C to stop
```

Visit `https://traefik.<DOMAIN>` — you should get a browser padlock and a
basic-auth prompt (log in with the credentials from step 3). If the cert
looks untrusted for a minute, that's Let's Encrypt still issuing; give it
up to ~60s.

### 5. Configure and start the book-reservation app

```bash
cp apps/book-reservation/.env.example apps/book-reservation/.env
nano apps/book-reservation/.env     # set DOMAIN (same as core) and BOOK_RESERVATION_SECRET_KEY

# generate a secret key for that file:
python3 -c "import secrets; print(secrets.token_urlsafe(50))"

docker compose -f apps/book-reservation/docker-compose.yml up -d
```

### 6. First-run database setup (once per app)

```bash
docker compose -f apps/book-reservation/docker-compose.yml run --rm web \
  python manage.py migrate
docker compose -f apps/book-reservation/docker-compose.yml run --rm -it web \
  python manage.py createsuperuser
```

### 7. Verify

```bash
curl -sS https://books.<DOMAIN>/healthz     # -> {"status": "ok", "version": "..."}
docker ps                                    # traefik, watchtower, book-reservation all "Up (healthy)"
```

The app is now live at `https://books.<DOMAIN>`, dashboard at
`https://traefik.<DOMAIN>`.

### 8. Schedule data backups

App data (SQLite DBs, uploaded media) lives in named Docker volumes and is
not protected by anything else in this repo:

```bash
crontab -e
# daily at 03:15
15 3 * * * /home/ubuntu/rwcoder-infra/scripts/backup-volumes.sh 2>&1 | logger -t vol-backup
```

Archives land in `~/backups` (override with `BACKUP_DIR`) and are pruned
after 14 days (`RETENTION_DAYS`). They're on the *same disk* as the data —
copy them off-box for real durability.

## Day to day

- **New release?** Nothing to do. Each app's CI pushes `:latest` to GHCR;
  Watchtower pulls the new digest within `WATCHTOWER_POLL_INTERVAL` (default
  1 hour) and recreates the container.
- **Force an update now / roll to a pinned version:**
  `./scripts/deploy-app.sh book-reservation` (edit the app's `.env` first
  if pinning a `:vX.Y.Z` tag). `./scripts/deploy-app.sh --list` shows what's
  deployable.
- **Back up now:** `./scripts/backup-volumes.sh`
- **Restore a volume** (stop the app first):
  ```bash
  docker compose -f apps/book-reservation/docker-compose.yml down
  docker run --rm -v book-reservation-data:/data -v ~/backups:/backup alpine \
    sh -c 'rm -rf /data/* && tar xzf /backup/<archive>.tar.gz -C /data'
  docker compose -f apps/book-reservation/docker-compose.yml up -d
  ```
- **Add a new app:** copy `apps/_template/` and see "Conventions for adding a
  new app" in [CLAUDE.md](CLAUDE.md).
- **Tune shared middlewares** (compression, security headers, rate limits):
  edit `traefik/dynamic/middlewares.yml` — Traefik watches that directory and
  applies changes live, no restart.

## Troubleshooting

- **Cert not issued / TLS errors:** ports 80 **and** 443 must be open in the
  Lightsail firewall, and DNS must resolve to this box — the Let's Encrypt
  HTTP-01 challenge needs port 80 reachable. Check `docker compose logs traefik`.
- **Locked out by Let's Encrypt rate limits:** you get 5 failed validations
  per hostname per hour. Set `ACME_CASERVER` to the staging URL in `.env`,
  fix the underlying DNS/firewall problem, confirm staging issues a cert,
  then switch back.
- **App returns 404 from Traefik:** the app container must be on the
  `traefik-public` network and carry `traefik.enable=true`; router/service
  names must be unique across all apps.
- **Django "DisallowedHost" / CSRF errors:** `DOMAIN` in the app's `.env`
  must match the real host; the compose file derives `DJANGO_ALLOWED_HOSTS`
  and `DJANGO_CSRF_TRUSTED_ORIGINS` from it.
- **App never auto-updates:** check the opt-in label is exactly
  `com.centurylinklabs.watchtower.enable=true` — the namespace is
  `centurylinklabs`, and with `WATCHTOWER_LABEL_ENABLE=true` a typo means the
  container is silently skipped forever. Confirm with
  `docker inspect -f '{{ .Config.Labels }}' <container>` and
  `docker logs watchtower`.
- **Watchtower not updating a private image:** the host isn't logged into
  GHCR, or the `config.json` mount on the watchtower service is still
  commented out (step 2).
- **Unexpected 429s from an app:** the shared `rate-limit@file` middleware
  allows 50 req/s per client IP with a burst of 100. Raise it in
  `traefik/dynamic/middlewares.yml` if an app legitimately bursts.
- **`bad interpreter: no such file or directory` running a script:** the file
  has CRLF endings. `.gitattributes` forces LF; re-clone or run
  `dos2unix scripts/*.sh`.
