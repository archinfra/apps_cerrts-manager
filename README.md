# apps_cerrts-manager

cert-manager Kubernetes offline `.run` installer package.

> Repository name follows the current upstream repository URL: `archinfra/apps_cerrts-manager`. The package and Kubernetes application name are standard `cert-manager`.

This package downloads the official cert-manager release manifest at build time, packages all required images into a self-extracting offline `.run`, retags and pushes those images to an internal registry at install time, rewrites the manifest image references, and deploys cert-manager on Kubernetes.

## Version

- cert-manager: `v1.20.3`
- default namespace: `cert-manager`
- default registry prefix: `sealos.hub:5000/kube4`
- default image pull policy: `IfNotPresent`
- release manifest: `https://github.com/cert-manager/cert-manager/releases/download/v1.20.3/cert-manager.yaml`

The default version is `v1.20.3`, the latest GitHub release when this package was created. The release notes mark it as a security patch release and say all users should upgrade.

## Images

The offline payload includes these images for each target architecture:

```text
quay.io/jetstack/cert-manager-controller:v1.20.3
quay.io/jetstack/cert-manager-cainjector:v1.20.3
quay.io/jetstack/cert-manager-webhook:v1.20.3
quay.io/jetstack/cert-manager-startupapicheck:v1.20.3
quay.io/jetstack/cert-manager-acmesolver:v1.20.3
```

The `acmesolver` image is included because cert-manager dynamically creates ACME HTTP-01 solver Pods. Offline clusters need this image in the internal registry even though it is not a long-running Deployment.

Default retargeted images:

```text
sealos.hub:5000/kube4/jetstack/cert-manager-controller:v1.20.3
sealos.hub:5000/kube4/jetstack/cert-manager-cainjector:v1.20.3
sealos.hub:5000/kube4/jetstack/cert-manager-webhook:v1.20.3
sealos.hub:5000/kube4/jetstack/cert-manager-startupapicheck:v1.20.3
sealos.hub:5000/kube4/jetstack/cert-manager-acmesolver:v1.20.3
```

## What this package creates

The official release manifest creates cert-manager CRDs and runtime resources, including:

- Namespace: `cert-manager` by default
- CRDs: `cert-manager.io` and `acme.cert-manager.io`
- ServiceAccounts, RBAC, ClusterRoles, ClusterRoleBindings
- Deployment: `cert-manager`
- Deployment: `cert-manager-cainjector`
- Deployment: `cert-manager-webhook`
- Service: `cert-manager-webhook`
- Job: `cert-manager-startupapicheck`

## Build locally

Build host requirements:

- Linux shell
- Docker
- Python 3
- `curl`
- `tar`
- `sha256sum`

No `jq` is required.

Build one architecture:

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
```

Build both:

```bash
bash build.sh --arch all
```

Use another manifest URL when needed:

```bash
bash build.sh --arch amd64 \
  --manifest-url https://github.com/cert-manager/cert-manager/releases/download/v1.20.3/cert-manager.yaml
```

Artifacts are written to `dist/`:

```text
dist/cert-manager-1.20.3-amd64.run
dist/cert-manager-1.20.3-amd64.run.sha256
dist/cert-manager-1.20.3-arm64.run
dist/cert-manager-1.20.3-arm64.run.sha256
```

## Target host requirements

Target host requirements:

- `bash`
- common Linux base tools: `awk`, `head`, `wc`, `dd`, `od`, `tail`, `tar`, `sed`
- `docker`, unless `--skip-image-prepare` is used
- `kubectl`
- optional `sha256sum`, only for checking the `.sha256` file before running the installer

The target host does **not** need `jq`, Python, curl, or Internet access.

## Install

```bash
sha256sum -c cert-manager-1.20.3-amd64.run.sha256
chmod +x cert-manager-1.20.3-amd64.run

./cert-manager-1.20.3-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'passw0rd' \
  -n cert-manager \
  -y
```

If the internal registry already contains all five images:

```bash
./cert-manager-1.20.3-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -n cert-manager \
  -y
```

Use another namespace:

```bash
./cert-manager-1.20.3-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  -n platform-cert-manager \
  -y
```

The installer rewrites namespaced resources and webhook CRD conversion service namespaces to the target namespace. Resource names remain the upstream defaults, such as `cert-manager`, `cert-manager-webhook`, and `cert-manager-cainjector`.

## Status

```bash
./cert-manager-1.20.3-amd64.run status -n cert-manager

kubectl get pods,svc,deploy,job -n cert-manager -l app.kubernetes.io/instance=cert-manager
kubectl get crd | grep -E 'cert-manager.io|acme.cert-manager.io'
```

Check rollout:

```bash
kubectl rollout status deploy/cert-manager -n cert-manager
kubectl rollout status deploy/cert-manager-cainjector -n cert-manager
kubectl rollout status deploy/cert-manager-webhook -n cert-manager
kubectl logs -n cert-manager job/cert-manager-startupapicheck
```

## Smoke test

Create a self-signed ClusterIssuer:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
EOF
```

Create a test Certificate:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-cert-tls
  dnsNames:
  - test.example.local
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
EOF
```

Check:

```bash
kubectl get certificate -n default test-cert
kubectl get secret -n default test-cert-tls
```

Cleanup smoke test:

```bash
kubectl delete certificate -n default test-cert --ignore-not-found=true
kubectl delete clusterissuer selfsigned --ignore-not-found=true
```

## Uninstall

By default, uninstall deletes cert-manager runtime resources but keeps CRDs:

```bash
./cert-manager-1.20.3-amd64.run uninstall -n cert-manager -y
```

Delete CRDs too:

```bash
./cert-manager-1.20.3-amd64.run uninstall -n cert-manager --delete-crds -y
```

Be careful: deleting CRDs deletes cert-manager custom resources such as Certificates, Issuers, ClusterIssuers, CertificateRequests, Orders, and Challenges.

## Production notes

- Keep cert-manager private inside the cluster; it usually does not need NodePort or external exposure.
- For Alibaba Cloud DNS-01, install cert-manager first, then create the Aliyun DNS webhook/solver integration separately.
- Back up Kubernetes resources and TLS Secrets before deleting CRDs.
- If you use Gateway API HTTPRoutes for ACME HTTP-01, make sure Gateway API CRDs and a compatible Gateway controller are already installed.

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds both `amd64` and `arm64` artifacts on:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.
