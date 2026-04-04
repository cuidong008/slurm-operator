# 基于 Slinky login 镜像：与 login Pod 一致使用 SSSD/NSS，便于 getent / su 解析 LDAP 用户。
#
# 仅换镜像不够：Deployment 须挂载 (1) sssd.conf（多为 ConfigMap -> /etc/sssd/sssd.conf）及 (2) 共享家目录 PVC。
# aixx 向导勾选「与 login 对齐」且 SSSD ConfigMap 名留空时，后端会从运行中的 login Pod 拉取 /etc/sssd/sssd.conf
# 并创建/更新 ConfigMap「scow-slurm-adapter-sssd」；亦可手填已有 ConfigMap 名。未挂卷则与旧版最小 Deployment 行为相同。
#
# 构建示例：
#   docker build -f Dockerfile.login -t harbor.example/slurm/scow-slurm-adapter-login:1.6.1 .
# 需将 release 的 scow-slurm-adapter-amd64、config.yaml.tmpl、entrypoint.sh 置于构建上下文中。

ARG LOGIN_IMAGE=harbor.aix.com:8443/slinkyproject/login:25.11-ubuntu24.04
FROM ${LOGIN_IMAGE}

WORKDIR /app

COPY scow-slurm-adapter-amd64 /app/scow-slurm-adapter-amd64

# login 镜像通常已含 Slurm 客户端；若缺少 sackd 则从 Debian 包解压（与 Dockerfile 主文件策略一致）
ARG SACKD_DEB_URL=http://deb.debian.org/debian/pool/main/s/slurm-wlm/sackd_25.11.4-1_amd64.deb

RUN set -eux; \
  if [ ! -x /usr/sbin/sackd ]; then \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates wget dpkg \
      libreadline8t64 libtinfo6 libjwt2 libjansson4 libb64-0d libssl3t64 libjson-c5; \
    wget -q -O /tmp/sackd.deb "${SACKD_DEB_URL}"; \
    dpkg-deb -x /tmp/sackd.deb /tmp/sackd-ex; \
    install -m 755 /tmp/sackd-ex/usr/sbin/sackd /usr/sbin/sackd; \
    rm -rf /tmp/sackd.deb /tmp/sackd-ex; \
    rm -rf /var/lib/apt/lists/*; \
  fi; \
  update-ca-certificates

# Slurm 客户端与 libslurm 使用 login 镜像内置版本，与 SSSD/login 栈一致；勿从 slurmd 覆盖以免混用 libc 插件路径。

RUN chmod +x /app/scow-slurm-adapter-amd64 \
  && (getent group slurm >/dev/null 2>&1 || groupadd -g 401 slurm) \
  && (getent passwd slurm >/dev/null 2>&1 || useradd --system --uid 401 --gid slurm --no-create-home --shell /usr/sbin/nologin slurm) \
  && install -d -o munge -g munge -m 0700 /etc/munge /var/lib/munge /run/munge 2>/dev/null || true \
  && install -d -o munge -g munge -m 0755 /var/log/munge 2>/dev/null || true \
  && rm -f /etc/munge/munge.key \
  && install -d -m 0755 /tmpl

COPY config.yaml.tmpl /tmpl/config.yaml.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8972

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
