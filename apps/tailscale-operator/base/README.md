# Tailscale operator

This app installs the Tailscale Kubernetes Operator. The chart expects an OAuth
secret named `operator-oauth` in the `tailscale` namespace with two keys:
`client_id` and `client_secret`.

Fill in `operator-oauth-secrets.yaml`, then encrypt it before syncing:

```sh
sops -e -i apps/tailscale-operator/base/operator-oauth-secrets.yaml
```

The OAuth client must have the `Devices Core`, `Auth Keys`, and `Services` write
scopes, and it must be tagged with `tag:k8s-operator`.

The tailnet policy needs these tag owners:

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:k8s-ingress": ["tag:k8s-operator"]
  }
}
```

Tailscale Ingress requires MagicDNS and HTTPS to be enabled for the tailnet.
Ingresses in this repo use the shared `ingress-proxies` ProxyGroup. That keeps
one proxy replica running while still exposing each admin service as a separate
Tailscale Service with its own DNS name and ACL tag.

## Sharing ACLs

The shared ingress ProxyGroup is tagged with `tag:k8s-ingress`. Each tailnet
ingress creates a Tailscale Service tagged with a service-specific sharing tag:

| Service | Tag |
| --- | --- |
| Argo CD | `tag:shared-argocd` |
| Longhorn | `tag:shared-longhorn` |
| MinIO development | `tag:shared-minio-dev` |
| MinIO production | `tag:shared-minio` |
| SurrealDB development | `tag:shared-surrealdb-dev` |
| SurrealDB production | `tag:shared-surrealdb` |
| VictoriaLogs | `tag:shared-victorialogs` |

The operator OAuth identity must be allowed to apply these tags:

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:k8s-ingress": ["tag:k8s-operator"],
    "tag:shared-argocd": ["tag:k8s-operator"],
    "tag:shared-longhorn": ["tag:k8s-operator"],
    "tag:shared-minio-dev": ["tag:k8s-operator"],
    "tag:shared-minio": ["tag:k8s-operator"],
    "tag:shared-surrealdb-dev": ["tag:k8s-operator"],
    "tag:shared-surrealdb": ["tag:k8s-operator"],
    "tag:shared-victorialogs": ["tag:k8s-operator"]
  }
}
```

The ProxyGroup devices must also be allowed to advertise the tagged Tailscale
Services:

```json
{
  "autoApprovers": {
    "services": {
      "tag:shared-argocd": ["tag:k8s-ingress"],
      "tag:shared-longhorn": ["tag:k8s-ingress"],
      "tag:shared-minio-dev": ["tag:k8s-ingress"],
      "tag:shared-minio": ["tag:k8s-ingress"],
      "tag:shared-surrealdb-dev": ["tag:k8s-ingress"],
      "tag:shared-surrealdb": ["tag:k8s-ingress"],
      "tag:shared-victorialogs": ["tag:k8s-ingress"]
    }
  }
}
```

To share a service with someone outside this tailnet:

1. Share the specific Tailscale Service from the Tailscale admin console.
2. Add a grant for that recipient and the service tag.

Example grant for one recipient:

```json
{
  "grants": [
    {
      "src": ["alice@example.com"],
      "dst": ["tag:shared-minio-dev"],
      "ip": ["443"]
    },
    {
      "src": ["alice@example.com"],
      "dst": ["tag:shared-victorialogs"],
      "ip": ["443"]
    }
  ]
}
```

Example grant for all shared users, still limited to only the machines they have
accepted shares for:

```json
{
  "grants": [
    {
      "src": ["autogroup:shared"],
      "dst": [
        "tag:shared-minio-dev",
        "tag:shared-victorialogs"
      ],
      "ip": ["443"]
    }
  ]
}
```

Tailscale currently also requires access to the ProxyGroup device for ICMP. Keep
this narrow by granting only ICMP to `tag:k8s-ingress`:

```json
{
  "grants": [
    {
      "src": ["alice@example.com"],
      "dst": ["tag:k8s-ingress"],
      "ip": ["icmp:*"]
    }
  ]
}
```

Sharing makes the selected Tailscale Service visible to the recipient user in
their Tailscale client. The grant limits what that user can connect to. Shared
services are visible only to the invited user, not to every member of the
recipient's tailnet.

Tailscale only applies tag and hostname annotations during initial provisioning.
If a tag changes on an already exposed service, remove and recreate the tailnet
exposure so the operator provisions a new Tailscale node with the new tags.
