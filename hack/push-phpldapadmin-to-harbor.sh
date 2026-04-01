#!/usr/bin/env bash
set -euo pipefail

# Pull phpldapadmin/phpldapadmin (PLA v2) and push to Harbor（可选 Web 管理；仓库示例清单不含 PLA，需自写 Deployment）。
#
# 用法：
#   export HARBOR_USERNAME=...
#   export HARBOR_PASSWORD=...
#   bash hack/push-phpldapadmin-to-harbor.sh
#
# 环境变量（可选）：
#   HARBOR_REGISTRY     默认 harbor.aix.com:8443
#   HARBOR_PROJECT      默认 library
#   PHPLDAPADMIN_TAG    默认 2.3.9（与 Hub 上 phpldapadmin/phpldapadmin 对齐）
#   SOURCE_IMAGE        默认 docker.io/phpldapadmin/phpldapadmin
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.aix.com:8443}"
HARBOR_PROJECT="${HARBOR_PROJECT:-library}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-Har#aix12345}"
PHPLDAPADMIN_TAG="${PHPLDAPADMIN_TAG:-2.3.9}"
SOURCE_IMAGE="${SOURCE_IMAGE:-docker.io/phpldapadmin/phpldapadmin}"
PULL_RETRIES="${PULL_RETRIES:-5}"
PUSH_RETRIES="${PUSH_RETRIES:-3}"

retry() {
  local max_attempts="$1"
  shift
  local attempt=1
  local delay=2

  until "$@"; do
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "Command failed after ${attempt} attempts: $*" >&2
      return 1
    fi
    echo "Attempt ${attempt}/${max_attempts} failed: $*" >&2
    echo "Retrying in ${delay}s ..." >&2
    sleep "${delay}"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

src="${SOURCE_IMAGE}:${PHPLDAPADMIN_TAG}"
dst="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/phpldapadmin:${PHPLDAPADMIN_TAG}"

if [[ -z "${HARBOR_PASSWORD}" ]]; then
  echo "HARBOR_PASSWORD is not set. Export it or run: docker login ${HARBOR_REGISTRY}" >&2
  exit 1
fi

echo "Logging in to ${HARBOR_REGISTRY} ..."
printf '%s' "${HARBOR_PASSWORD}" | docker login "${HARBOR_REGISTRY}" --username "${HARBOR_USERNAME}" --password-stdin

echo "Pulling ${src} ..."
retry "${PULL_RETRIES}" docker pull "${src}"

echo "Tagging ${src} -> ${dst} ..."
docker tag "${src}" "${dst}"

echo "Pushing ${dst} ..."
retry "${PUSH_RETRIES}" docker push "${dst}"

echo "Done. Set image in examples/openldap-bitnami-minimal.yaml to:"
echo "  ${dst}"
