#!/bin/sh
# Provision role(s) + database(s) on the shared `pgvector` service using the
# superuser credentials. Idempotent. Mirrors the k3s plane/twenty/cybernetics
# init-db jobs.
#
# Env:
#   PGHOST               (default: pgvector)
#   PGUSER PGPASSWORD    superuser (pgadmin)
#   NEW_ROLE             optional: login role to create
#   NEW_ROLE_PASSWORD    password for NEW_ROLE
#   NEW_DATABASES        space-separated list of databases to create
#   NEW_OWNER            optional owner for the databases (default: NEW_ROLE or PGUSER)
set -eu

export PGHOST="${PGHOST:-pgvector}"

echo "waiting for postgres at ${PGHOST}..."
until pg_isready -U "${PGUSER}" >/dev/null 2>&1; do sleep 2; done

OWNER="${NEW_OWNER:-${NEW_ROLE:-${PGUSER}}}"

if [ -n "${NEW_ROLE:-}" ]; then
  psql -v ON_ERROR_STOP=1 -d postgres <<SQL
SELECT 'CREATE ROLE ${NEW_ROLE} LOGIN PASSWORD ''${NEW_ROLE_PASSWORD}'''
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${NEW_ROLE}')\gexec
SQL
  echo "role '${NEW_ROLE}' ready"
fi

for db in ${NEW_DATABASES}; do
  psql -v ON_ERROR_STOP=1 -d postgres <<SQL
SELECT 'CREATE DATABASE ${db} OWNER ${OWNER}'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')\gexec
SQL
  echo "database '${db}' ready (owner ${OWNER})"
done
