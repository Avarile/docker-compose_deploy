#!/bin/sh
# Create bucket(s) on the shared `minio` service. Idempotent.
# Runs in the minio/mc image. Mirrors the k3s *-init-minio jobs.
#
# Env:
#   MINIO_ENDPOINT  (default: http://minio:9000)
#   ACCESS_KEY SECRET_KEY   credentials (the minio root user by default)
#   BUCKETS         space-separated list of buckets to create
set -eu

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"

echo "waiting for minio at ${MINIO_ENDPOINT}..."
until mc alias set infra "${MINIO_ENDPOINT}" "${ACCESS_KEY}" "${SECRET_KEY}" >/dev/null 2>&1; do sleep 2; done

for b in ${BUCKETS}; do
  mc mb --ignore-existing "infra/${b}"
  echo "bucket '${b}' ready"
done
