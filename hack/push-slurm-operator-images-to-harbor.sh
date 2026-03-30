#!/usr/bin/env bash
set -euo pipefail

# Pull Slurm Operator + Slurm workload images and push to Harbor.
# Override defaults with env vars when needed.
#
# Operator / webhook image tags:
#   helm/slurm-operator templates use .Values.*.image.tag, defaulting to Chart.Version
#   when tag is empty (see templates/_operator.tpl). Keep OPERATOR_VERSION in sync with
#   helm/slurm-operator/Chart.yaml "version" (e.g. 1.1.0-rc1 on release-1.1).
#   Older charts used 1.0.2 — wrong tag => ErrImagePull on harbor.aix.com/.../slurm-operator:...
#
# Slurm component images (slurmctld, login, …):
#   Default tag is SLINKY_VERSION (Slurm container tag, e.g. 25.11-ubuntu24.04).
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.aix.com:8443}"
HARBOR_PROJECT="${HARBOR_PROJECT:-slinkyproject}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-Har#aix12345}"
PULL_RETRIES="${PULL_RETRIES:-5}"
PUSH_RETRIES="${PUSH_RETRIES:-3}"
SLINKY_VERSION="${SLINKY_VERSION:-25.11-ubuntu24.04}"
OPERATOR_VERSION="${OPERATOR_VERSION:-1.1.0-rc1-jwtfix}"
# Comma-separated image list to append, e.g.
# EXTRA_SOURCE_IMAGES="quay.io/jetstack/cert-manager-controller:v1.15.0,ghcr.io/foo/bar:latest"
EXTRA_SOURCE_IMAGES="${EXTRA_SOURCE_IMAGES:-}"

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

SOURCE_IMAGES=(
  # slurm-operator chart images
  "ghcr.io/slinkyproject/slurm-operator:${OPERATOR_VERSION}"
  "ghcr.io/slinkyproject/slurm-operator-webhook:${OPERATOR_VERSION}"

  # slurm chart default images
  "ghcr.io/slinkyproject/slurmctld:${SLINKY_VERSION}"
  "ghcr.io/slinkyproject/slurmd:${SLINKY_VERSION}"
  "ghcr.io/slinkyproject/slurmrestd:${SLINKY_VERSION}"
  "ghcr.io/slinkyproject/slurmdbd:${SLINKY_VERSION}"
  "ghcr.io/slinkyproject/login:${SLINKY_VERSION}"
  "docker.io/library/alpine:latest"
)

if [[ -n "${EXTRA_SOURCE_IMAGES}" ]]; then
  IFS=',' read -r -a extra_images <<< "${EXTRA_SOURCE_IMAGES}"
  for image in "${extra_images[@]}"; do
    image="$(echo "${image}" | xargs)"
    [[ -n "${image}" ]] && SOURCE_IMAGES+=("${image}")
  done
fi

echo "Logging in to ${HARBOR_REGISTRY} ..."
printf '%s' "${HARBOR_PASSWORD}" | docker login "${HARBOR_REGISTRY}" --username "${HARBOR_USERNAME}" --password-stdin

declare -A seen_images=()
for src in "${SOURCE_IMAGES[@]}"; do
  if [[ -n "${seen_images[${src}]:-}" ]]; then
    continue
  fi
  seen_images["${src}"]=1

  image_name_with_tag="${src##*/}" # e.g. slurm-operator:1.0.2
  dst="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${image_name_with_tag}"

  echo "Pulling ${src} ..."
  retry "${PULL_RETRIES}" docker pull "${src}"

  echo "Tagging ${src} -> ${dst} ..."
  docker tag "${src}" "${dst}"

  echo "Pushing ${dst} ..."
  retry "${PUSH_RETRIES}" docker push "${dst}"
done

echo "Done. Images pushed to ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
