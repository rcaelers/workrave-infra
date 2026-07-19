#!/usr/bin/env bash
# Install/upgrade Flux CD on a cluster and point it at this repo.
#
# Idempotent: safe to re-run (flux bootstrap performs an upgrade if Flux is
# already present, and skips writing files that already match).
#
# Usage: scripts/flux-bootstrap.sh <home|production> <kube-context> [ssh-private-key-file]
set -euo pipefail

ENVIRONMENT="${1:?Usage: $0 <home|production> <kube-context> [ssh-private-key-file]}"
CONTEXT="${2:?Usage: $0 <home|production> <kube-context> [ssh-private-key-file]}"
SSH_KEY_FILE="${3:-}"

case "${ENVIRONMENT}" in
  home)
    GIT_URL="ssh://robc@k3s.home.krandor.org/srv/git/workrave-infra.git"
    GIT_BRANCH="staging"
    ;;
  production)
    GIT_URL="https://github.com/rcaelers/workrave-infra.git"
    GIT_BRANCH="main"
    ;;
  *)
    echo "Unknown environment '${ENVIRONMENT}' (expected 'home' or 'production')" >&2
    exit 1
    ;;
esac

FLUX_PATH="clusters/${ENVIRONMENT}"

if ! command -v flux >/dev/null 2>&1; then
  echo "==> flux CLI not found, installing via Homebrew"
  brew install fluxcd/tap/flux
fi

echo "==> flux CLI: $(flux --version)"

echo "==> Pre-flight checks on context '${CONTEXT}'"
flux check --context="${CONTEXT}" --pre

BOOTSTRAP_ARGS=(
  --context="${CONTEXT}"
  --url="${GIT_URL}"
  --branch="${GIT_BRANCH}"
  --path="${FLUX_PATH}"
  --silent
)

case "${GIT_URL}" in
  ssh://*)
    if [ -n "${SSH_KEY_FILE}" ]; then
      BOOTSTRAP_ARGS+=(--private-key-file="${SSH_KEY_FILE}")
    elif ! ssh-add -l >/dev/null 2>&1; then
      echo "WARNING: no keys loaded in ssh-agent and no ssh-private-key-file given." >&2
      echo "         flux bootstrap will likely fail to authenticate to ${GIT_URL}." >&2
      echo "         Re-run with the key explicitly: $0 ${ENVIRONMENT} ${CONTEXT} ~/.ssh/<key>" >&2
    fi
    ;;
  https://*)
    # Outbound SSH (port 22) from the cluster's pod network may be
    # blocked even when it works fine from this machine directly (this
    # bit us on hetzner: `flux bootstrap` cloning locally over SSH
    # worked, but the in-cluster source-controller hung forever on
    # "building artifact" trying to reach github.com over SSH). Use
    # HTTPS with a token instead, which only needs port 443.
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      BOOTSTRAP_ARGS+=(--username=git --password="$(gh auth token)")
    else
      echo "WARNING: gh CLI not authenticated; flux bootstrap will likely fail to" >&2
      echo "         authenticate to ${GIT_URL} over HTTPS (GitHub requires a token," >&2
      echo "         not a password). Run 'gh auth login' first." >&2
    fi
    ;;
esac

echo "==> Bootstrapping Flux on '${CONTEXT}' from ${GIT_URL} (${GIT_BRANCH}) at ${FLUX_PATH}"
flux bootstrap git "${BOOTSTRAP_ARGS[@]}"

echo "==> Waiting for the root Kustomization to reconcile"
flux --context="${CONTEXT}" reconcile kustomization flux-system --with-source --timeout=5m

echo "==> Bootstrap complete. Inspect status with:"
echo "      flux --context=${CONTEXT} get kustomizations -A"
echo "      flux --context=${CONTEXT} get helmreleases -A"
