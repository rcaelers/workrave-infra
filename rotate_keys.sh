#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}" && pwd)"

gen_alnum() {
  local n="${1:-32}"
  ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n" )
}

# ── Snapshot current Rauthy ENC_KEYS before rotation ─────────────────────────

OLD_RAUTHY_ENC_KEYS=""
if [ -f "${REPO_ROOT}/apps/rauthy/overlays/home/rauthy-secrets.yaml" ]; then
  OLD_RAUTHY_ENC_KEYS=$(
    sops --decrypt "${REPO_ROOT}/apps/rauthy/overlays/home/rauthy-secrets.yaml" 2>/dev/null \
      | awk '/^ +ENC_KEYS:/{print $2}'
  )
fi

# ── Generate new secrets ──────────────────────────────────────────────────────

VALKEY_PASSWORD="$(gen_alnum 32)"

GARAGE_ACCESS_KEY="GK$(openssl rand -hex 16)"
GARAGE_SECRET_KEY="$(openssl rand -hex 32)"
GARAGE_RPC_SECRET="$(openssl rand -hex 32)"
GARAGE_METRICS_TOKEN="$(openssl rand -base64 32)"
GARAGE_ADMIN_TOKEN="$(openssl rand -base64 32)"

POCKETID_STATIC_API_KEY="$(gen_alnum 32)"
POCKETID_ENCRYPTION_KEY="$(openssl rand -base64 32)"
POCKETID_SECRET_ROTATION_ID="$(openssl rand -hex 16)"

SURREALDB_ROOT_PASSWORD="$(gen_alnum 32)"
SURREALDB_SECRET_ROTATION_ID="$(openssl rand -hex 16)"

RAUTHY_ENC_KEY_ID="$(openssl rand -hex 4)"
RAUTHY_ENC_KEY="$(openssl rand -base64 32 | tr -d '\n')"
# Prepend old keys so existing data remains decryptable after rotation
if [ -n "$OLD_RAUTHY_ENC_KEYS" ]; then
  RAUTHY_ENC_KEYS="${RAUTHY_ENC_KEY_ID}/${RAUTHY_ENC_KEY} ${OLD_RAUTHY_ENC_KEYS}"
else
  RAUTHY_ENC_KEYS="${RAUTHY_ENC_KEY_ID}/${RAUTHY_ENC_KEY}"
fi
RAUTHY_HQL_SECRET_RAFT="$(gen_alnum 32)"
RAUTHY_HQL_SECRET_API="$(gen_alnum 32)"
RAUTHY_BOOTSTRAP_API_KEY_SECRET="$(gen_alnum 64)"
RAUTHY_ADMIN_PASSWORD="$(gen_alnum 32)"
RAUTHY_BOOTSTRAP_API_KEY="$(printf '%s' \
  '{"name":"guardrail","exp":9999999999,"access":[' \
  '{"group":"Clients","access_rights":["read","create","update","delete"]},' \
  '{"group":"Users","access_rights":["read","create","update","delete"]},' \
  '{"group":"Secrets","access_rights":["read"]}' \
  ']}' \
  | base64 | tr -d '\n')"

RESEND_API_KEY="$(gen_alnum 32)"
# Extract only the base64 body (single line) from the Ed25519 PKCS8 PEM
JWK_PRIVATE_KEY_B64="$(openssl genpkey -algorithm Ed25519 2>/dev/null | grep -v '^-----' | tr -d '\n')"
# Derive the public key from the generated private key
JWK_PUBLIC_KEY_B64="$({
  echo '-----BEGIN PRIVATE KEY-----'
  echo "${JWK_PRIVATE_KEY_B64}"
  echo '-----END PRIVATE KEY-----'
} | openssl pkey -pubout 2>/dev/null | grep -v '^-----' | tr -d '\n')"

# ── Render template → encrypted SOPS file ────────────────────────────────────

