#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="cert-manager"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_NAMESPACE="cert-manager"
DEFAULT_WAIT_TIMEOUT="300s"
DEFAULT_IMAGE_PULL_POLICY="IfNotPresent"
DEFAULT_ALIDNS_SECRET_NAME="alidns-secret"
DEFAULT_ALIDNS_REGION="cn-hangzhou"
DEFAULT_ALIDNS_ACME_ENV="staging"
DEFAULT_ALIDNS_CERTIFICATE_NAMESPACE="default"

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

REGISTRY="${DEFAULT_REGISTRY}"
REGISTRY_USER=""
REGISTRY_PASS=""
NAMESPACE="${DEFAULT_NAMESPACE}"
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
IMAGE_PULL_POLICY="${DEFAULT_IMAGE_PULL_POLICY}"
SKIP_IMAGE_PREPARE=0
YES=0
DELETE_CRDS=0

ALIDNS_ENABLED=0
ALIDNS_ACCESS_KEY_ID=""
ALIDNS_ACCESS_KEY_SECRET=""
ALIDNS_SECRET_NAME="${DEFAULT_ALIDNS_SECRET_NAME}"
ALIDNS_GROUP_NAME=""
ALIDNS_REGION="${DEFAULT_ALIDNS_REGION}"
ALIDNS_DOMAIN=""
ALIDNS_EMAIL=""
ALIDNS_ACME_ENV="${DEFAULT_ALIDNS_ACME_ENV}"
ALIDNS_ACME_SERVER=""
ALIDNS_CREATE_ISSUER="auto"
ALIDNS_CREATE_CERTIFICATE="auto"
ALIDNS_CERTIFICATE_NAMESPACE="${DEFAULT_ALIDNS_CERTIFICATE_NAMESPACE}"
ALIDNS_CERTIFICATE_NAME=""
ALIDNS_CERTIFICATE_SECRET_NAME=""
ALIDNS_ISSUER_NAME=""
ALIDNS_WILDCARD="true"
ALIDNS_WAIT_CERTIFICATE="false"

WORKDIR=""
IMAGE_INDEX=""

