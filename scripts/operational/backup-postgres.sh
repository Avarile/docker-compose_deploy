#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Live logical backup of every database on the shared `pgvector` service —
# one pg_dump (custom format) per database, plus a globals-only dump for
# roles/grants. pg_dump takes an MVCC snapshot, so this runs safely with the
# stack up, no `make down` needed. Databases are discovered dynamically
# (pg_database), so new apps' databases get picked up automatically.
#
# This complements, not replaces, the cold `rsync ./data/` backup documented
# in README.md #9 — that one is for full-host disaster recovery, this one is
# for point-in-time / single-database restore.
#
# Usage:
#   ./scripts/operational/backup-postgres.sh
#
# Env overrides:
#   BACKUP_ROOT      where dumps land (default: ${DATA_ROOT}/backups/postgres)
#   RETENTION_DAYS   delete dump dirs older than this (default: 14, 0 = keep all)
#
# Restore a single database:
#   gunzip -c globals.sql.gz | docker compose exec -T pgvector psql -U "$POSTGRES_USER" -d postgres
#   cat <db>.dump | docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" pgvector \
#     pg_restore -U "$POSTGRES_USER" -d <db> --clean --if-exists
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

set -a
source .env
source infra/.env
set +a

BACKUP_ROOT="${BACKUP_ROOT:-${DATA_ROOT}/backups/postgres}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${BACKUP_ROOT}/${STAMP}"

CONTAINER="$(docker compose ps -q pgvector)"
[[ -n "$CONTAINER" ]] || { echo "ERROR: pgvector service is not running (docker compose up -d pgvector)" >&2; exit 1; }

mkdir -p "$OUT_DIR"
echo "== backing up postgres (pgvector) -> ${OUT_DIR}"

# globals: roles + role memberships (not captured by per-database dumps)
docker compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" pgvector \
  pg_dumpall -U "${POSTGRES_USER}" --globals-only | gzip >"${OUT_DIR}/globals.sql.gz"
echo "  globals.sql.gz"

# every real database (skip templates + the maintenance 'postgres' db)
databases="$(docker compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" pgvector \
  psql -U "${POSTGRES_USER}" -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres' ORDER BY datname")"

[[ -n "$databases" ]] || { echo "ERROR: no databases found on pgvector" >&2; exit 1; }

while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  echo "  ${db}.dump"
  docker compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" pgvector \
    pg_dump -U "${POSTGRES_USER}" -d "${db}" -Fc >"${OUT_DIR}/${db}.dump"
done <<<"$databases"

if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -print -exec rm -rf {} \; | sed 's/^/  pruned /'
fi

echo "== postgres backup complete: ${OUT_DIR} ($(du -sh "$OUT_DIR" | cut -f1))"
