# Linode DNS webhook

The home cluster installs Linode's official cert-manager DNS01 webhook from:

https://github.com/linode/cert-manager-webhook-linode

The Argo CD application is pinned to the latest upstream release tag.

Create the API token secret manually in the home cluster:

```sh
kubectl create secret generic linode-credentials \
  --namespace cert-manager \
  --from-literal=token='<LINODE_TOKEN>'
```

The token must be allowed to update DNS records for `workrave.org`.
