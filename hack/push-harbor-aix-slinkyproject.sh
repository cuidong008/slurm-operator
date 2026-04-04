#!/usr/bin/env bash
# 在 slurm-operator 仓库根目录执行：用普通 docker build（host 网络）构建 manager + webhook 并 push 到 Harbor。
# 默认：harbor.aix.com:8443/slinkyproject/slurm-operator:1.1.0-rc1-fix2
#       harbor.aix.com:8443/slinkyproject/slurm-operator-webhook:1.1.0-rc1-fix2
#
# 依赖：docker；需已 docker login harbor；建议 DOCKER_BUILDKIT=1（默认脚本会开启）
#
# 用法：
#   ./hack/push-harbor-aix-slinkyproject.sh
#   REGISTRY=harbor.example.com:443/myproject VERSION=mytag ./hack/push-harbor-aix-slinkyproject.sh
#
# 代理（与你在终端里直接 docker build 的习惯一致）：
#   USE_LOCAL_PROXY=1 ./hack/push-harbor-aix-slinkyproject.sh
# 或：
#   export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
# 脚本会同步 HTTP_PROXY/HTTPS_PROXY，BuildKit 的 RUN 会用到；拉基础镜像仍走 dockerd，必要时在 daemon 里配代理或 mirror。
#
# Go 模块：脚本默认 GOPROXY=https://goproxy.cn,direct、GOSUMDB=sum.golang.google.cn（避免走 proxy.golang.org 超时）；可 export 覆盖。
# 基础镜像可覆盖（默认 DaoCloud 代理 Docker Hub 的 library/golang）：
#   GO_BUILDER_IMAGE=golang:1.26 …
#   GO_BUILDER_IMAGE=harbor.aix.com:8443/slinkyproject/golang:1.26 …
# 可选：PLATFORM=linux/amd64（交叉构建时）
#
# 若拉/推 Harbor 报错：http: server gave HTTP response to HTTPS client
#   在 /etc/docker/daemon.json 增加 insecure-registries 后重启 Docker，例如：
#     { "insecure-registries": ["harbor.aix.com:8443"] }

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REGISTRY="${REGISTRY:-harbor.aix.com:8443/slinkyproject}"
VERSION="${VERSION:-1.1.0-rc1-fix2}"
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"
USE_LOCAL_PROXY="${USE_LOCAL_PROXY:-}"
PLATFORM="${PLATFORM:-}"

if ! "$CONTAINER_TOOL" version >/dev/null 2>&1; then
  echo "需要 docker" >&2
  exit 1
fi

export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"

if [[ "$USE_LOCAL_PROXY" == "1" || "$USE_LOCAL_PROXY" == "true" ]]; then
  export http_proxy="${http_proxy:-http://127.0.0.1:7890}"
  export https_proxy="${https_proxy:-http://127.0.0.1:7890}"
  export all_proxy="${all_proxy:-socks5://127.0.0.1:7890}"
fi

if [[ -n "${https_proxy:-}" || -n "${http_proxy:-}" || -n "${HTTPS_PROXY:-}" || -n "${HTTP_PROXY:-}" ]]; then
  export HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
  export HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-}}}"
  export ALL_PROXY="${ALL_PROXY:-${all_proxy:-}}"
  export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,.local}"
fi

export GO_BUILDER_IMAGE="${GO_BUILDER_IMAGE:-docker.m.daocloud.io/library/golang:1.26}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"

OPERATOR_TAG="${REGISTRY}/slurm-operator:${VERSION}"
WEBHOOK_TAG="${REGISTRY}/slurm-operator-webhook:${VERSION}"

echo ">>> REGISTRY=$REGISTRY VERSION=$VERSION"
echo ">>> GO_BUILDER_IMAGE=$GO_BUILDER_IMAGE"
echo ">>> GOPROXY=$GOPROXY GOSUMDB=$GOSUMDB"
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  echo ">>> HTTPS_PROXY=$HTTPS_PROXY"
fi

BUILD_ARGS=(
  --build-arg "GO_BUILDER_IMAGE=${GO_BUILDER_IMAGE}"
  --build-arg "GOPROXY=${GOPROXY}"
  --build-arg "GOSUMDB=${GOSUMDB}"
)

PLATFORM_ARGS=()
if [[ -n "$PLATFORM" ]]; then
  PLATFORM_ARGS+=(--platform "$PLATFORM")
fi

# 与手动 docker build 一致：host 网络 + 当前环境代理
"$CONTAINER_TOOL" build --network host "${PLATFORM_ARGS[@]}" "${BUILD_ARGS[@]}" \
  -f Dockerfile --target manager -t "$OPERATOR_TAG" .

"$CONTAINER_TOOL" build --network host "${PLATFORM_ARGS[@]}" "${BUILD_ARGS[@]}" \
  -f Dockerfile --target webhook -t "$WEBHOOK_TAG" .

"$CONTAINER_TOOL" push "$OPERATOR_TAG"
"$CONTAINER_TOOL" push "$WEBHOOK_TAG"

echo ">>> 已推送: $OPERATOR_TAG"
echo ">>> 已推送: $WEBHOOK_TAG"
