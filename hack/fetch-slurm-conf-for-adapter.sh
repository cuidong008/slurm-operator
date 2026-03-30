#!/usr/bin/env bash
# 从 slurm 命名空间的 slurmctld Pod 导出 slurm.conf，供本机 Docker adapter 使用。
# 用法：NS=slurm bash hack/fetch-slurm-conf-for-adapter.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-slurm}"
OUT="${OUT:-$ROOT/deploy/scow-slurm-adapter/slurm.conf}"

pick_ctld_pod() {
  kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.containers[*].name}{"\n"}{end}' 2>/dev/null \
    | awk '$2=="Running" && $0 ~ /slurmctld/ {print $1; exit}'
}

POD="$(pick_ctld_pod)"
if [[ -z "${POD}" ]]; then
  echo "未找到 Running 且含 slurmctld 容器的 Pod（namespace=$NS）。请手动："
  echo "  kubectl -n $NS get pods"
  echo "  kubectl -n $NS exec <pod> -c slurmctld -- cat /etc/slurm/slurm.conf > deploy/scow-slurm-adapter/slurm.conf"
  exit 1
fi

echo "使用 Pod: $POD"
kubectl -n "$NS" exec "$POD" -c slurmctld -- cat /etc/slurm/slurm.conf >"$OUT"
echo "已写入: $OUT"

# 集群内 Deployment（scow-slurm-adapter.k8s.yaml）：用 Service DNS，避免 ClusterIP 变更。
#   K8S_ADAPTER=1 NS=slurm bash hack/fetch-slurm-conf-for-adapter.sh
if [[ "${K8S_ADAPTER:-0}" == "1" ]]; then
  sed -i.bak 's/^SlurmctldHost=.*/SlurmctldHost=slurm-controller/' "$OUT" && rm -f "${OUT}.bak"
  echo "已 PATCH SlurmctldHost -> slurm-controller（供同 namespace 内 adapter Pod）。"
# 默认将 SlurmctldHost 改为 slurm-controller Service 的 ClusterIP，便于在本机 Docker 内连 6817（需路由可达 ClusterIP，否则配合 host 网络 compose）
elif [[ "${PATCH_CLUSTERIP:-1}" == "1" ]]; then
  CTIP=$(kubectl -n "$NS" get svc slurm-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [[ -n "${CTIP}" ]]; then
    sed -i.bak "s/^SlurmctldHost=.*/SlurmctldHost=slurmctld(${CTIP})/" "$OUT" && rm -f "${OUT}.bak"
    echo "已 PATCH SlurmctldHost -> slurmctld(${CTIP})（slurm-controller ClusterIP）。若仍连不上 slurmctld，请用 host 网络 compose 或为 6817 配置 NodePort）。"
  else
    echo "未找到 svc/slurm-controller，跳过 SlurmctldHost PATCH。"
  fi
fi

# Debian bookworm 的 slurm-client（如 22.05）解析部分 25.x 配置会报错（如 MaxNodeCount 与 cons_tres）
if [[ "${STRIP_CLIENT_INCOMPAT:-1}" == "1" ]]; then
  sed -i.bak '/^MaxNodeCount=/d' "$OUT" && rm -f "${OUT}.bak"
  echo "已去掉 MaxNodeCount= 行（供容器内旧版 scontrol 解析）。"
fi

# 集群外 Docker 中的 sacctmgr 无法使用 svc/slurm-accounting 这类集群内 DNS。为 accounting 配置 NodePort 后，导出时传入节点可达地址：
#   ACCOUNTING_NODE_HOST=172.16.84.71 ACCOUNTING_NODE_PORT=30819 NS=slurm bash hack/fetch-slurm-conf-for-adapter.sh
# NodePort 见：kubectl -n slurm get svc slurm-accounting
if [[ -n "${ACCOUNTING_NODE_HOST:-}" && -n "${ACCOUNTING_NODE_PORT:-}" ]]; then
  if grep -q '^AccountingStorageHost=' "$OUT" 2>/dev/null; then
    sed -i.bak "s/^AccountingStorageHost=.*/AccountingStorageHost=${ACCOUNTING_NODE_HOST}/" "$OUT" && rm -f "${OUT}.bak"
  else
    echo "警告: ${OUT} 中无 AccountingStorageHost=，跳过替换。" >&2
  fi
  if grep -q '^AccountingStoragePort=' "$OUT" 2>/dev/null; then
    sed -i.bak "s/^AccountingStoragePort=.*/AccountingStoragePort=${ACCOUNTING_NODE_PORT}/" "$OUT" && rm -f "${OUT}.bak"
  else
    echo "警告: ${OUT} 中无 AccountingStoragePort=，跳过替换。" >&2
  fi
  echo "已 PATCH AccountingStorage -> ${ACCOUNTING_NODE_HOST}:${ACCOUNTING_NODE_PORT}（供集群外 adapter / sacctmgr）。"
fi
