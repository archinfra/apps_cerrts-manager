# apps_cerrts-manager

cert-manager Kubernetes offline `.run` installer package.

> Repository name follows the current upstream repository URL: `archinfra/apps_cerrts-manager`. The package and Kubernetes application name are standard `cert-manager`.

This package downloads the official cert-manager release manifest at build time, packages all required images into a self-extracting offline `.run`, retags and pushes those images to an internal registry at install time, rewrites the manifest image references, and deploys cert-manager on Kubernetes.

It can also optionally install an integrated AliDNS DNS01 webhook solver, create the Aliyun AK/SK Secret, create a Let’s Encrypt ClusterIssuer, and create a Certificate for a domain such as `weagent.cc` and `*.weagent.cc`.

## Version

- cert-manager: `v1.20.3`
- AliDNS webhook: `wjiec/alidns-webhook:v1.0.3`
- default namespace: `cert-manager`
- default registry prefix: `sealos.hub:5000/kube4`
- default image pull policy: `IfNotPresent`
- release manifest: `https://github.com/cert-manager/cert-manager/releases/download/v1.20.3/cert-manager.yaml`

The default cert-manager version is `v1.20.3`, the latest GitHub release when this package was created. The release notes mark it as a security patch release and say all users should upgrade.

## Images

The offline payload includes these images for each target architecture:

```text
quay.io/jetstack/cert-manager-controller:v1.20.3
quay.io/jetstack/cert-manager-cainjector:v1.20.3
quay.io/jetstack/cert-manager-webhook:v1.20.3
quay.io/jetstack/cert-manager-acmesolver:v1.20.3
docker.io/wjiec/alidns-webhook:v1.0.3
```

The `acmesolver` image is included because cert-manager dynamically creates ACME HTTP-01 solver Pods. Offline clusters need this image in the internal registry even though it is not a long-running Deployment.

The official `cert-manager.yaml` static release manifest does not include the Helm chart `startupapicheck` Job, so this offline package does not require or package `cert-manager-startupapicheck`.

Default retargeted images:

```text
sealos.hub:5000/kube4/jetstack/cert-manager-controller:v1.20.3
sealos.hub:5000/kube4/jetstack/cert-manager-cainjector:v1.20.3
sealos.hub:5000/kube4/jetstack/cert-manager-webhook:v1.20.3
sealos.hub:5000/kube4/jetstack/cert-manager-acmesolver:v1.20.3
sealos.hub:5000/kube4/wjiec/alidns-webhook:v1.0.3
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

When AliDNS is enabled, the installer also creates:

- Secret: `alidns-secret`, containing Aliyun AK/SK
- ServiceAccount: `alidns-webhook`
- RBAC for extension API server auth delegation, flowcontrol, secrets read, and domain solver access
- Issuer/Certificate resources for the webhook serving TLS certificate
- Service: `alidns-webhook`
- Deployment: `alidns-webhook`
- APIService: `v1alpha1.<groupName>`
- Optional ClusterIssuer: for example `letsencrypt-dns01-staging`
- Optional Certificate: for example `weagent-cc`, writing TLS cert to `weagent-cc-tls`

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
- common Linux base tools: `awk`, `head`, `wc`, `dd`, `od`, `tail`, `tar`, `sed`, `base64`
- `docker`, unless `--skip-image-prepare` is used
- `kubectl`
- optional `sha256sum`, only for checking the `.sha256` file before running the installer

The target host does **not** need `jq`, Python, curl, Helm, or Internet access.

## Help

Show all options, including AliDNS options:

```bash
./cert-manager-1.20.3-amd64.run -h
./cert-manager-1.20.3-amd64.run help
```

## Install cert-manager only

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

If the internal registry already contains all images:

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

## Install cert-manager + AliDNS for `weagent.cc`

Recommended first run: use Let’s Encrypt staging.

```bash
./cert-manager-1.20.3-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  -n cert-manager \
  --alidns-domain weagent.cc \
  --alidns-access-key-id 'YOUR_ALIYUN_ACCESS_KEY_ID' \
  --alidns-access-key-secret 'YOUR_ALIYUN_ACCESS_KEY_SECRET' \
  --alidns-email admin@weagent.cc \
  --alidns-staging \
  -y
```

This command automatically derives:

```text
groupName:                 acme.weagent.cc
ClusterIssuer:             letsencrypt-dns01-staging
Certificate name:          weagent-cc
Certificate namespace:     default
TLS Secret:                weagent-cc-tls
DNS names:                 weagent.cc, *.weagent.cc
ACME server:               https://acme-staging-v02.api.letsencrypt.org/directory
```

For production Let’s Encrypt:

```bash
./cert-manager-1.20.3-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -n cert-manager \
  --alidns-domain weagent.cc \
  --alidns-access-key-id 'YOUR_ALIYUN_ACCESS_KEY_ID' \
  --alidns-access-key-secret 'YOUR_ALIYUN_ACCESS_KEY_SECRET' \
  --alidns-email admin@weagent.cc \
  --alidns-prod \
  -y