usage() {
  cat <<USAGE
Usage:
  ./cert-manager-<version>-<arch>.run install [options]
  ./cert-manager-<version>-<arch>.run status [options]
  ./cert-manager-<version>-<arch>.run uninstall [options]
  ./cert-manager-<version>-<arch>.run help

Actions:
  install      Extract payload, load/tag/push images, retarget release manifest, and install cert-manager.
               Optional: install AliDNS DNS01 webhook, ClusterIssuer, and Certificate.
  status       Show cert-manager, optional AliDNS webhook resources, and CRDs.
  uninstall    Delete cert-manager runtime resources. CRDs are kept unless --delete-crds is set.
               If --enable-alidns-webhook or --alidns-domain is set, also delete rendered AliDNS resources.
  help         Show this help.

Core options:
  --registry <repo-prefix>                 Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>                   Registry username for docker login.
  --registry-pass <pass>                   Registry password for docker login.
  --skip-image-prepare                     Skip docker load/tag/push; still render images to --registry prefix.
  -n, --namespace <namespace>              cert-manager namespace. Default: ${DEFAULT_NAMESPACE}
  --image-pull-policy <policy>             IfNotPresent, Always, or Never. Default: ${DEFAULT_IMAGE_PULL_POLICY}
  --wait-timeout <duration>                Wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --delete-crds                            During uninstall, also delete cert-manager CRDs. This deletes cert-manager custom resources.
  -y, --yes                                Do not ask for confirmation.
  -h, --help                               Show this help.

AliDNS DNS01 options:
  --enable-alidns-webhook                  Install AliDNS DNS01 webhook and configure cert-manager solver.
  --alidns-access-key-id <ak>              Aliyun AccessKeyId. Required for AliDNS install.
  --alidns-access-key-secret <sk>          Aliyun AccessKeySecret. Required for AliDNS install.
  --alidns-secret-name <name>              Secret name for AK/SK. Default: ${DEFAULT_ALIDNS_SECRET_NAME}
  --alidns-domain <domain>                 DNS zone / certificate domain, for example weagent.cc. Also enables AliDNS.
  --alidns-email <email>                   ACME account email. Default when domain is set: admin@<domain>
  --alidns-group-name <group>              Webhook API groupName. Default when domain is set: acme.<domain>
  --alidns-region <region>                 AliDNS region passed to solver. Default: ${DEFAULT_ALIDNS_REGION}
  --alidns-staging                         Use Let's Encrypt staging ACME server. Default.
  --alidns-prod                            Use Let's Encrypt production ACME server.
  --alidns-acme-server <url>               Explicit ACME directory URL. Overrides --alidns-staging/--alidns-prod.
  --alidns-issuer-name <name>              ClusterIssuer name. Default: letsencrypt-dns01-<staging|prod>
  --alidns-create-issuer <true|false>      Create ClusterIssuer. Default: true when --alidns-domain is set.
  --alidns-create-certificate <true|false> Create Certificate for domain. Default: true when --alidns-domain is set.
  --alidns-certificate-namespace <ns>      Namespace for Certificate and resulting TLS Secret. Default: ${DEFAULT_ALIDNS_CERTIFICATE_NAMESPACE}
  --alidns-certificate-name <name>         Certificate resource name. Default: <domain-with-dashes>
  --alidns-certificate-secret-name <name>  TLS Secret name. Default: <domain-with-dashes>-tls
  --alidns-wildcard <true|false>           Also request *.<domain>. Default: true
  --alidns-wait-certificate <true|false>   Wait for Certificate Ready during install. Default: false

Example: install cert-manager only:
  ./cert-manager-1.20.3-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --registry-user admin \
    --registry-pass 'passw0rd' \
    -n cert-manager \
    -y

Example: install cert-manager + AliDNS DNS01 + staging Certificate for weagent.cc:
  ./cert-manager-1.20.3-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    -n cert-manager \
    --alidns-domain weagent.cc \
    --alidns-access-key-id 'YOUR_AK' \
    --alidns-access-key-secret 'YOUR_SK' \
    --alidns-email admin@weagent.cc \
    --alidns-staging \
    -y

Example: switch to production ACME:
  ./cert-manager-1.20.3-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --skip-image-prepare \
    -n cert-manager \
    --alidns-domain weagent.cc \
    --alidns-access-key-id 'YOUR_AK' \
    --alidns-access-key-secret 'YOUR_SK' \
    --alidns-email admin@weagent.cc \
    --alidns-prod \
    -y
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
    --registry-pass|--registry-password) REGISTRY_PASS="${2:-}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGE_PREPARE=1; shift ;;
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --image-pull-policy) IMAGE_PULL_POLICY="${2:-}"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --delete-crds) DELETE_CRDS=1; shift ;;
    --enable-alidns-webhook|--alidns-enable) ALIDNS_ENABLED=1; shift ;;
    --alidns-access-key-id) ALIDNS_ACCESS_KEY_ID="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-access-key-secret) ALIDNS_ACCESS_KEY_SECRET="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-secret-name) ALIDNS_SECRET_NAME="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-domain) ALIDNS_DOMAIN="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-email) ALIDNS_EMAIL="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-group-name) ALIDNS_GROUP_NAME="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-region) ALIDNS_REGION="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-staging) ALIDNS_ACME_ENV="staging"; ALIDNS_ENABLED=1; shift ;;
    --alidns-prod|--alidns-production) ALIDNS_ACME_ENV="prod"; ALIDNS_ENABLED=1; shift ;;
    --alidns-acme-server) ALIDNS_ACME_SERVER="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-issuer-name) ALIDNS_ISSUER_NAME="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-create-issuer) ALIDNS_CREATE_ISSUER="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-create-certificate) ALIDNS_CREATE_CERTIFICATE="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-certificate-namespace) ALIDNS_CERTIFICATE_NAMESPACE="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-certificate-name) ALIDNS_CERTIFICATE_NAME="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-certificate-secret-name) ALIDNS_CERTIFICATE_SECRET_NAME="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-wildcard) ALIDNS_WILDCARD="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    --alidns-wait-certificate) ALIDNS_WAIT_CERTIFICATE="${2:-}"; ALIDNS_ENABLED=1; shift 2 ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi

