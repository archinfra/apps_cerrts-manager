#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="cert-manager"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_NAMESPACE="cert-manager"
DEFAULT_WAIT_TIMEOUT="300s"
DEFAULT_IMAGE_PULL_POLICY="IfNotPresent"

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
  status       Show cert-manager resources and CRDs.
  uninstall    Delete cert-manager runtime resources. CRDs are kept unless --delete-crds is set.
  help         Show this help.

Options:
  --registry <repo-prefix>             Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>               Registry username for docker login.
  --registry-pass <pass>               Registry password for docker login.
  --skip-image-prepare                 Skip docker load/tag/push; still render images to --registry prefix.
  -n, --namespace <namespace>          Kubernetes namespace. Default: ${DEFAULT_NAMESPACE}
  --image-pull-policy <policy>         IfNotPresent, Always, or Never. Default: ${DEFAULT_IMAGE_PULL_POLICY}
  --wait-timeout <duration>            Wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --delete-crds                        During uninstall, also delete cert-manager CRDs. This deletes cert-manager custom resources.
  -y, --yes                            Do not ask for confirmation.
  -h, --help                           Show this help.

Example:
  ./cert-manager-1.20.3-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --registry-user admin \
    --registry-pass 'passw0rd' \
    -n cert-manager \
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
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} cert-manager in namespace '${NAMESPACE}'."
  if [[ "${ACTION}" == "uninstall" && "${DELETE_CRDS}" == "1" ]]; then
    echo "WARNING: --delete-crds will delete cert-manager CRDs and all cert-manager custom resources."
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
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

install_app() {
  need kubectl
  extract_payload
  confirm
  prepare_images
  local rendered
  rendered="$(render_manifest)"
  info "delete previous startupapicheck job if present"
  kubectl delete job cert-manager-startupapicheck -n "${NAMESPACE}" --ignore-not-found=true || true
  info "kubectl apply -f rendered manifest"
  kubectl apply -f "${rendered}"
  info "waiting for cert-manager CRDs"
  kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout="${WAIT_TIMEOUT}"
  kubectl wait --for=condition=Established crd/issuers.cert-manager.io --timeout="${WAIT_TIMEOUT}"
  kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout="${WAIT_TIMEOUT}"
  info "waiting for deployments"
  kubectl rollout status deployment/cert-manager -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl rollout status deployment/cert-manager-cainjector -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  kubectl rollout status deployment/cert-manager-webhook -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  info "waiting for startupapicheck job"
  kubectl wait --for=condition=Complete job/cert-manager-startupapicheck -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}" || true
  status_app
}

status_app() {
  need kubectl
  echo "Namespace: ${NAMESPACE}"
  kubectl get pods,svc,deploy,job -n "${NAMESPACE}" -l app.kubernetes.io/instance=cert-manager || true
  echo
  kubectl get crd | grep -E 'cert-manager.io|acme.cert-manager.io' || true
}

uninstall_app() {
  need kubectl
  extract_payload
  confirm
  local rendered delete_manifest
  rendered="$(render_manifest)"
  delete_manifest="${rendered}"
  if [[ "${DELETE_CRDS}" != "1" ]]; then
    delete_manifest="${WORKDIR}/rendered-cert-manager.no-crds.yaml"
    strip_crds "${rendered}" "${delete_manifest}"
    info "CRDs kept. Use --delete-crds only when you really want to delete cert-manager custom resources."
  fi
  info "kubectl delete -f rendered manifest"
  kubectl delete -f "${delete_manifest}" --ignore-not-found=true || true
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
