#!/bin/sh
# Provision a dedicated MySQL database + user on the shared `mysql` service.
# Idempotent — safe to re-run. Mirrors the k3s ghost/gitea init-jobs.
#
# Env:
#   MYSQL_HOST           (default: mysql)
#   MYSQL_ROOT_PASSWORD  root password of the shared mysql
#   DB_NAME DB_USER DB_PASSWORD   the app database + its owner
set -eu

MYSQL_HOST="${MYSQL_HOST:-mysql}"

echo "waiting for mysql at ${MYSQL_HOST}..."
until mysqladmin ping -h "${MYSQL_HOST}" --silent 2>/dev/null; do sleep 2; done

export MYSQL_PWD="${MYSQL_ROOT_PASSWORD}"
mysql -h "${MYSQL_HOST}" -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
echo "mysql database '${DB_NAME}' ready"
