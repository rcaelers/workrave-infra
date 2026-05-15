#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# ── Generate new secrets ──────────────────────────────────────────────────────

VALKEY_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"

GARAGE_ACCESS_KEY="GK$(openssl rand -hex 16)"
GARAGE_SECRET_KEY="$(openssl rand -hex 32)"
GARAGE_RPC_SECRET="$(openssl rand -hex 32)"
GARAGE_METRICS_TOKEN="$(openssl rand -base64 32)"
GARAGE_ADMIN_TOKEN="$(openssl rand -base64 32)"

POCKETID_STATIC_API_KEY="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
POCKETID_ENCRYPTION_KEY="$(openssl rand -base64 32)"

SURREALDB_ROOT_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"

OIDC_CLIENT_SECRET="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
RESEND_API_KEY="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
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
    -e "s|%SURREALDB_ROOT_PASSWORD%|${SURREALDB_ROOT_PASSWORD}|g" \
    -e "s|%OIDC_CLIENT_SECRET%|${OIDC_CLIENT_SECRET}|g" \
    -e "s|%RESEND_API_KEY%|${RESEND_API_KEY}|g" \
    -e "s|%JWK_PRIVATE_KEY_B64%|${JWK_PRIVATE_KEY_B64}|g" \
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
  apps/guardrail-config/base/02-valkey-secrets-template.yaml \
  apps/guardrail-config/base/02-valkey-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/base/03-object-storage-secrets-template.yaml \
  apps/guardrail-config/base/03-object-storage-secrets.yaml

render_and_encrypt \
  apps/guardrail-config/base/04-auth-oidc-secrets-template.yaml \
  apps/guardrail-config/base/04-auth-oidc-secrets.yaml

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
  apps/guardrail-config/overlays/home/01-config-template.yaml \
  apps/guardrail-config/overlays/home/01-config.yaml

render_config \
  apps/guardrail-config/overlays/production/01-config-template.yaml \
  apps/guardrail-config/overlays/production/01-config.yaml

echo "Done."