[[ -n "${REGISTRY}" ]] || die "--registry cannot be empty"
[[ -n "${NAMESPACE}" ]] || die "--namespace cannot be empty"
case "${IMAGE_PULL_POLICY}" in IfNotPresent|Always|Never) ;; *) die "--image-pull-policy must be IfNotPresent, Always, or Never" ;; esac
case "${ALIDNS_ACME_ENV}" in staging|prod) ;; *) die "--alidns-staging/--alidns-prod resolved to unsupported env: ${ALIDNS_ACME_ENV}" ;; esac
case "${ALIDNS_CREATE_ISSUER}" in auto|true|false) ;; *) die "--alidns-create-issuer must be true or false" ;; esac
case "${ALIDNS_CREATE_CERTIFICATE}" in auto|true|false) ;; *) die "--alidns-create-certificate must be true or false" ;; esac
case "${ALIDNS_WILDCARD}" in true|false) ;; *) die "--alidns-wildcard must be true or false" ;; esac
case "${ALIDNS_WAIT_CERTIFICATE}" in true|false) ;; *) die "--alidns-wait-certificate must be true or false" ;; esac

normalize_alidns_defaults() {
  [[ -n "${ALIDNS_DOMAIN}" ]] && ALIDNS_ENABLED=1
  if [[ "${ALIDNS_ENABLED}" != "1" ]]; then
    return 0
  fi

  if [[ -n "${ALIDNS_DOMAIN}" ]]; then
    [[ -n "${ALIDNS_GROUP_NAME}" ]] || ALIDNS_GROUP_NAME="acme.${ALIDNS_DOMAIN}"
    [[ -n "${ALIDNS_EMAIL}" ]] || ALIDNS_EMAIL="admin@${ALIDNS_DOMAIN}"
    if [[ "${ALIDNS_CREATE_ISSUER}" == "auto" ]]; then ALIDNS_CREATE_ISSUER="true"; fi
    if [[ "${ALIDNS_CREATE_CERTIFICATE}" == "auto" ]]; then ALIDNS_CREATE_CERTIFICATE="true"; fi
  else
    if [[ "${ALIDNS_CREATE_ISSUER}" == "auto" ]]; then ALIDNS_CREATE_ISSUER="false"; fi
    if [[ "${ALIDNS_CREATE_CERTIFICATE}" == "auto" ]]; then ALIDNS_CREATE_CERTIFICATE="false"; fi
  fi

  if [[ -z "${ALIDNS_ACME_SERVER}" ]]; then
    if [[ "${ALIDNS_ACME_ENV}" == "prod" ]]; then
      ALIDNS_ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
    else
      ALIDNS_ACME_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
    fi
  fi
  [[ -n "${ALIDNS_ISSUER_NAME}" ]] || ALIDNS_ISSUER_NAME="letsencrypt-dns01-${ALIDNS_ACME_ENV}"
  if [[ -n "${ALIDNS_DOMAIN}" ]]; then
    local domain_name
    domain_name="$(printf '%s' "${ALIDNS_DOMAIN}" | sed -E 's/^\*\.//; s/[^A-Za-z0-9]+/-/g; s/^-+//; s/-+$//')"
    [[ -n "${ALIDNS_CERTIFICATE_NAME}" ]] || ALIDNS_CERTIFICATE_NAME="${domain_name}"
    [[ -n "${ALIDNS_CERTIFICATE_SECRET_NAME}" ]] || ALIDNS_CERTIFICATE_SECRET_NAME="${domain_name}-tls"
  fi
}

