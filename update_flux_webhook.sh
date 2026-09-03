#!/usr/bin/env bash
# Point the GitHub webhook at the Flux receiver's current URL and shared secret.
#
# Flux derives the receiver path from the token: sha256(token+name+namespace).
# So rotating the token (rotate_keys.sh) changes the URL as well as the secret,
# and GitHub must be updated or push events fail silently -- sync then falls
# back to the GitRepository interval (1h) with nothing reporting unhealthy.
#
# Run this AFTER Flux has applied the rotated secret to the cluster.
set -euo pipefail

REPO="${REPO:-rcaelers/workrave-infra}"
HOST="${HOST:-flux-webhook.workrave.org}"
RECEIVER="${RECEIVER:-github-receiver}"
NAMESPACE="${NAMESPACE:-flux-system}"
SECRET_FILE="apps/flux-webhook/base/flux-webhook-secrets.yaml"

cd "$(dirname "${BASH_SOURCE[0]}")"

for t in kubectl sops gh; do
  command -v "$t" >/dev/null || { echo "error: $t not found" >&2; exit 1; }
done

TOKEN="$(sops --decrypt "$SECRET_FILE" | awk '/^ *token:/{print $2}')"
[ -n "$TOKEN" ] || { echo "error: could not read token from $SECRET_FILE" >&2; exit 1; }

# Take the path from the cluster rather than recomputing it, so this keeps
# working if Flux ever changes the derivation.
WEBHOOK_PATH="$(kubectl get receiver "$RECEIVER" -n "$NAMESPACE" \
  -o jsonpath='{.status.webhookPath}' 2>/dev/null || true)"
[ -n "$WEBHOOK_PATH" ] || {
  echo "error: receiver $RECEIVER has no .status.webhookPath yet." >&2
  echo "       Has Flux applied the rotated secret? Check:" >&2
  echo "         kubectl get receiver $RECEIVER -n $NAMESPACE" >&2
  exit 1; }

# Confirm the receiver is serving the path derived from the token we hold. If
# these disagree, the cluster has not caught up with the repo yet.
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}
EXPECTED="/hook/$(printf '%s' "${TOKEN}${RECEIVER}${NAMESPACE}" | sha256)"
if [ "$WEBHOOK_PATH" != "$EXPECTED" ]; then
  echo "error: receiver path does not match the token in git." >&2
  echo "       The cluster is still on the previous secret. Wait for Flux to" >&2
  echo "       reconcile (the secret is labelled reconcile.fluxcd.io/watch so" >&2
  echo "       this should be seconds, not the 10m Receiver interval) and retry." >&2
  exit 1
fi

URL="https://${HOST}${WEBHOOK_PATH}"

HOOK_ID="$(gh api "repos/${REPO}/hooks" \
  --jq ".[] | select(.config.url | contains(\"${HOST}\")) | .id" | head -1)"

if [ -n "$HOOK_ID" ]; then
  gh api "repos/${REPO}/hooks/${HOOK_ID}" -X PATCH \
    -f "config[url]=${URL}" \
    -f 'config[content_type]=json' \
    -f 'config[insecure_ssl]=0' \
    -f "config[secret]=${TOKEN}" \
    --jq '"updated hook id=\(.id)"'
else
  gh api "repos/${REPO}/hooks" -X POST \
    -f name=web -F active=true -f 'events[]=push' \
    -f "config[url]=${URL}" \
    -f 'config[content_type]=json' \
    -f 'config[insecure_ssl]=0' \
    -f "config[secret]=${TOKEN}" \
    --jq '"created hook id=\(.id)"'
  HOOK_ID="$(gh api "repos/${REPO}/hooks" \
    --jq ".[] | select(.config.url | contains(\"${HOST}\")) | .id" | head -1)"
fi

echo "url: ${URL}"

# A ping proves the whole path end to end: DNS, TLS, routing, and the HMAC
# signature against the new secret.
gh api "repos/${REPO}/hooks/${HOOK_ID}/pings" -X POST >/dev/null
sleep 5
RESULT="$(gh api "repos/${REPO}/hooks/${HOOK_ID}/deliveries" \
  --jq 'map(select(.event=="ping"))|sort_by(.delivered_at)|last|"\(.status) \(.status_code)"')"
echo "ping: ${RESULT}"
case "$RESULT" in
  "OK 200") echo "webhook healthy" ;;
  *) echo "warning: ping did not return 200 -- check notification-controller logs:" >&2
     echo "  kubectl logs -n ${NAMESPACE} deploy/notification-controller --tail=20" >&2
     exit 1 ;;
esac