```

If your Gateway is in another namespace, put the resulting TLS Secret there:

```bash
./cert-manager-1.20.3-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -n cert-manager \
  --alidns-domain weagent.cc \
  --alidns-access-key-id 'YOUR_ALIYUN_ACCESS_KEY_ID' \
  --alidns-access-key-secret 'YOUR_ALIYUN_ACCESS_KEY_SECRET' \
  --alidns-email admin@weagent.cc \
  --alidns-prod \
  --alidns-certificate-namespace envoy-gateway-system \
  --alidns-certificate-secret-name weagent-cc-tls \
  -y
```

The default `--alidns-wait-certificate false` means install does not block until Let’s Encrypt finishes DNS propagation and issuance. Check certificate status separately.

## AliDNS options

Important options:

```text
--enable-alidns-webhook
--alidns-access-key-id <ak>
--alidns-access-key-secret <sk>
--alidns-domain <domain>
--alidns-email <email>
--alidns-group-name <group>
--alidns-region <region>
--alidns-staging
--alidns-prod
--alidns-acme-server <url>
--alidns-issuer-name <name>
--alidns-create-issuer <true|false>
--alidns-create-certificate <true|false>
--alidns-certificate-namespace <ns>
--alidns-certificate-name <name>
--alidns-certificate-secret-name <name>
--alidns-wildcard <true|false>
--alidns-wait-certificate <true|false>
```

Rules:

- `--alidns-domain weagent.cc` automatically enables AliDNS.
- If `--alidns-group-name` is omitted, the installer uses `acme.<domain>`, for example `acme.weagent.cc`.
- If `--alidns-email` is omitted and domain is set, the installer uses `admin@<domain>`.
- If `--alidns-wildcard true`, the Certificate includes both `weagent.cc` and `*.weagent.cc`.
- If `--alidns-create-certificate false`, the installer only creates the webhook and ClusterIssuer.

## Status

```bash
./cert-manager-1.20.3-amd64.run status -n cert-manager

kubectl get pods,svc,deploy,job -n cert-manager -l app.kubernetes.io/instance=cert-manager
kubectl get pods,svc,deploy -n cert-manager -l app.kubernetes.io/instance=alidns-webhook
kubectl get apiservice | grep -E 'alidns|acme\.'
kubectl get clusterissuer
kubectl get certificate -A
kubectl get crd | grep -E 'cert-manager.io|acme.cert-manager.io'
```

Check rollout:

```bash
kubectl rollout status deploy/cert-manager -n cert-manager
kubectl rollout status deploy/cert-manager-cainjector -n cert-manager
kubectl rollout status deploy/cert-manager-webhook -n cert-manager
kubectl rollout status deploy/alidns-webhook -n cert-manager
```

Check certificate issuance:

```bash
kubectl describe certificate -n default weagent-cc
kubectl get order,challenge -A
kubectl describe challenge -A
kubectl logs -n cert-manager deploy/cert-manager
kubectl logs -n cert-manager deploy/alidns-webhook
```

## Smoke test without AliDNS

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

If AliDNS was installed by this package and you want to delete rendered AliDNS resources too, pass the same domain or groupName:

```bash
./cert-manager-1.20.3-amd64.run uninstall \
  -n cert-manager \
  --alidns-domain weagent.cc \
  -y
```

Delete CRDs too:

```bash
./cert-manager-1.20.3-amd64.run uninstall -n cert-manager --delete-crds -y
```

Be careful: deleting CRDs deletes cert-manager custom resources such as Certificates, Issuers, ClusterIssuers, CertificateRequests, Orders, and Challenges.

## Production notes

- Keep cert-manager private inside the cluster; it usually does not need NodePort or external exposure.
- For Alibaba Cloud DNS-01, the domain must be hosted in AliDNS or the AK/SK must be able to manage the DNS zone.
- Prefer a least-privilege RAM user that can manage TXT records for `_acme-challenge.weagent.cc`.
- Start with `--alidns-staging`, then switch to `--alidns-prod` after Challenge/Certificate flow is verified.
- Back up Kubernetes resources and TLS Secrets before deleting CRDs.
- If you use Gateway API HTTPRoutes for ACME HTTP-01, make sure Gateway API CRDs and a compatible Gateway controller are already installed.

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds both `amd64` and `arm64` artifacts on:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.
