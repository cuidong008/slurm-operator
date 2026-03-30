#!/bin/sh
set -e
# 与 Dockerfile 中 Slurm 插件路径一致（scontrol / sackd）
export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu/slurm${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ -z "${DB_PASSWORD}" ]; then
  echo "scow-slurm-adapter: DB_PASSWORD is required (see .env.example)" >&2
  exit 1
fi

# 仅当显式 START_MUNGED=1 且挂载了集群 munge.key 时启动 munged（auth/munge 集群用 docker-compose.munge.yml）
if [ "${START_MUNGED:-0}" = "1" ] && [ -r /etc/munge/munge.key ]; then
  chown root:munge /etc/munge/munge.key 2>/dev/null || true
  chmod 0400 /etc/munge/munge.key 2>/dev/null || true
  install -d -o munge -g munge -m 0755 /run/munge /var/lib/munge /var/log/munge 2>/dev/null || true
  chown munge:munge /var/log/munge 2>/dev/null || true
  if [ ! -S /run/munge/munge.socket ]; then
    echo "scow-slurm-adapter: starting munged..." >&2
    munged
    i=0
    while [ "$i" -lt 15 ] && [ ! -S /run/munge/munge.socket ]; do
      i=$((i + 1))
      sleep 1
    done
    if [ ! -S /run/munge/munge.socket ]; then
      echo "scow-slurm-adapter: munged did not create /run/munge/munge.socket" >&2
      exit 1
    fi
  fi
fi

# Bind 挂载的 slurm.key/jwt.key 在主机上常为 uid 1000；auth/slurm 要求属主为 root 或 SlurmUser(401)，否则 sackd 报错
# "Could not load key file"。复制到 /run 并 chown slurm，同时生成改写路径后的 slurm.conf，供 SLURM_CONF 使用。
SLURM_CONF_EFFECTIVE="${SLURM_CONF:-}"
if [ -r /etc/slurm/slurm.conf ]; then
  if [ -r /etc/slurm/slurm.key ] || [ -r /etc/slurm/jwt.key ]; then
    install -d -m 0755 /run/slurm-adapter
    [ -r /etc/slurm/slurm.key ] && install -m 600 -o slurm -g slurm /etc/slurm/slurm.key /run/slurm-adapter/slurm.key
    [ -r /etc/slurm/jwt.key ] && install -m 600 -o slurm -g slurm /etc/slurm/jwt.key /run/slurm-adapter/jwt.key
    cp /etc/slurm/slurm.conf /run/slurm-adapter/slurm.conf
    sed -i 's#/etc/slurm/slurm.key#/run/slurm-adapter/slurm.key#g' /run/slurm-adapter/slurm.conf
    sed -i 's#/etc/slurm/jwt.key#/run/slurm-adapter/jwt.key#g' /run/slurm-adapter/slurm.conf
    chmod 644 /run/slurm-adapter/slurm.conf
    export SLURM_CONF=/run/slurm-adapter/slurm.conf
    SLURM_CONF_EFFECTIVE="$SLURM_CONF"
    echo "scow-slurm-adapter: staged slurm keys + SLURM_CONF=$SLURM_CONF (fix bind-mount uid)" >&2
  fi
fi
[ -z "$SLURM_CONF_EFFECTIVE" ] && SLURM_CONF_EFFECTIVE=/etc/slurm/slurm.conf
export SLURM_CONF_EFFECTIVE

# auth/slurm + configless 时，无 slurmd 的节点需 sackd 提供 /run/slurm/sack.socket，scontrol 才能建凭证（见 helm login sackd 说明）。
if [ "${START_SACKD:-1}" != "0" ] && [ -x /usr/sbin/sackd ] && [ -r /etc/slurm/slurm.conf ] \
  && [ -r /etc/slurm/slurm.key ] && [ -r /etc/slurm/jwt.key ]; then
  install -d -m 0755 /run/slurm /var/log/slurm
  chown slurm:slurm /run/slurm 2>/dev/null || true
  export RUNTIME_DIRECTORY=/run/slurm
  echo "scow-slurm-adapter: starting sackd (auth/slurm)..." >&2
  runuser -u slurm -- env SLURM_CONF="$SLURM_CONF_EFFECTIVE" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" RUNTIME_DIRECTORY=/run/slurm /usr/sbin/sackd -D 2>&1 &
  sackd_pid=$!
  i=0
  while [ "$i" -lt 30 ]; do
    if [ -S /run/slurm/sack.socket ]; then
      echo "scow-slurm-adapter: sack.socket ready" >&2
      break
    fi
    if ! kill -0 "$sackd_pid" 2>/dev/null; then
      echo "scow-slurm-adapter: WARN sackd 已退出，请检查 slurm.conf / slurm.key / jwt.key" >&2
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ ! -S /run/slurm/sack.socket ]; then
    echo "scow-slurm-adapter: WARN /run/slurm/sack.socket 未就绪，scontrol 可能认证失败" >&2
  fi
elif [ "${START_SACKD:-1}" != "0" ] && [ -r /etc/slurm/slurm.conf ] && grep -q '^AuthType=auth/slurm' /etc/slurm/slurm.conf 2>/dev/null; then
  if [ ! -r /etc/slurm/slurm.key ] || [ ! -r /etc/slurm/jwt.key ]; then
    echo "scow-slurm-adapter: WARN AuthType=auth/slurm 但未挂载 /etc/slurm/slurm.key 与 jwt.key，请: hack/fetch-slurm-auth-keys-for-adapter.sh 并叠加 docker-compose.slurm-auth.yml" >&2
  fi
fi

MYSQL_HOST=${MYSQL_HOST:-172.16.84.71}
mkdir -p /app/config
export MYSQL_HOST DB_PASSWORD
awk '{
  s = $0
  gsub(/__MYSQL_HOST__/, ENVIRON["MYSQL_HOST"], s)
  gsub(/__DB_PASSWORD__/, ENVIRON["DB_PASSWORD"], s)
  print s
}' /tmpl/config.yaml.tmpl > /app/config/config.yaml

echo "scow-slurm-adapter: config rendered, starting gRPC :8972..." >&2
if command -v scontrol >/dev/null 2>&1; then
  scontrol show partition >/dev/null 2>&1 && echo "scow-slurm-adapter: scontrol show partition OK" >&2 \
    || echo "scow-slurm-adapter: WARN scontrol show partition failed（检查 slurm.conf / SlurmctldHost / munge）" >&2
fi
exec /app/scow-slurm-adapter-amd64
