#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Live logical backup of every database on the shared `mysql` service — one
# gzip'd mysqldump per database. --single-transaction gives a consistent
# InnoDB snapshot without locking tables, so this runs safely with the stack
# up, no `make down` needed. Databases are discovered dynamically (SHOW
# DATABASES minus the system schemas), so new apps' databases get picked up
# automatically.
#
# This complements, not replaces, the cold `rsync ./data/` backup documented
# in README.md #9 — that one is for full-host disaster recovery, this one is
# for point-in-time / single-database restore.
#
# Usage:
#   ./scripts/operational/backup-mysql.sh
#
# Env overrides:
#   BACKUP_ROOT      where dumps land (default: ${DATA_ROOT}/backups/mysql)
#   RETENTION_DAYS   delete dump dirs older than this (default: 14, 0 = keep all)
#
# Restore a single database:
#   gunzip -c <db>.sql.gz | docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
#     mysql -uroot <db>
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

set -a
source .env
source infra/.env
set +a

BACKUP_ROOT="${BACKUP_ROOT:-${DATA_ROOT}/backups/mysql}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${BACKUP_ROOT}/${STAMP}"

CONTAINER="$(docker compose ps -q mysql)"
[[ -n "$CONTAINER" ]] || { echo "ERROR: mysql service is not running (docker compose up -d mysql)" >&2; exit 1; }

mkdir -p "$OUT_DIR"
echo "== backing up mysql -> ${OUT_DIR}"

databases="$(docker compose exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql \
  mysql -uroot -N -e 'SHOW DATABASES' | grep -Ev '^(information_schema|mysql|performance_schema|sys)$')"

[[ -n "$databases" ]] || { echo "ERROR: no user databases found on mysql" >&2; exit 1; }

while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  echo "  ${db}.sql.gz"
  docker compose exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql \
    mysqldump -uroot --single-transaction --routines --triggers --events "${db}" \
    | gzip >"${OUT_DIR}/${db}.sql.gz"
done <<<"$databases"

if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -print -exec rm -rf {} \; | sed 's/^/  pruned /'
fi

echo "== mysql backup complete: ${OUT_DIR} ($(du -sh "$OUT_DIR" | cut -f1))"
