#!/bin/sh
# Create a vhost + user with full permissions on the shared `rabbitmq` service
# via its management HTTP API. Idempotent. Mirrors the k3s plane-init-mq job.
#
# Env:
#   MQ_API       (default: http://rabbitmq:15672/api)
#   ADMIN_USER ADMIN_PASS   rabbitmq admin (mqadmin)
#   APP_USER APP_PASS       the app's dedicated user
#   VHOST        vhost to create (default: plane)
set -eu

MQ_API="${MQ_API:-http://rabbitmq:15672/api}"
VHOST="${VHOST:-plane}"

echo "waiting for rabbitmq management API at ${MQ_API}..."
until curl -fsS -u "${ADMIN_USER}:${ADMIN_PASS}" "${MQ_API}/overview" >/dev/null 2>&1; do sleep 2; done

AUTH="-u ${ADMIN_USER}:${ADMIN_PASS}"
curl -fsS $AUTH -X PUT "${MQ_API}/vhosts/${VHOST}"
curl -fsS $AUTH -X PUT "${MQ_API}/users/${APP_USER}" \
  -H 'content-type: application/json' \
  -d "{\"password\":\"${APP_PASS}\",\"tags\":\"\"}"
curl -fsS $AUTH -X PUT "${MQ_API}/permissions/${VHOST}/${APP_USER}" \
  -H 'content-type: application/json' \
  -d '{"configure":".*","write":".*","read":".*"}'
echo "rabbitmq vhost '${VHOST}' + user '${APP_USER}' ready"
