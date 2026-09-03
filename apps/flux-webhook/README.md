# Flux GitHub webhook receiver

Removes the up-to-60s `GitRepository` polling lag by having GitHub notify
Flux on push. Pairs with `--requeue-dependency=5s` (commit 3082346), which
addressed the much larger cost: dependency propagation through the 19-deep
gate chain.

## Prerequisite: DNS (must be done FIRST)

    flux-webhook.workrave.org.  CNAME  cygnus.krandor.org.

`workrave.org` is on Linode (ns1-4.linode.com); there is no wildcard record.

**Do not merge this branch before that record resolves.** The ClusterIssuer
solves ACME via HTTP-01, so cert-manager cannot issue until the name points
at the node. And because the `envoy-gateway` Kustomization runs `wait: true`
with no explicit `healthChecks`, Flux waits on every applied resource - a
`Certificate` stuck Pending, or a listener whose TLS secret does not exist,
stalls that Kustomization for its full 5m timeout and blocks `gate-40` and
everything below it (surrealdb, garage, valkey, pocket-id, all of guardrail).
Traffic keeps flowing, but reconciliation wedges.

Verify before merging:

    dig +short flux-webhook.workrave.org     # must return 178.105.30.118

## What this adds

| Resource | Where |
|---|---|
| `Certificate flux-webhook-workrave-org` | `apps/envoy-gateway/overlays/production/certificates.yaml` |
| Gateway listener `flux-webhook-https` | `apps/envoy-gateway/overlays/production/gateway-listeners-patch.json` |
| `HTTPRoute` -> `webhook-receiver:80` | `apps/flux-webhook/base/httproute.yaml` |
| `Receiver github-receiver` | `apps/flux-webhook/base/receiver.yaml` |
| `SopsSecret flux-webhook-token` | `apps/flux-webhook/base/flux-webhook-secrets.yaml` |
| `Kustomization flux-webhook` (dependsOn gate-40) | `clusters/production/tiers/40-data-plane.yaml` |

## After merging

1. Wait for the cert and the receiver to come up:

       kubectl get certificate flux-webhook-workrave-org -n envoy-gateway-system
       kubectl get receiver github-receiver -n flux-system

2. Read the generated webhook path (Flux derives it from the token):

       kubectl get receiver github-receiver -n flux-system -o jsonpath='{.status.webhookPath}'

3. Recover the shared secret:

       sops --decrypt apps/flux-webhook/base/flux-webhook-secrets.yaml \
         | grep 'token:' | awk '{print $2}'

4. Register the webhook (URL is `https://flux-webhook.workrave.org` + the path
   from step 2):

       gh api repos/rcaelers/workrave-infra/hooks -X POST \
         -f name=web -F active=true -f events[]=push \
         -f config[url]="https://flux-webhook.workrave.org<PATH>" \
         -f config[content_type]=json \
         -f config[secret]="<TOKEN>"

5. Confirm GitHub's ping was accepted:

       gh api repos/rcaelers/workrave-infra/hooks --jq '.[].last_response'

## Rollback

Revert the merge. The listener and cert are additive; removing them does not
touch the crashes/auth listeners.

## Security note

This is a new publicly reachable HTTPS endpoint on the shared gateway.
notification-controller validates GitHub's HMAC signature against the shared
secret, and the route only matches the `/hook/` prefix, so unsigned or
misdirected requests are rejected. It is still new external attack surface -
that is the cost of this option over simply lowering the `GitRepository`
interval to 15s, which recovers 45 of the same 60 seconds with none of it.
