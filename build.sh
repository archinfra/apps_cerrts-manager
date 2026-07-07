#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="cert-manager"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
TAG="v${VERSION#v}"
DIST_DIR="${ROOT_DIR}/dist"
IMAGE_JSON="${ROOT_DIR}/images/image.json"
MANIFEST_URL="${MANIFEST_URL:-https://github.com/cert-manager/cert-manager/releases/download/${TAG}/cert-manager.yaml}"

usage() {
  cat <<USAGE
Usage: bash build.sh --arch amd64|arm64|all [--manifest-url <url>]

Build cert-manager offline .run installer packages.

Options:
  --arch <arch>            Target architecture: amd64, arm64, or all.
  --manifest-url <url>     cert-manager release manifest URL. Default: ${MANIFEST_URL}
  -h, --help               Show this help.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

ARCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --manifest-url) MANIFEST_URL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${ARCH}" ]] || die "--arch is required"
case "${ARCH}" in amd64|arm64|all) ;; *) die "--arch must be amd64, arm64, or all" ;; esac

need docker
need tar
need sha256sum
need python3
need curl

[[ -f "${ROOT_DIR}/install.sh" ]] || die "install.sh not found"
[[ -f "${IMAGE_JSON}" ]] || die "images/image.json not found"
grep -qx '__PAYLOAD_BELOW__' "${ROOT_DIR}/install.sh" || die "install.sh must contain a standalone __PAYLOAD_BELOW__ marker"
python3 -m json.tool "${IMAGE_JSON}" >/dev/null
bash -n "${ROOT_DIR}/install.sh"

arches=()
if [[ "${ARCH}" == "all" ]]; then
  arches=(amd64 arm64)
else
  arches=("${ARCH}")
fi

write_arch_image_json() {
  local arch="$1" out="$2"
  python3 - "${IMAGE_JSON}" "${arch}" "${out}" <<'PY'
import json, sys
src, arch, out = sys.argv[1:]
with open(src, 'r', encoding='utf-8') as f:
    data = json.load(f)
items = [x for x in data if x.get('arch') == arch]
if not items:
    raise SystemExit(f'no image entries for arch {arch}')
with open(out, 'w', encoding='utf-8') as f:
    json.dump(items, f, indent=2, ensure_ascii=False)
    f.write('\n')
PY
}

verify_manifest_images() {
  local manifest="$1" image_json="$2"
  python3 - "${manifest}" "${image_json}" <<'PY'
import json, re, sys
manifest, image_json = sys.argv[1:]
text = open(manifest, 'r', encoding='utf-8').read()
with open(image_json, 'r', encoding='utf-8') as f:
    images = json.load(f)
missing = []
for item in images:
    src = item['pull']
    if src not in text:
        missing.append(src)
if missing:
    raise SystemExit('manifest does not contain expected image references:\n' + '\n'.join(missing))
# Also ensure there are no unexpected quay.io/jetstack cert-manager images left outside our manifest list.
found = set(re.findall(r'quay\.io/jetstack/cert-manager-[A-Za-z0-9_.-]+:v[0-9]+\.[0-9]+\.[0-9]+', text))
expected = {x['pull'] for x in images}
extra = sorted(found - expected)
if extra:
    raise SystemExit('manifest contains unexpected cert-manager image references:\n' + '\n'.join(extra))
PY
}

build_one() {
  local arch="$1"
  local build_dir="${ROOT_DIR}/.build/${PACKAGE_NAME}-${arch}"
  local payload_dir="${build_dir}/payload"
  local payload_tar="${build_dir}/payload.tar.gz"
  local run_name="${PACKAGE_NAME}-${VERSION}-${arch}.run"
  local run_path="${DIST_DIR}/${run_name}"
  local manifest_path="${payload_dir}/manifests/cert-manager.yaml"

  echo ">>> building ${PACKAGE_NAME} ${TAG} for ${arch}"
  rm -rf "${build_dir}"
  mkdir -p "${payload_dir}/images" "${payload_dir}/manifests" "${payload_dir}/meta" "${DIST_DIR}"

  write_arch_image_json "${arch}" "${payload_dir}/images/image.json"

  echo ">>> downloading ${MANIFEST_URL}"
  curl -fsSL "${MANIFEST_URL}" -o "${manifest_path}"
  grep -q 'kind: CustomResourceDefinition' "${manifest_path}" || die "downloaded manifest does not look like cert-manager install YAML"
  verify_manifest_images "${manifest_path}" "${payload_dir}/images/image.json"

  printf 'name|tar_name|source_ref|load_ref|default_target_ref|platform\n' > "${payload_dir}/images/image-index.tsv"

  python3 - "${payload_dir}/images/image.json" <<'PY' | while IFS='|' read -r name image_arch platform pull tag tar_name; do
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
for item in data:
    fields = [item.get(k, '') for k in ('name', 'arch', 'platform', 'pull', 'tag', 'tar')]
    print('|'.join(fields))
PY
    [[ -n "${name}" ]] || die "image entry is missing name"
    [[ -n "${platform}" ]] || die "image ${name} is missing platform"
    [[ -n "${pull}" ]] || die "image ${name} is missing pull"
    [[ -n "${tag}" ]] || die "image ${name} is missing tag"
    [[ -n "${tar_name}" ]] || die "image ${name} is missing tar"

    echo ">>> docker pull --platform ${platform} ${pull}"
    docker pull --platform "${platform}" "${pull}"
    docker tag "${pull}" "${tag}"
    echo ">>> docker save ${tag} -> payload/images/${tar_name}"
    docker save -o "${payload_dir}/images/${tar_name}" "${tag}"
    printf '%s|%s|%s|%s|%s|%s\n' "${name}" "${tar_name}" "${pull}" "${tag}" "${tag}" "${platform}" >> "${payload_dir}/images/image-index.tsv"
  done

  cat > "${payload_dir}/meta/package.env" <<META
PACKAGE_NAME=${PACKAGE_NAME}
VERSION=${VERSION}
TAG=${TAG}
ARCH=${arch}
MANIFEST_URL=${MANIFEST_URL}
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META

  (cd "${payload_dir}" && tar -czf "${payload_tar}" .)
  tar -tzf "${payload_tar}" >/dev/null
  cat "${ROOT_DIR}/install.sh" "${payload_tar}" > "${run_path}"
  chmod +x "${run_path}"
  (cd "${DIST_DIR}" && sha256sum "${run_name}" > "${run_name}.sha256")
  echo ">>> wrote ${run_path}"
}

for a in "${arches[@]}"; do
  build_one "$a"
done

ls -lh "${DIST_DIR}"/*.run "${DIST_DIR}"/*.sha256
