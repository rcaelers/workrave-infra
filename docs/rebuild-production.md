# Rebuild production from an empty k3s cluster

Git contains the workload definitions, encrypted credentials, storage classes,
and setup jobs. It does not contain the SOPS private key, host configuration,
external accounts, or persistent application data. Keep those backups outside
the cluster before wiping it.

The `home` cluster and its SSH Git server are retired. Use `production`, the
GitHub repository, and the `main` branch.

## Save before wiping

Save the original SOPS age key in an encrypted backup or password manager. To
export it to a restricted local file without displaying it:

```sh
umask 077
RECOVERY_DIR="$(mktemp -d)"
kubectl --context=hetzner get secret sops-age-key-file -n sops \
  -o 'jsonpath={.data.keys\.txt}' | base64 -d > "$RECOVERY_DIR/keys.txt"
test -s "$RECOVERY_DIR/keys.txt"
```

Move that file into your secure backup, and verify it can decrypt a repository
secret without printing the result:

```sh
SOPS_AGE_KEY_FILE="$RECOVERY_DIR/keys.txt" sops --decrypt \
  apps/tailscale-operator/base/operator-oauth-secrets.yaml >/dev/null
```

Generating a new age key will not decrypt the existing secrets. The key is used
by the SOPS operator, in `sops/sops-age-key-file`, with the data key `keys.txt`.

Back up persistent data separately, using a consistent database export or a
snapshot taken while writers are stopped. Current PVCs are:

| Namespace | PVC | Contents |
| --- | --- | --- |
| `surrealdb` | `surrealdb` | Guardrail database |
| `garage` | `meta-garage-0`, `data-garage-0` | Object metadata, keys, buckets, and objects; preserve both together |
| `guardrail` | `pocket-id-data` | Users, passkeys, and identity-provider state |
| `monitoring` | `victorialogs-storage` | Log history |

Preserve the matching Pocket ID encryption key and SurrealDB credentials from
the encrypted manifests along with their data. Local-path volumes live on the
node; a `Retain` reclaim policy does not protect them from a host wipe. A k3s
datastore backup also does not include PVC contents.

Save the host's k3s service/configuration, network and firewall settings, DNS
records, and access to GitHub, Tailscale, and certificate-provider accounts.
Production currently has a Hetzner cloud controller outside this repository.
If recreating its external-cloud configuration, restore that controller too;
otherwise use k3s's built-in cloud controller. Do not copy
`--disable-cloud-controller` or `cloud-provider=external` onto a generic server
without supplying their replacement.

## Prepare an empty server

Use an **amd64 Linux** server: the Garage image is `dxflrs/amd64_garage`.
The current production baseline is **k3s v1.37.0+k3s1**, which supplies Gateway
API **v1.6.1 standard** CRDs through its `gateway-api-crd` packaged chart.
Keep CoreDNS, local-path storage, the k3s Helm controller, and that Gateway API
package enabled. Disable Traefik and ServiceLB, because Envoy binds host ports
80 and 443. Keep the default Kubernetes domain `cluster.local`.

For a new generic server, create `/etc/rancher/k3s/config.yaml`:

```yaml
disable:
  - traefik
  - servicelb
secrets-encryption: true
```

Download and inspect the [k3s installer](https://get.k3s.io), then run it with
the pinned baseline, for example:

```sh
curl -fsSL https://get.k3s.io -o /tmp/install-k3s.sh
sudo env INSTALL_K3S_VERSION=v1.37.0+k3s1 sh /tmp/install-k3s.sh
```

Add the new cluster's admin kubeconfig to your local kubeconfig under the chosen
context. Ensure its API endpoint and certificate SANs match the address used
from your workstation. Allow public traffic on 80/443 and outbound access to
GitHub, image/chart registries, Tailscale, and certificate authorities. Restore
the service DNS records to the new server before checking public endpoints.

For this Envoy release, bootstrap requires Gateway API v1.6 standard. Envoy
v1.9's [published compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/)
lists Kubernetes through v1.36; v1.37 is the current production baseline and
is outside that published tested range. A complete empty-cluster rebuild on
this baseline still needs a rehearsal before relying on it for disaster
recovery.

## Bootstrap from Git

On the workstation, install the tools and authenticate GitHub with permission
to push this repository (Flux bootstrap can write its generated manifests):

```sh
brew install fluxcd/tap/flux kubectl gh sops
gh auth login
git clone https://github.com/rcaelers/workrave-infra.git
cd workrave-infra
scripts/flux-bootstrap.sh production <new-kube-context> /secure/backup/keys.txt
```

The script checks node readiness, local-path storage, Traefik, and Gateway API
CRDs; validates and installs the original age key; installs the Flux version
committed in Git; then waits for **all application Kustomizations and
HelmReleases**. Its default readiness timeout is 30 minutes per wait; override
with `WORKRAVE_BOOTSTRAP_TIMEOUT=45m` if needed. A failed tier causes a nonzero
exit and a Flux status listing. Re-running is supported; omit the key-file
argument once the correct key secret already exists.

Flux installs Envoy-specific CRDs directly from the pinned chart artifact
before installing the controller. k3s remains the owner of the standard
Gateway API CRDs and safe-upgrade policies. The Envoy CRDs are retained if their
Flux Kustomization is removed. Renovate updates the CRD source and controller
chart together.

Garage's setup job runs alongside its Helm install, so it can assign the
initial storage layout before Garage's health check passes. Later application
tiers wait for both Garage and this setup job.

An empty-data install creates new databases, object storage, and identity state.
To recover existing data, restore the consistent backups into the intended
volumes **before** starting their applications and setup jobs; that restore
procedure is separate from this bootstrap script. Do not run the complete
bootstrap first and then overwrite running databases.

## Verify recovery

```sh
flux --context=<new-kube-context> get kustomizations -A
flux --context=<new-kube-context> get helmreleases -A
kubectl --context=<new-kube-context> get pods,pvc -A
kubectl --context=<new-kube-context> get gateway,httproute -A
kubectl --context=<new-kube-context> get certificates -A
```

Check Ready conditions, successful setup jobs, bound PVCs, Gateway
`Accepted`/`Programmed`, and HTTPRoute `Accepted`/`ResolvedRefs`. Verify public
HTTPS, Tailscale access, Pocket ID login, and Guardrail ingestion and object
retrieval. If restoring data, verify the previous users and records too.

Repository rendering, API dry-runs, and an upgrade of the existing cluster do
not establish that a complete empty-cluster recovery works. Rehearse on a
separate server with test external accounts before wiping production.
