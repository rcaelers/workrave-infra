#!/usr/bin/env bash
# Install/upgrade Flux and wait for the production application tiers.
# Usage: scripts/flux-bootstrap.sh production <kube-context> [sops-age-key-file]
set -euo pipefail

usage() {
  echo "Usage: $0 production <kube-context> [sops-age-key-file]" >&2
  exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || usage
ENVIRONMENT="$1"
CONTEXT="$2"
AGE_KEY_FILE="${3:-}"
BOOTSTRAP_TIMEOUT="${WORKRAVE_BOOTSTRAP_TIMEOUT:-30m}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "$ENVIRONMENT" != production ]]; then
  echo "Only production is supported; the home cluster and its Git server are retired." >&2
  exit 1
fi

for tool in flux kubectl gh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool. Install the prerequisites in docs/rebuild-production.md." >&2
    exit 1
  fi
done

# Match the version committed in Git, rather than upgrading to the CLI's default.
FLUX_VERSION="$(sed -n 's/^# Flux Version: //p' "$REPO_ROOT/clusters/production/flux-system/gotk-components.yaml")"
[[ -n "$FLUX_VERSION" ]] || { echo "Cannot determine the committed Flux version." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Authenticate GitHub first with gh auth login." >&2; exit 1; }

echo "==> Pre-flight checks on context '$CONTEXT' (Flux $FLUX_VERSION)"
flux check --context="$CONTEXT" --pre
KUBECTL=(kubectl --context="$CONTEXT")
"${KUBECTL[@]}" wait nodes --all --for=condition=Ready --timeout=2m
NODE_ARCHITECTURES="$("${KUBECTL[@]}" get nodes -o 'jsonpath={range .items[*]}{.status.nodeInfo.architecture}{" "}{end}')"
if [[ ! "$NODE_ARCHITECTURES" =~ ^(amd64[[:space:]]*)+$ ]]; then
  echo "This stack requires amd64 nodes for the Garage image; found '$NODE_ARCHITECTURES'." >&2
  exit 1
fi
"${KUBECTL[@]}" get storageclass local-path >/dev/null

TRAEFIK="$("${KUBECTL[@]}" get deployment traefik -n kube-system -o name --ignore-not-found)"
TRAEFIK_CHART="$("${KUBECTL[@]}" get helmchart traefik -n kube-system -o name --ignore-not-found)"
if [[ -n "$TRAEFIK$TRAEFIK_CHART" ]]; then
  echo "Disable k3s Traefik and ServiceLB first; Envoy needs host ports 80/443." >&2
  exit 1
fi

GATEWAY_BUNDLE="$("${KUBECTL[@]}" get crd gateways.gateway.networking.k8s.io --ignore-not-found \
  -o 'go-template={{index .metadata.annotations "gateway.networking.k8s.io/bundle-version"}} {{index .metadata.annotations "gateway.networking.k8s.io/channel"}}')"
case "$GATEWAY_BUNDLE" in
  'v1.6.'*' standard') ;;
  *)
    echo "Expected provider-managed Gateway API v1.6 standard CRDs; found '$GATEWAY_BUNDLE'." >&2
    echo "Use the k3s baseline described in docs/rebuild-production.md." >&2
    exit 1
    ;;
esac
"${KUBECTL[@]}" wait crd \
  gateways.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io backendtlspolicies.gateway.networking.k8s.io \
  tcproutes.gateway.networking.k8s.io udproutes.gateway.networking.k8s.io \
  tlsroutes.gateway.networking.k8s.io listenersets.gateway.networking.k8s.io \
  --for=condition=Established --timeout=2m

if [[ -n "$AGE_KEY_FILE" ]]; then
  [[ -r "$AGE_KEY_FILE" ]] || { echo "Cannot read the age key file: $AGE_KEY_FILE" >&2; exit 1; }
  command -v sops >/dev/null 2>&1 || { echo "Install sops to validate the age key." >&2; exit 1; }
  # Validate without printing decrypted credentials. A newly generated key cannot
  # decrypt the secrets already committed to this repository.
  SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --decrypt \
    "$REPO_ROOT/apps/tailscale-operator/base/operator-oauth-secrets.yaml" >/dev/null
  echo "==> Installing the original SOPS age key"
  "${KUBECTL[@]}" create namespace sops --dry-run=client -o yaml | \
    "${KUBECTL[@]}" apply --server-side --field-manager=workrave-bootstrap -f -
  "${KUBECTL[@]}" create secret generic sops-age-key-file -n sops \
    --from-file="keys.txt=$AGE_KEY_FILE" --dry-run=client -o yaml | \
    "${KUBECTL[@]}" apply --server-side --field-manager=workrave-bootstrap -f -
elif ! "${KUBECTL[@]}" get secret sops-age-key-file -n sops >/dev/null 2>&1; then
  echo "The original SOPS age key is required on a fresh cluster." >&2
  echo "Re-run with its backup as the third argument. Do not generate a replacement key." >&2
  exit 1
fi

show_status() {
  flux --context="$CONTEXT" get kustomizations -A || true
  flux --context="$CONTEXT" get helmreleases -A || true
}
trap 'echo "Bootstrap failed; inspect the first failing dependency below." >&2; show_status' ERR

echo "==> Bootstrapping Flux from production/main"
# Flux supports GIT_PASSWORD, which keeps the token out of command-line arguments.
GIT_PASSWORD="${GIT_PASSWORD:-$(gh auth token)}" flux bootstrap git \
  --context="$CONTEXT" \
  --url=https://github.com/rcaelers/workrave-infra.git \
  --branch=main --path=clusters/production --version="$FLUX_VERSION" \
  --username=git --silent

echo "==> Waiting for the root and all application tiers"
flux --context="$CONTEXT" reconcile kustomization flux-system --with-source --timeout=5m
"${KUBECTL[@]}" wait kustomizations.kustomize.toolkit.fluxcd.io -n flux-system \
  --all --for=condition=Ready --timeout="$BOOTSTRAP_TIMEOUT"
# HelmReleases now exist because their parent application tiers are Ready.
"${KUBECTL[@]}" wait helmreleases.helm.toolkit.fluxcd.io -n flux-system \
  --all --for=condition=Ready --timeout="$BOOTSTRAP_TIMEOUT"

echo "==> Bootstrap complete: all Flux application tiers and HelmReleases are Ready."
show_status
