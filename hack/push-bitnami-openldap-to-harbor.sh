#!/usr/bin/env bash
set -euo pipefail

# Pull bitnamilegacy/openldap and push to Harbor for examples/openldap-bitnami-minimal.yaml.
#
# 用法：
#   export HARBOR_USERNAME=...
#   export HARBOR_PASSWORD=...
#   bash hack/push-bitnami-openldap-to-harbor.sh
#
# 环境变量（可选）：
#   HARBOR_REGISTRY   默认 harbor.aix.com:8443
#   HARBOR_PROJECT    默认 library（与 examples/openldap-bitnami-minimal.yaml 中 Harbor 路径一致）
#   BITNAMI_OPENLDAP_TAG  默认 2.6.10-debian-12-r1
#   SOURCE_IMAGE      默认 docker.io/bitnamilegacy/openldap
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.aix.com:8443}"
HARBOR_PROJECT="${HARBOR_PROJECT:-library}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-Har#aix12345}"
BITNAMI_OPENLDAP_TAG="${BITNAMI_OPENLDAP_TAG:-2.6.10-debian-12-r1}"
SOURCE_IMAGE="${SOURCE_IMAGE:-docker.io/bitnamilegacy/openldap}"
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

src="${SOURCE_IMAGE}:${BITNAMI_OPENLDAP_TAG}"
dst="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/bitnami-openldap:${BITNAMI_OPENLDAP_TAG}"

if [[ -z "${HARBOR_PASSWORD}" ]]; then
  echo "HARBOR_PASSWORD is not set. Export it or run: docker login ${HARBOR_REGISTRY}" >&2
  exit 1
fi

echo "Logging in to ${HARBOR_REGISTRY} ..."
printf '%s' "${HARBOR_PASSWORD}" | docker login "${HARBOR_REGISTRY}" --username "${HARBOR_USERNAME}" --password-stdin

echo "Pulling ${src} ..."
retry "${PULL_RETRIES}" docker pull "${src}"

img_id="$(docker inspect --format '{{.Id}}' "${src}")"
echo "Source image Id: ${img_id}"
echo "  推送后 Harbor 显示的 digest 与 Docker Hub（687f14…）可能不同，属正常；Kubernetes 用 harbor 域名时应引用 Harbor 返回的 digest 或仅用 tag。"
echo "  校验：docker pull ${dst} && docker inspect --format '{{json .RepoDigests}}' ${dst}"

echo "Tagging ${src} -> ${dst} ..."
docker tag "${src}" "${dst}"

echo "Pushing ${dst} ..."
retry "${PUSH_RETRIES}" docker push "${dst}"

echo "Done. Set image in examples/openldap-bitnami-minimal.yaml to:"
echo "  ${dst}"
