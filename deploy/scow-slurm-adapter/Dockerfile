# 与集群 Slurm 主版本一致的控制器/计算镜像，用于复制 scontrol 及 auth_slurm 等插件（Debian/apt 的 slurm-client 过旧会报 cannot find auth plugin for auth/slurm）。
ARG SLURM_IMAGE=harbor.aix.com:8443/slinkyproject/slurmd:25.11-ubuntu24.04
FROM ${SLURM_IMAGE} AS slurm

FROM ubuntu:24.04

WORKDIR /app

# Release binary downloaded from:
# https://github.com/PKUHPC/scow-slurm-adapter/releases
COPY scow-slurm-adapter-amd64 /app/scow-slurm-adapter-amd64

# Debian sid 的 sackd 与 Slinky slurm-smd 同为 25.11.4；运行时通过 LD_LIBRARY_PATH 使用镜像内 slurm 的 libslurmfull（与 scontrol 一致）。
ARG SACKD_DEB_URL=http://deb.debian.org/debian/pool/main/s/slurm-wlm/sackd_25.11.4-1_amd64.deb

# 运行 scontrol / sackd 所需的动态库（与 slurmd 镜像中 auth_slurm.so 的 ldd 一致）
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    bash \
    munge \
    wget \
    dpkg \
    libreadline8t64 \
    libtinfo6 \
    libjwt2 \
    libjansson4 \
    libb64-0d \
    libssl3t64 \
    libjson-c5 \
  && wget -q -O /tmp/sackd.deb "${SACKD_DEB_URL}" \
  && dpkg-deb -x /tmp/sackd.deb /tmp/sackd-ex \
  && install -m 755 /tmp/sackd-ex/usr/sbin/sackd /usr/sbin/sackd \
  && rm -rf /tmp/sackd.deb /tmp/sackd-ex \
  && rm -rf /var/lib/apt/lists/* \
  && update-ca-certificates

COPY --from=slurm \
  /usr/bin/scontrol \
  /usr/bin/sinfo \
  /usr/bin/squeue \
  /usr/bin/sacct \
  /usr/bin/scancel \
  /usr/bin/sbatch \
  /usr/bin/salloc \
  /usr/bin/srun \
  /usr/bin/sattach \
  /usr/bin/sacctmgr \
  /usr/bin/

COPY --from=slurm /usr/lib/x86_64-linux-gnu/slurm /usr/lib/x86_64-linux-gnu/slurm

RUN chmod +x /app/scow-slurm-adapter-amd64 \
  && install -d -o munge -g munge -m 0700 /etc/munge /var/lib/munge /run/munge \
  && install -d -o munge -g munge -m 0755 /var/log/munge \
  && rm -f /etc/munge/munge.key \
  && groupadd -g 401 slurm \
  && useradd --system --uid 401 --gid 401 --no-create-home --shell /usr/sbin/nologin slurm \
  && install -d -m 0755 /tmpl

COPY config.yaml.tmpl /tmpl/config.yaml.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8972

# Compose 仍可通过 volume 覆盖 /entrypoint.sh 与 /tmpl；Kubernetes 内建部署可直接用此入口（sackd + 渲染 config）。
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
