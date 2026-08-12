#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time: publish the 3 custom-built images (not on any public registry) to
# the private Gitea registry, so a fresh host can `docker compose pull` them
# like every other image instead of needing a local `docker load`/build.
#
#   cybernetics                 — only in the live k3s node's containerd
#   cybernetics-project-web     — only in the live k3s node's containerd
#   main-website                — already in this host's Docker engine
#
# Run this ON THIS HOST (the k3s node). It needs:
#   - sudo, to read the k3s node's containerd image store
#   - the `registry-bot` Gitea account's push token (see
#     k3s-deployment/supports/25-image-registry/README.md) for `docker login`
#
# Usage: ./scripts/publish-custom-images.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REGISTRY=gitea.avarile.com
NAMESPACE=registry-bot
CYBERNETICS_REF="cybernetics:release.2026-06-10T04-05-13Z.1"
PLANE_WEB_REF="cybernetics-project-web:release.2026-07-29T12-56-03Z.1"
MAIN_WEBSITE_REF="main-website:latest"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "== 1/4: logging in to ${REGISTRY} as ${NAMESPACE} =="
echo "   (paste the registry-bot Personal Access Token when prompted)"
docker login "$REGISTRY" -u "$NAMESPACE"

echo "== 2/4: exporting images from k3s containerd that aren't in the Docker engine =="
for ref in "$CYBERNETICS_REF" "$PLANE_WEB_REF"; do
  if docker image inspect "$ref" >/dev/null 2>&1; then
    echo "   $ref already in Docker engine, skipping export"
    continue
  fi
  name="$(echo "$ref" | tr '/:' '__')"
  tarfile="${TMP_DIR}/${name}.tar"
  echo "   exporting $ref from k3s containerd (needs sudo)..."
  sudo k3s ctr -n k8s.io images export "$tarfile" "$ref"
  echo "   loading $ref into the Docker engine..."
  docker load -i "$tarfile"
done

echo "== 3/4: tagging for ${REGISTRY}/${NAMESPACE} =="
for ref in "$CYBERNETICS_REF" "$PLANE_WEB_REF" "$MAIN_WEBSITE_REF"; do
  docker tag "$ref" "${REGISTRY}/${NAMESPACE}/${ref}"
done

echo "== 4/4: pushing =="
for ref in "$CYBERNETICS_REF" "$PLANE_WEB_REF" "$MAIN_WEBSITE_REF"; do
  docker push "${REGISTRY}/${NAMESPACE}/${ref}"
done

echo
echo "Done. compose.yaml files already reference these as"
echo "  ${REGISTRY}/${NAMESPACE}/<name>:<tag>"
echo "so 'make pull' on any host logged in to ${REGISTRY} will now fetch them."
