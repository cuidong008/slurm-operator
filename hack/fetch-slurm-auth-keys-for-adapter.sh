#!/usr/bin/env bash
# 从集群 Secret 导出 slurm.key / jwt.key，供本机 Docker adapter + sackd 使用（AuthType=auth/slurm）。
# 用法：NS=slurm RELEASE=slurm bash hack/fetch-slurm-auth-keys-for-adapter.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NS:-slurm}"
RELEASE="${RELEASE:-slurm}"
OUT_DIR="${OUT_DIR:-$ROOT/deploy/scow-slurm-adapter}"

SECRET_SLURM="${SECRET_SLURM:-${RELEASE}-auth-slurm}"
SECRET_JWT="${SECRET_JWT:-${RELEASE}-auth-jwt}"

mkdir -p "$OUT_DIR"
kubectl -n "$NS" get secret "$SECRET_SLURM" -o jsonpath='{.data.slurm\.key}' | base64 -d >"$OUT_DIR/slurm.key"
kubectl -n "$NS" get secret "$SECRET_JWT" -o jsonpath='{.data.jwt\.key}' | base64 -d >"$OUT_DIR/jwt.key"
chmod 600 "$OUT_DIR/slurm.key" "$OUT_DIR/jwt.key"
echo "已写入: $OUT_DIR/slurm.key 与 $OUT_DIR/jwt.key（勿提交仓库；已 .gitignore）"
echo "启动示例: docker compose -f docker-compose.yml -f docker-compose.hostnet.yml -f docker-compose.slurm.yml -f docker-compose.slurm-auth.yml up -d --build"
