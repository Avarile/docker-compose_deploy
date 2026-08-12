#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Generate a fresh, independent set of real .env files for a NEW deployment,
# instead of hand-copying credentials from another host. Follows the
# CHANGE_ME_* / CHANGE_ME_equals_infra_<KEY> convention already used across
# every .env.example in this repo:
#
#   1. infra/.env.example: every CHANGE_ME_* value becomes one fresh
#      `openssl rand -hex 24` secret, written to infra/.env.
#   2. Each app's .env.example: CHANGE_ME_equals_infra_<KEY> tokens resolve to
#      the matching infra value from step 1; every other CHANGE_ME_* token
#      gets its own fresh secret (reused everywhere that exact token repeats
#      within the file, e.g. Plane's CHANGE_ME_plane_db_password appears 3x).
#
# Generated values are opaque random hex strings even for keys that read as
# "usernames" (POSTGRES_USER, MINIO_ROOT_USER, ...) — nothing depends on
# those being human-legible, they're just credentials wired through env vars.
#
# Refuses to overwrite an existing real .env unless run with --force.
#
# Usage:
#   ./scripts/generate-secrets.sh            # only fills in missing .env files
#   ./scripts/generate-secrets.sh --force    # regenerate every .env from scratch
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPS=(gitea ghost twenty cybernetics plane vaultwarden)

gen() { openssl rand -hex 24; }

write_env() {
  local target="$1" content="$2"
  if [[ -f "$target" && "$FORCE" -ne 1 ]]; then
    echo "skip: $target already exists (use --force to overwrite)"
    return 0
  fi
  printf '%s' "$content" >"$target"
  echo "wrote $target"
}

# ── 1. infra: every CHANGE_ME_* value becomes a fresh random secret ──
declare -A INFRA
infra_content=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=CHANGE_ME ]]; then
    key="${BASH_REMATCH[1]}"
    val="$(gen)"
    INFRA["$key"]="$val"
    line="${key}=${val}"
  fi
  infra_content+="${line}"$'\n'
done <infra/.env.example
write_env infra/.env "$infra_content"

# ── 2. each app: resolve equals_infra_* against INFRA[], generate the rest ──
for app in "${APPS[@]}"; do
  example="apps/${app}/.env.example"
  target="apps/${app}/.env"
  [[ -f "$example" ]] || continue

  content="$(cat "$example")"

  # unique CHANGE_ME_* tokens, longest first so no token is a substring of
  # one substituted before it
  tokens="$(grep -oE 'CHANGE_ME_[A-Za-z0-9_]*' "$example" | sort -u |
    awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)"

  while IFS= read -r token; do
    [[ -z "$token" ]] && continue
    if [[ "$token" =~ ^CHANGE_ME_equals_infra_(.+)$ ]]; then
      infra_key="${BASH_REMATCH[1]}"
      value="${INFRA[$infra_key]:-}"
      if [[ -z "$value" ]]; then
        echo "ERROR: $example references infra key '$infra_key', which infra/.env.example doesn't define" >&2
        exit 1
      fi
    else
      value="$(gen)"
    fi
    content="${content//$token/$value}"
  done <<<"$tokens"

  write_env "$target" "$content"
done

echo
echo "Done. Review infra/.env and each apps/*/.env, then: make bootstrap"