render_and_encrypt() {
  local template="${REPO_ROOT}/$1"
  local output="${REPO_ROOT}/$2"

  sed \
    -e "s|%VALKEY_PASSWORD%|${VALKEY_PASSWORD}|g" \
    -e "s|%GARAGE_ACCESS_KEY%|${GARAGE_ACCESS_KEY}|g" \
    -e "s|%GARAGE_SECRET_KEY%|${GARAGE_SECRET_KEY}|g" \
    -e "s|%GARAGE_RPC_SECRET%|${GARAGE_RPC_SECRET}|g" \
    -e "s|%GARAGE_ADMIN_TOKEN%|${GARAGE_ADMIN_TOKEN}|g" \
    -e "s|%GARAGE_METRICS_TOKEN%|${GARAGE_METRICS_TOKEN}|g" \
    -e "s|%POCKETID_STATIC_API_KEY%|${POCKETID_STATIC_API_KEY}|g" \
    -e "s|%POCKETID_ENCRYPTION_KEY%|${POCKETID_ENCRYPTION_KEY}|g" \
    -e "s|%POCKETID_SECRET_ROTATION_ID%|${POCKETID_SECRET_ROTATION_ID}|g" \
    -e "s|%SURREALDB_ROOT_PASSWORD%|${SURREALDB_ROOT_PASSWORD}|g" \
    -e "s|%SURREALDB_SECRET_ROTATION_ID%|${SURREALDB_SECRET_ROTATION_ID}|g" \
    -e "s|%RESEND_API_KEY%|${RESEND_API_KEY}|g" \
    -e "s|%JWK_PRIVATE_KEY_B64%|${JWK_PRIVATE_KEY_B64}|g" \
    -e "s|%RAUTHY_ENC_KEYS%|${RAUTHY_ENC_KEYS}|g" \
    -e "s|%RAUTHY_ENC_KEY_ID%|${RAUTHY_ENC_KEY_ID}|g" \
    -e "s|%RAUTHY_HQL_SECRET_RAFT%|${RAUTHY_HQL_SECRET_RAFT}|g" \
    -e "s|%RAUTHY_HQL_SECRET_API%|${RAUTHY_HQL_SECRET_API}|g" \
    -e "s|%RAUTHY_BOOTSTRAP_API_KEY%|${RAUTHY_BOOTSTRAP_API_KEY}|g" \
    -e "s|%RAUTHY_BOOTSTRAP_API_KEY_SECRET%|${RAUTHY_BOOTSTRAP_API_KEY_SECRET}|g" \
    -e "s|%RAUTHY_ADMIN_PASSWORD%|${RAUTHY_ADMIN_PASSWORD}|g" \
        "$template" > "$output"

  sops --encrypt --in-place "$output"
  echo "  ✓ $2"
}

render_config() {
  local template="${REPO_ROOT}/$1"
  local output="${REPO_ROOT}/$2"

  sed \
    -e "s|%JWK_PUBLIC_KEY_B64%|${JWK_PUBLIC_KEY_B64}|g" \
    "$template" > "$output"

  echo "  ✓ $2"
}

# ── Render and encrypt all secret files ──────────────────────────────────────

echo "Rotating secrets..."

render_and_encrypt \
  apps/valkey/base/valkey-secrets-template.yaml \
  apps/valkey/base/valkey-secrets.yaml

render_and_encrypt \
  apps/garage/base/garage-secrets-template.yaml \
  apps/garage/base/garage-secrets.yaml

render_and_encrypt \
  apps/surrealdb/base/surrealdb-secrets-template.yaml \
  apps/surrealdb/base/surrealdb-secrets.yaml

render_and_encrypt \
  apps/pocket-id/base/pocket-id-secrets-template.yaml \
  apps/pocket-id/base/pocket-id-secrets.yaml

render_and_encrypt \
  apps/rauthy/overlays/home/rauthy-secrets-template.yaml \
  apps/rauthy/overlays/home/rauthy-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/overlays/home/05-provisioner-rauthy-secrets-template.yaml \
  apps/guardrail-config/overlays/home/05-provisioner-rauthy-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/base/02-valkey-secrets-template.yaml \
  apps/guardrail-config/base/02-valkey-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/base/03-object-storage-secrets-template.yaml \
  apps/guardrail-config/base/03-object-storage-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/base/04-auth-jwk-secrets-template.yaml \
  apps/guardrail-config/base/04-auth-jwk-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/base/05-provisioner-secrets-template.yaml \
  apps/guardrail-config/base/05-provisioner-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/base/06-database-secrets-template.yaml \
  apps/guardrail-config/base/06-database-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/base/07-email-secrets-template.yaml \
  apps/guardrail-config/base/07-email-secrets.yaml

render_config \
  apps/guardrail-config/base/01-database-template.yaml \
  apps/guardrail-config/base/01-database.yaml

echo "Done."