normalize_alidns_defaults

if [[ "${ACTION}" == "install" && "${ALIDNS_ENABLED}" == "1" ]]; then
  [[ -n "${ALIDNS_ACCESS_KEY_ID}" ]] || die "--alidns-access-key-id is required when AliDNS is enabled"
  [[ -n "${ALIDNS_ACCESS_KEY_SECRET}" ]] || die "--alidns-access-key-secret is required when AliDNS is enabled"
  [[ -n "${ALIDNS_GROUP_NAME}" ]] || die "--alidns-group-name is required when AliDNS is enabled without --alidns-domain"
  if [[ "${ALIDNS_CREATE_ISSUER}" == "true" || "${ALIDNS_CREATE_CERTIFICATE}" == "true" ]]; then
    [[ -n "${ALIDNS_DOMAIN}" ]] || die "--alidns-domain is required when creating issuer or certificate"
    [[ -n "${ALIDNS_EMAIL}" ]] || die "--alidns-email is required when creating issuer"
  fi
  if [[ "${ALIDNS_CREATE_CERTIFICATE}" == "true" && "${ALIDNS_CREATE_ISSUER}" != "true" ]]; then
    die "--alidns-create-certificate true requires --alidns-create-issuer true"
  fi
fi

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  WORKDIR="$(mktemp -d -t ${PACKAGE_NAME}.XXXXXX)"
  IMAGE_INDEX="${WORKDIR}/images/image-index.tsv"
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "failed to extract payload"
  [[ -f "${IMAGE_INDEX}" ]] || die "payload missing images/image-index.tsv"
  [[ -f "${WORKDIR}/manifests/cert-manager.yaml" ]] || die "payload missing manifests/cert-manager.yaml"
  if [[ "${ALIDNS_ENABLED}" == "1" ]]; then
    [[ -f "${WORKDIR}/manifests/alidns-webhook.yaml.tmpl" ]] || die "payload missing manifests/alidns-webhook.yaml.tmpl; rebuild the .run package"
  fi
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} cert-manager in namespace '${NAMESPACE}'."
  if [[ "${ALIDNS_ENABLED}" == "1" ]]; then
    echo "AliDNS webhook enabled: groupName=${ALIDNS_GROUP_NAME}, domain=${ALIDNS_DOMAIN:-n/a}, issuer=${ALIDNS_ISSUER_NAME}, acme-env=${ALIDNS_ACME_ENV}"
  fi
  if [[ "${ACTION}" == "uninstall" && "${DELETE_CRDS}" == "1" ]]; then
    echo "WARNING: --delete-crds will delete cert-manager CRDs and all cert-manager custom resources."
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

