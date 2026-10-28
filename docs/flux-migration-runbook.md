# ArgoCD → Flux CD migration runbook

This is the historical migration record for the production stack.
For a fresh production cluster, follow
[Rebuild production](rebuild-production.md); the bootstrap script now accepts
`production <kube-context> [sops-age-key-file]`.

## Why

ArgoCD's controller stack (`argocd-application-controller`,
`repo-server`, `server`, `applicationset-controller`, `notifications`,
`dex`, `redis`) was using well over 1.4GB RAM on a single-node k3s
cluster (8GB total), and its `Application` finalizer has repeatedly gotten
stuck on reinstall, requiring manual finalizer surgery (see git history of
the old `apps/app-of-apps/README.md`, now removed).

Flux CD's controllers (source-controller, kustomize-controller,
helm-controller, notification-controller) typically run under ~200MB
combined, apply via server-side apply, and have no custom finalizer to get
stuck.

## What changed

- `apps/argocd-config/`, `apps/app-of-apps/`, `apps/app-of-apps.yaml`, and
  `apps/tailnet-admin/` (the ArgoCD-UI Tailscale ingress) are removed.
- `clusters/production/` holds one Flux
  `Kustomization` object per app (mirroring the old one-Application-per-app
  ArgoCD model), grouped into numbered tiers under `tiers/` that replicate
  the old ArgoCD sync-wave order (10, 20, 25, 30, 35, 40, 50, 60, 65,
  70). Each tier starts with a `gate-<N>` Kustomization that
  `dependsOn` every app in the previous tier; apps in that tier `dependsOn`
  the gate. `clusters/_empty/` is a shared no-op path used only by gates.
- Apps that used kustomize's `helmCharts:` inflator (cert-manager, garage,
  kyverno, reloader, sops-secrets-operator, surrealdb, tailscale-operator,
  valkey) were converted to native `HelmRepository`/`OCIRepository` +
  `HelmRelease` objects, because Flux's kustomize-controller does not
  support the `helmCharts:` inflator (it requires kustomize's
  `--enable-helm` exec plugin, which Flux disables by design). Chart
  versions were kept identical to what ArgoCD was running.
  - `envoy-gateway-helm` (OCI chart) has its own `apps/` entry;
    it previously existed only as inline ApplicationSet templating.
  - All `HelmRepository`/`OCIRepository`/`GitRepository`/`HelmRelease`
    objects live in the `flux-system` namespace with `targetNamespace: <ns>`
    + `install.createNamespace: true`, to avoid a chicken-and-egg problem
    where the object's own namespace doesn't exist yet.
  - `garage`, `valkey`, `surrealdb`, and `tailscale-operator` each have
    their `HelmRelease`/`HelmRepository` split into a sibling `apps/<app>/flux/`
    directory instead of `apps/<app>/base/`, because their base/overlays set
    a kustomize `namespace:` transformer for their plain resources — had the
    HelmRelease stayed in that same kustomization, the transformer would
    have rewritten its namespace away from `flux-system`.
- ArgoCD's `CreateNamespace=true` has no Flux equivalent for plain
  (non-Helm) resources, so an explicit `Namespace` manifest was added to
  whichever app is the first consumer of a given namespace
  (`guardrail-resources`, `fluent-bit`+`victorialogs`,
  `guardrail-setup-surrealdb-schema`, `garage`, `tailscale-operator`). Namespaces
  first created by a `HelmRelease` rely on its built-in
  `install.createNamespace: true` instead.
- ArgoCD `PreSync`/`Sync`/`PostSync` hook Jobs (migrate, guardrail-setup-*,
  pocket-id setup/rotation, surrealdb rotation) are now annotated
  `kustomize.toolkit.fluxcd.io/force: "Enabled"`, which tells Flux to
  delete+recreate the Job when its spec changes — the closest equivalent of
  ArgoCD's `BeforeHookCreation` hook-delete-policy.
  - **Known limitation**: a few of these jobs relied on ArgoCD's fine-grained
    hook-phase ordering (e.g. `pocket-id-key-rotation-job.yaml` and
    `surrealdb-password-rotation-job.yaml` each run a "snapshot" Job before a
    "rotate" Job; `guardrail-setup-surrealdb-schema` runs a "start" Job before
    a "complete" Job). Flux only orders at the `Kustomization` (tier)
    granularity, not between individual Jobs inside the same one. Both
    rotation jobs already retry (`backoffLimit` > 1) and the rotate script
    tolerates a missing snapshot secret by falling back/erroring cleanly, so
    a first-attempt race should self-heal on the Job's own retry — but if you
    see a rotation job hard-fail, check whether its sibling snapshot job had
    finished first.
- Secrets (`sops-secrets-operator` + SOPS-encrypted `*secrets*.yaml` files)
  are untouched — decryption happens in-cluster via the operator's own CRD
  reconciliation, independent of ArgoCD vs Flux.

## Prerequisites

- Install Flux CLI, `kubectl`, GitHub CLI, and SOPS as described in
  [Rebuild production](rebuild-production.md), then authenticate with
  `gh auth login`.
- A `kubectl` context for production (`hetzner` in this repo's setup).
- The original SOPS age key, either installed in the cluster or supplied as
  the bootstrap script's third argument.

## Migration procedure (completed for production)

1. Make sure this Flux content is present on `main` in
   `https://github.com/rcaelers/workrave-infra.git` before bootstrapping,
   since `flux bootstrap git` reconciles from that branch immediately.
2. Tear down ArgoCD, without pruning live workloads:
   ```sh
   scripts/argocd-teardown.sh <kube-context>
   ```
   The script scales `argocd-application-controller` to 0 first. During an
   earlier migration, an older version of this script stripped Application
   finalizers *before* doing that, and the still-running controller re-added
   them within milliseconds — all 28 Applications ended up stuck
   `Terminating` and blocked the `argocd` namespace from deleting, the exact
   failure mode this whole migration exists to get away from. If you ever
   see that again: confirm `argocd-application-controller` has zero pods,
   then re-strip finalizers (`kubectl -n argocd patch application.argoproj.io
   <name> --type=merge -p '{"metadata":{"finalizers":null}}'`) — with the
   controller actually dead, the strip sticks.
3. Bootstrap Flux and point it at this repo:
   ```sh
   scripts/flux-bootstrap.sh production <kube-context> [sops-age-key-file]
   ```
4. Watch reconciliation:
   ```sh
   flux --context=<kube-context> get kustomizations -A --watch
   flux --context=<kube-context> get helmreleases -A --watch
   ```
5. Verify workloads match the pre-migration set and memory usage of the
   `flux-system` namespace is far below ArgoCD's old footprint:
   ```sh
   kubectl --context=<kube-context> get pods -A
   kubectl --context=<kube-context> top pods -n flux-system
   ```

## Rolling back

Flux was bootstrapped fresh; it did not delete anything ArgoCD created
(`argocd-teardown.sh` only removes ArgoCD's own Application finalizers and
its own namespace/CRDs, leaving managed workloads running). To roll back:

1. `flux uninstall --context=<kube-context>` (removes Flux controllers and
   CRDs, leaves workloads running).
2. Re-apply the old ArgoCD manifests from a prior commit if needed.
