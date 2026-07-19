#!/usr/bin/env bash
# Safely remove ArgoCD from a cluster without cascading a prune of the
# workloads it manages, by stripping the resources-finalizer from every
# Application *before* deleting it. This orphans the live Deployments,
# Services, etc. (they keep running, untouched) instead of ArgoCD deleting
# them on its way out. A subsequent `flux-bootstrap.sh` run then adopts the
# same resources via server-side apply.
#
# This proactive finalizer removal is exactly the manual recovery step
# documented in the old apps/app-of-apps/README.md after ArgoCD reinstalls
# got stuck with a terminating `applications.argoproj.io` CRD; doing it here
# up front avoids that failure mode entirely.
#
# IMPORTANT: argocd-application-controller re-adds
# resources-finalizer.argocd.argoproj.io on its next reconcile if it's still
# running when a finalizer is stripped (its sync policy declaratively wants
# that finalizer present). The controller must be scaled to 0 *before*
# stripping finalizers, or the strip is a no-op race.
#
# Usage: scripts/argocd-teardown.sh <kube-context>
set -euo pipefail

CONTEXT="${1:?Usage: $0 <kube-context>}"
KUBECTL="kubectl --context=${CONTEXT}"

echo "==> Tearing down ArgoCD on context '${CONTEXT}'"

if ! ${KUBECTL} get namespace argocd >/dev/null 2>&1; then
  echo "==> No 'argocd' namespace found, nothing to tear down."
  exit 0
fi

echo "==> Scaling down argocd-application-controller so it can't re-add finalizers"
${KUBECTL} -n argocd scale statefulset argocd-application-controller --replicas=0 2>/dev/null || true
${KUBECTL} -n argocd wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller --timeout=2m 2>/dev/null || true

echo "==> Stripping resources-finalizer.argocd.argoproj.io from all Applications"
for ns in $(${KUBECTL} get applications.argoproj.io -A -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u); do
  for app in $(${KUBECTL} -n "${ns}" get applications.argoproj.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "    - ${ns}/${app}"
    ${KUBECTL} -n "${ns}" patch application.argoproj.io "${app}" \
      --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
done

echo "==> Deleting Applications"
${KUBECTL} delete applications.argoproj.io -A --all --ignore-not-found --wait=true --timeout=2m || true

echo "==> Deleting ApplicationSets"
${KUBECTL} delete applicationsets.argoproj.io -A --all --ignore-not-found --wait=true --timeout=2m || true

echo "==> Deleting AppProjects"
${KUBECTL} delete appprojects.argoproj.io -A --all --ignore-not-found --wait=true --timeout=2m || true

echo "==> Deleting the argocd namespace (controllers, server, redis, dex, repo-server)"
${KUBECTL} delete namespace argocd --ignore-not-found --wait=true --timeout=3m

echo "==> Deleting ArgoCD CRDs"
${KUBECTL} get crds -o name | grep argoproj.io | xargs -r ${KUBECTL} delete --ignore-not-found

echo "==> ArgoCD teardown complete. Live workloads were left running (orphaned, not pruned)."
