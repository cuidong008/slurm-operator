#!/usr/bin/env bash
# 最简单的 Slurm 提测：在 controller 上用 srun 跑一条单节点命令（无需共享存储上的脚本文件）。
#
# 用法：
#   ./slurm-smoke-test.sh [命名空间]
# 默认命名空间 slurm；需已配置 kubectl，且 slurm-controller-0 为 Running。
#
# 也可在 login 上交互测试（需能执行 srun）：
#   kubectl exec -it -n slurm deploy/slurm-login-login -- bash -lc 'sinfo; srun -N1 hostname'

set -euo pipefail

NS="${1:-slurm}"
CTRL_POD="${SLURM_CTRL_POD:-slurm-controller-0}"
CTLD_C="${SLURM_CTLD_CONTAINER:-slurmctld}"

echo ">>> namespace=$NS pod=$CTRL_POD container=$CTLD_C"
kubectl -n "$NS" get pod "$CTRL_POD" -o wide

echo ">>> sinfo"
kubectl -n "$NS" exec "$CTRL_POD" -c "$CTLD_C" -- sinfo

echo ">>> srun -N1 hostname（单节点一条命令）"
kubectl -n "$NS" exec "$CTRL_POD" -c "$CTLD_C" -- srun -N1 hostname

echo ">>> 可选：sbatch 批处理（sleep 5 后退出）"
kubectl -n "$NS" exec "$CTRL_POD" -c "$CTLD_C" -- bash -c 'JOB=$(sbatch --wrap="sleep 5 && echo done" --parsable) && echo "submitted $JOB" && squeue -j "$JOB" && sleep 8 && sacct -j "$JOB" --format=JobID,State,ExitCode -n || true'

echo ">>> ok"
