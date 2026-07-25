#!/usr/bin/env bash
# Back up every Docker named volume belonging to an app stack to a timestamped
# tar.gz under $BACKUP_DIR, then prune archives older than $RETENTION_DAYS.
#
# Why this exists: app state here lives in named volumes (book-reservation's
# SQLite DB and media uploads, and whatever future apps add). Nothing else in
# this repo protects it — Watchtower recreates containers freely, and a
# `docker volume rm` or a lost instance is unrecoverable. Lightsail's own
# instance snapshots cover the whole disk, but they're coarse, cost extra, and
# can't restore one app's data without rolling back everything.
#
# Usage:
#   scripts/backup-volumes.sh                  # all app volumes
#   scripts/backup-volumes.sh book-reservation-data
#   BACKUP_DIR=/mnt/backups RETENTION_DAYS=30 scripts/backup-volumes.sh
#
# Restore (stop the app first):
#   docker run --rm -v <volume>:/data -v "$BACKUP_DIR":/backup alpine \
#     sh -c 'rm -rf /data/* && tar xzf /backup/<archive>.tar.gz -C /data'
#
# Cron it (daily 03:15, log to syslog):
#   15 3 * * * /home/ubuntu/rwcoder-infra/scripts/backup-volumes.sh 2>&1 | logger -t vol-backup

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-${HOME}/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
# Only volumes matching this are considered app data. Traefik's letsencrypt
# volume is excluded on purpose: certs are re-issued free on demand, so
# backing them up is pure downside (a stale acme.json restored later can
# confuse the resolver).
VOLUME_FILTER="${VOLUME_FILTER:-^(book-reservation|.*-data$)}"

timestamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [[ $# -gt 0 ]]; then
  volumes=("$@")
else
  mapfile -t volumes < <(docker volume ls --format '{{.Name}}' | grep -E "$VOLUME_FILTER" || true)
fi

if [[ ${#volumes[@]} -eq 0 ]]; then
  echo "No matching volumes found (filter: ${VOLUME_FILTER}). Nothing to do."
  exit 0
fi

# Containers are paused for the duration of their volume's tar. SQLite is the
# reason: copying a live DB can catch it mid-write and yield a torn file. Pause
# freezes the process so the .sqlite3 + -wal + -shm set is captured as a
# mutually consistent, recoverable snapshot. Each pause lasts seconds, and only
# affects the one app being archived.
pause_users_of() {
  docker ps --format '{{.Names}}' --filter "volume=$1"
}

failed=0
for vol in "${volumes[@]}"; do
  archive="${BACKUP_DIR}/${vol}-${timestamp}.tar.gz"
  echo "==> Backing up volume '${vol}' -> ${archive}"

  mapfile -t users < <(pause_users_of "$vol")
  for c in "${users[@]}"; do
    [[ -n "$c" ]] && docker pause "$c" >/dev/null && echo "    paused ${c}"
  done

  # Always unpause, even if the tar fails or the script is interrupted.
  unpause_all() {
    for c in "${users[@]}"; do
      [[ -n "$c" ]] && docker unpause "$c" >/dev/null 2>&1 && echo "    unpaused ${c}"
    done
  }
  trap unpause_all EXIT

  if docker run --rm \
      -v "${vol}:/data:ro" \
      -v "${BACKUP_DIR}:/backup" \
      alpine:3.20 \
      tar czf "/backup/$(basename "$archive")" -C /data . ; then
    echo "    ok ($(du -h "$archive" | cut -f1))"
  else
    echo "    FAILED to archive ${vol}" >&2
    failed=1
  fi

  unpause_all
  trap - EXIT

done

echo "==> Pruning archives older than ${RETENTION_DAYS} days in ${BACKUP_DIR}"
find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' -type f -mtime "+${RETENTION_DAYS}" -print -delete

# These archives live on the same disk as the data they protect — that covers
# "I deleted the volume", not "the instance died". Copy them off-box (S3, or
# `rsync` to another machine) for real durability.
echo "==> Done. Reminder: these archives are still on this instance only."
exit "$failed"
