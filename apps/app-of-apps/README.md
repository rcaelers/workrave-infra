# Argo CD app-of-apps bootstrap

This directory contains the `workrave-apps` ApplicationSet. It generates the
individual Workrave and Guardrail Argo CD Applications for the selected cluster
environment.

After reinstalling Argo CD, re-create the bootstrap ApplicationSet from the
repository root:

```sh
kubectl apply -f apps/app-of-apps.yaml
```

The bootstrap ApplicationSet creates the `workrave-apps` Application, which then
syncs this directory and recreates the `workrave-apps` ApplicationSet.

## Home cluster recovery notes

The home cluster uses a private SSH repository URL. Its SSH host key is
cluster-local configuration and should not be committed to this public repo.
After reinstalling Argo CD, add the host key directly to the live
`argocd-ssh-known-hosts-cm` ConfigMap, then restart `argocd-repo-server`.

If Argo CD was removed while Applications still had
`resources-finalizer.argocd.argoproj.io`, the `applications.argoproj.io` CRD can
remain stuck terminating. In that case:

1. Remove finalizers from the already-deleting `Application` objects so
   Kubernetes can finish deleting the old CRD.
2. Recreate the Argo CD `Application` CRD for the installed Argo CD version if
   the reinstall did not restore it.
3. Restart `argocd-applicationset-controller` so it refreshes its watches.
4. Re-apply `apps/app-of-apps.yaml` or annotate `workrave-apps` with
   `argocd.argoproj.io/refresh=hard`.

If Kyverno was removed before its webhook configurations, stale fail-closed
Kyverno webhooks can block Argo CD patches. Remove only the stale Kyverno
webhook configurations; the `kyverno` Application will recreate them when it
syncs again.

The standard `argocd-cm` labels must remain present:

```yaml
app.kubernetes.io/name: argocd-cm
app.kubernetes.io/part-of: argocd
```

Without these labels, Argo CD components can report `configmap "argocd-cm" not
found` even though the ConfigMap exists. The home/base overlay keeps those
labels on `argocd-cm`.

The warning below during reinstall is harmless. It means the existing ConfigMap
was not originally created by `kubectl apply`; `kubectl apply` will add the
annotation automatically.

```text
Warning: resource configmaps/argocd-cm is missing the kubectl.kubernetes.io/last-applied-configuration annotation
```

## Recovery performed on 2026-05-14

The home Argo CD reinstall left old `Application` objects deleting with
`resources-finalizer.argocd.argoproj.io`, which kept the old
`applications.argoproj.io` CRD terminating. The recovery steps were:

1. Applied `apps/app-of-apps.yaml` to recreate `workrave-apps-bootstrap`.
2. Removed finalizers from already-deleting old `Application` objects so the old
   Application CRD could finish deleting without pruning live workloads.
3. Recreated the Argo CD `Application` CRD for the installed Argo CD version.
4. Deleted stale Kyverno webhook configurations because Kyverno had no running
   service and the fail-closed webhooks were blocking patches.
5. Restarted `argocd-applicationset-controller`.
6. Added the private home SSH host key to the live `argocd-ssh-known-hosts-cm`
   ConfigMap and restarted `argocd-repo-server`.
7. Hard-refreshed `workrave-apps`, which recreated the `workrave-apps`
   ApplicationSet and all child Applications.
8. Restored the standard labels on `argocd-cm` and restarted
   `argocd-application-controller`.