retarget_image() {
  local default_ref="$1"
  local suffix
  if [[ "${default_ref}" == sealos.hub:5000/kube4/* ]]; then
    suffix="${default_ref#sealos.hub:5000/kube4/}"
  else
    suffix="${default_ref#*/}"
  fi
  printf '%s/%s\n' "${REGISTRY%/}" "${suffix}"
}

image_ref_by_name() {
  local wanted="$1"
  awk -F'|' -v name="${wanted}" 'NR > 1 && $1 == name { print $5; exit }' "${IMAGE_INDEX}"
}

target_ref_by_name() {
  local wanted="$1" default_ref
  default_ref="$(image_ref_by_name "${wanted}")"
  [[ -n "${default_ref}" ]] || die "image not found in payload index: ${wanted}"
  retarget_image "${default_ref}"
}

prepare_images() {
  [[ "${SKIP_IMAGE_PREPARE}" == "1" ]] && { info "skip image prepare"; return 0; }
  need docker

  if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
    [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "both --registry-user and --registry-pass are required for docker login"
    local login_host="${REGISTRY%%/*}"
    info "docker login ${login_host}"
    printf '%s' "${REGISTRY_PASS}" | docker login "${login_host}" -u "${REGISTRY_USER}" --password-stdin
  fi

  tail -n +2 "${IMAGE_INDEX}" | while IFS='|' read -r name tar_name source_ref load_ref default_ref platform; do
    [[ -n "${name}" ]] || continue
    local tar_path="${WORKDIR}/images/${tar_name}"
    local target_ref
    [[ -f "${tar_path}" ]] || die "image tar not found: ${tar_path}"
    target_ref="$(retarget_image "${default_ref}")"
    info "docker load ${tar_name}"
    docker load -i "${tar_path}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      info "docker tag ${load_ref} ${target_ref}"
      docker tag "${load_ref}" "${target_ref}"
    fi
    info "docker push ${target_ref}"
    docker push "${target_ref}"
  done
}

rewrite_namespace() {
  local input="$1" output="$2"
  awk -v ns="${NAMESPACE}" '
    BEGIN { in_ns_doc = 0 }
    /^---[[:space:]]*$/ { in_ns_doc = 0; print; next }
    /^kind:[[:space:]]*Namespace[[:space:]]*$/ { in_ns_doc = 1; print; next }
    in_ns_doc == 1 && /^[[:space:]]*name:[[:space:]]*cert-manager[[:space:]]*$/ {
      sub(/cert-manager[[:space:]]*$/, ns)
      print
      next
    }
    /^[[:space:]]*namespace:[[:space:]]*cert-manager[[:space:]]*$/ {
      sub(/cert-manager[[:space:]]*$/, ns)
      print
      next
    }
    { print }
  ' "${input}" > "${output}"
}

strip_crds() {
  local input="$1" output="$2"
  awk '
    BEGIN { doc = ""; sep = "" }
    function flush_doc() {
      if (doc != "" && doc !~ /(^|\n)kind:[[:space:]]*CustomResourceDefinition(\n|$)/) {
        printf "%s%s", sep, doc
        sep = "---\n"
      }
      doc = ""
    }
    /^---[[:space:]]*$/ { flush_doc(); next }
    { doc = doc $0 "\n" }
    END { flush_doc() }
  ' "${input}" > "${output}"
}

render_manifest() {
  local src tmp rendered source_ref default_ref target_ref
  src="${WORKDIR}/manifests/cert-manager.yaml"
  tmp="${WORKDIR}/rendered-cert-manager.tmp.yaml"
  rendered="${WORKDIR}/rendered-cert-manager.yaml"
  rewrite_namespace "${src}" "${tmp}"

  tail -n +2 "${IMAGE_INDEX}" | while IFS='|' read -r name tar_name source_ref load_ref default_ref platform; do
    [[ -n "${name}" ]] || continue
    target_ref="$(retarget_image "${default_ref}")"
    sed -i "s|$(escape_sed "${source_ref}")|$(escape_sed "${target_ref}")|g" "${tmp}"
  done

  sed -E "s|^([[:space:]]*)imagePullPolicy:[[:space:]].*$|\\1imagePullPolicy: ${IMAGE_PULL_POLICY}|" "${tmp}" > "${rendered}"
  printf '%s\n' "${rendered}"
}

render_alidns_manifest() {
  need base64
  local src rendered alidns_image wildcard_line
  src="${WORKDIR}/manifests/alidns-webhook.yaml.tmpl"
  rendered="${WORKDIR}/rendered-alidns-webhook.yaml"
  alidns_image="$(target_ref_by_name alidns-webhook)"
  wildcard_line=""
  if [[ "${ALIDNS_WILDCARD}" == "true" && -n "${ALIDNS_DOMAIN}" ]]; then
    wildcard_line="  - $(yaml_quote "*.${ALIDNS_DOMAIN}")"
  fi

  awk \
    -v ns="${NAMESPACE}" \
    -v image="${alidns_image}" \
    -v image_pull_policy="${IMAGE_PULL_POLICY}" \
    -v ak_b64="$(b64 "${ALIDNS_ACCESS_KEY_ID}")" \
    -v sk_b64="$(b64 "${ALIDNS_ACCESS_KEY_SECRET}")" \
    -v secret_name="${ALIDNS_SECRET_NAME}" \
    -v group_name="${ALIDNS_GROUP_NAME}" \
    -v group_name_quoted="$(yaml_quote "${ALIDNS_GROUP_NAME}")" \
    -v region_quoted="$(yaml_quote "${ALIDNS_REGION}")" \
    -v domain_quoted="$(yaml_quote "${ALIDNS_DOMAIN}")" \
    -v email_quoted="$(yaml_quote "${ALIDNS_EMAIL}")" \
    -v acme_server_quoted="$(yaml_quote "${ALIDNS_ACME_SERVER}")" \
    -v issuer_name="${ALIDNS_ISSUER_NAME}" \
    -v create_issuer="${ALIDNS_CREATE_ISSUER}" \
    -v create_certificate="${ALIDNS_CREATE_CERTIFICATE}" \
    -v cert_ns="${ALIDNS_CERTIFICATE_NAMESPACE}" \
    -v cert_name="${ALIDNS_CERTIFICATE_NAME}" \
    -v cert_secret_name="${ALIDNS_CERTIFICATE_SECRET_NAME}" \
    -v wildcard_line="${wildcard_line}" \
    '
      /__ALIDNS_ISSUER_START__/ { if (create_issuer != "true") skip_issuer=1; next }
      /__ALIDNS_ISSUER_END__/ { skip_issuer=0; next }
      skip_issuer == 1 { next }
      /__ALIDNS_CERTIFICATE_START__/ { if (create_certificate != "true") skip_certificate=1; next }
      /__ALIDNS_CERTIFICATE_END__/ { skip_certificate=0; next }
      skip_certificate == 1 { next }
      /__ALIDNS_WILDCARD_DNS_NAME_LINE__/ { if (wildcard_line != "") print wildcard_line; next }
      {
        gsub(/__NAMESPACE__/, ns)
        gsub(/__ALIDNS_WEBHOOK_IMAGE__/, image)
        gsub(/__IMAGE_PULL_POLICY__/, image_pull_policy)
        gsub(/__ALIDNS_ACCESS_KEY_ID_B64__/, ak_b64)
        gsub(/__ALIDNS_ACCESS_KEY_SECRET_B64__/, sk_b64)
        gsub(/__ALIDNS_SECRET_NAME__/, secret_name)
        gsub(/__ALIDNS_GROUP_NAME_QUOTED__/, group_name_quoted)
        gsub(/__ALIDNS_GROUP_NAME__/, group_name)
        gsub(/__ALIDNS_REGION_QUOTED__/, region_quoted)
        gsub(/__ALIDNS_DOMAIN_QUOTED__/, domain_quoted)
        gsub(/__ALIDNS_EMAIL_QUOTED__/, email_quoted)
        gsub(/__ALIDNS_ACME_SERVER_QUOTED__/, acme_server_quoted)
        gsub(/__ALIDNS_ISSUER_NAME__/, issuer_name)
        gsub(/__ALIDNS_CERTIFICATE_NAMESPACE__/, cert_ns)
        gsub(/__ALIDNS_CERTIFICATE_NAME__/, cert_name)
        gsub(/__ALIDNS_CERTIFICATE_SECRET_NAME__/, cert_secret_name)
        print
      }
    ' "${src}" > "${rendered}"

  printf '%s\n' "${rendered}"
}

install_alidns() {
  [[ "${ALIDNS_ENABLED}" == "1" ]] || return 0
  local rendered
  rendered="$(render_alidns_manifest)"
  info "kubectl apply -f rendered AliDNS webhook manifest"
  kubectl apply -f "${rendered}"
  info "waiting for deployment/alidns-webhook"
  kubectl rollout status deployment/alidns-webhook -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  info "waiting for APIService/v1alpha1.${ALIDNS_GROUP_NAME}"
  kubectl wait --for=condition=Available "apiservice/v1alpha1.${ALIDNS_GROUP_NAME}" --timeout="${WAIT_TIMEOUT}"
  if [[ "${ALIDNS_CREATE_ISSUER}" == "true" ]]; then
    kubectl get clusterissuer "${ALIDNS_ISSUER_NAME}" || true
  fi
  if [[ "${ALIDNS_CREATE_CERTIFICATE}" == "true" ]]; then
    kubectl get certificate -n "${ALIDNS_CERTIFICATE_NAMESPACE}" "${ALIDNS_CERTIFICATE_NAME}" || true
    if [[ "${ALIDNS_WAIT_CERTIFICATE}" == "true" ]]; then
      kubectl wait --for=condition=Ready "certificate/${ALIDNS_CERTIFICATE_NAME}" -n "${ALIDNS_CERTIFICATE_NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
    else
      info "certificate wait skipped; check later with: kubectl describe certificate -n ${ALIDNS_CERTIFICATE_NAMESPACE} ${ALIDNS_CERTIFICATE_NAME}"
    fi
  fi
}

install_app() {
  need kubectl
  extract_payload
  confirm
  prepare_images
  local rendered
  rendered="$(render_manifest)"
  info "kubectl apply -f rendered cert-manager manifest"
  kubectl apply -f "${rendered}"
  info "waiting for cert-manager CRDs"
  kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout="${WAIT_TIMEOUT}"
  kubectl wait --for=condition=Established crd/issuers.cert-manager.io --timeout="${WAIT_TIMEOUT}"
  kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout="${WAIT_TIMEOUT}"
  info "waiting for cert-manager deployments"
  kubectl rollout status deployment/cert-manager -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl rollout status deployment/cert-manager-cainjector -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl rollout status deployment/cert-manager-webhook -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  install_alidns
  status_app
}

status_app() {
  need kubectl
  echo "Namespace: ${NAMESPACE}"
  kubectl get pods,svc,deploy,job -n "${NAMESPACE}" -l app.kubernetes.io/instance=cert-manager || true
  kubectl get pods,svc,deploy -n "${NAMESPACE}" -l app.kubernetes.io/instance=alidns-webhook || true
  echo
  kubectl get apiservice | grep -E 'alidns|acme\.' || true
  echo
  kubectl get clusterissuer 2>/dev/null || true
  echo
  kubectl get crd | grep -E 'cert-manager.io|acme.cert-manager.io' || true
}

uninstall_alidns() {
  [[ "${ALIDNS_ENABLED}" == "1" ]] || return 0
  local rendered
  rendered="$(render_alidns_manifest)"
  info "kubectl delete -f rendered AliDNS webhook manifest"
  kubectl delete -f "${rendered}" --ignore-not-found=true || true
}

uninstall_app() {
  need kubectl
  extract_payload
  confirm
  local rendered delete_manifest
  uninstall_alidns
  rendered="$(render_manifest)"
  delete_manifest="${rendered}"
  if [[ "${DELETE_CRDS}" != "1" ]]; then
    delete_manifest="${WORKDIR}/rendered-cert-manager.no-crds.yaml"
    strip_crds "${rendered}" "${delete_manifest}"
    info "CRDs kept. Use --delete-crds only when you really want to delete cert-manager custom resources."
  fi
  info "kubectl delete -f rendered cert-manager manifest"
  kubectl delete -f "${delete_manifest}" --ignore-not-found=true || true
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
