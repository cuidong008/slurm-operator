# Slurm-web v6（Docker Compose）

[Rackslab 官方文档](https://docs.rackslab.io/slurm-web/install/install/containers/docker.html)写明：**Slurm-web 的 Docker 安装目前不在支持范围内**。本目录用 Ubuntu 24.04 上的官方 APT 源（`slurmweb-6`）把 **agent** 与 **gateway** 打进同一镜像，再用 Compose 跑起来，便于与本仓库的 Kubernetes + `slurmrestd`（RestApi）对接。

架构说明见 [Slurm-web 概览](https://docs.rackslab.io/slurm-web/overview/start.html)。

## 前提

- 集群已启用与 Slurm-web 兼容的 **Slurm REST**：`slurmrestd` 监听 TCP（Slinky Helm 默认 **6820**），且 Slurm 侧已配置 **JWT**（`AuthAltParameters` 等），与 [Quickstart](https://docs.rackslab.io/slurm-web/install/quickstart.html) 一致。
- **agent 容器**必须能访问 `slurmrestd` 的 TCP（默认 URI：`http://host.docker.internal:6820`）。常见做法是在**跑 Docker 的那台机器**上对集群 Service 做端口转发（见下）。若用 **NodePort / LoadBalancer**，把 `SLURMRESTD_URI` 改成实际 `http://IP:端口`。

## 准备 JWT 密钥文件

Slurm-web agent 需要 **与集群相同的 JWT 签名密钥**（Helm 默认在 Secret 的 `jwt.key` 字段里）：

```bash
mkdir -p secrets
# 键名是 jwt.key（带点）：jsonpath 用反斜杠转义点；整条 jsonpath 用单引号，避免 zsh 把双引号里的 [...] 当 glob 弄成空输出。
kubectl get secret -n <namespace> slurm-auth-jwt -o jsonpath='{.data.jwt\.key}' | base64 -d > secrets/slurmrestd.key
# 备选（不依赖 jsonpath 转义）：
# kubectl get secret -n <namespace> slurm-auth-jwt -o json | jq -r '.data["jwt.key"]' | base64 -d > secrets/slurmrestd.key
chmod 600 secrets/slurmrestd.key
wc -c secrets/slurmrestd.key   # 应远大于 0（与 Secret 里 jwt.key 原始长度一致）
```

Compose 把该文件**只读**挂到容器内 `/run/slurmrestd.key`，entrypoint 再复制到 **agent 容器私有路径** `/etc/slurm-web/slurm-cluster-jwt.key`（不放在与 gateway 共用的命名卷里），避免两个容器同时写 `/var/lib/slurm-web` 时把密钥文件截断成空（日志里会出现 `Key ... is empty`）。宿主机 `600` 权限不影响：复制由 root 完成后再 `chown slurm-web`。

## 启动

```bash
cd deploy/slurm-web-docker
docker compose build
# 若 slurmrestd 在本机 6820（例如已 port-forward）：
docker compose up -d
```

浏览器打开：本机用 `http://localhost:5011`；若用 **公网 IP / 域名** 访问，必须先设 `SLURM_WEB_PUBLIC_URL`（见下「CORS / API 指向 localhost」）。

## 常用环境变量

| 变量 | 含义 |
|------|------|
| `SLURMRESTD_URI` | agent 访问 `slurmrestd` 的 URL，默认 `http://host.docker.internal:6820` |
| `SLURM_CLUSTER_NAME` | 与 Slurm `ClusterName` 一致，默认 `slurm` |
| `SLURM_WEB_PUBLIC_URL` | **必须与地址栏完全一致**（如 `http://203.0.113.10:5011`）。Slurm-web 用它写入前端 API 基址；默认 `http://localhost:5011` 在非本机访问时会导致请求打到 `localhost` 并触发 CORS |
| `SLURMRESTD_KEY_FILE` | JWT 密钥挂载路径，默认 `./secrets/slurmrestd.key` |
| `SLURM_WEB_PORT` | 宿主机映射端口，默认 `5011` |
| `SLURM_WEB_LDAP_ENABLED` | 是否启用 LDAP 登录，默认 `true`（对接 `openldap-lab`）；无目录时设 `false` |
| `SLURM_WEB_LDAP_URI` | 目录 URI，默认 `ldap://host.docker.internal:389`（宿主机映射的 Bitnami OpenLDAP） |
| `SLURM_WEB_LDAP_USER_BASE` / `GROUP_BASE` | 默认 `ou=users,dc=example,dc=org` / `ou=groups,dc=example,dc=org`（与 `examples/docker-compose.openldap.yml`、`hack/add-openldap-cuidong-user.sh` 一致） |
| `SLURM_WEB_LDAP_BIND_DN` / `BIND_PASSWORD` | 服务账号，默认 `cn=admin,dc=example,dc=org` / `admin` |

**与 `openldap-lab`（`docker compose -f examples/docker-compose.openldap.yml`）同机时**：先起 OpenLDAP（宿主机 **389**），再起本 compose；gateway 已加 `host.docker.internal` 与上述默认 URI。网页登录一般用预置 **`user01` / `bitnami1`**（uid），不要用 `cn=admin` 当登录名（与 phpLDAPadmin 说明一致）。

**改用容器名 `openldap:389`（不经宿主机端口）**：给 `slurm-web-gateway` 增加外部网络 `openldap-lab_default` 并设置 `SLURM_WEB_LDAP_URI=ldap://openldap:389`（两栈需在同一 Docker 主机）。

示例（`slurmrestd` 在局域网另一台机器）：

```bash
SLURMRESTD_URI=http://192.168.1.50:6820 SLURM_CLUSTER_NAME=hpc docker compose up -d
```

## 故障排除：CORS / `localhost:5011/api/...` 被拦截

**现象**：从 `http://<公网IP>:5011` 打开页面，控制台报 CORS，且 XHR 指向 `http://localhost:5011/api/...`。

**原因**：gateway 里 `[ui] host`（由 `SLURM_WEB_PUBLIC_URL` 生成）仍是默认的 `http://localhost:5011`，打包进前端的 API 基址不对，浏览器把「页面来源」和「API 主机」当成两个源。

**处理**：用你真实访问 URL 重建 gateway，例如：

```bash
cd deploy/slurm-web-docker
SLURM_WEB_PUBLIC_URL='http://<你的公网IP或域名>:5011' docker compose up -d --force-recreate slurm-web-gateway
```

若前面有 **HTTPS 反代**，这里填对外的 `https://域名/…`（与 [Slurm-web gateway 配置](https://docs.rackslab.io/slurm-web/conf/conf/gateway.html) 中 `ui.host` 说明一致）。

## 故障排除：`Connection refused` / `Unable to connect to slurmrestd`

含义：**agent 连不上** `SLURMRESTD_URI` 里的地址（默认 `host.docker.internal:6820`）。

1. **先确认集群里有 RestApi / slurmrestd Service**（release 名为 `slurm` 时一般为 `slurm-restapi`）：
   ```bash
   kubectl get svc -n slurm slurm-restapi
   ```
2. **在宿主机上做 port-forward，且必须监听 `0.0.0.0`**（默认只绑 `127.0.0.1` 时，容器经 `host.docker.internal` 连宿主机 **连不上** 该端口）：
   ```bash
   kubectl port-forward -n slurm svc/slurm-restapi 6820:6820 --address 0.0.0.0
   ```
   保持该终端不要关。再在宿主机执行 `ss -lntp | grep 6820` 应看到 `0.0.0.0:6820`。
3. **若 slurmrestd 不在本机转发**（例如在别的节点或只有内网 IP），设置：
   ```bash
   SLURMRESTD_URI=http://<可达IP>:6820 docker compose up -d
   ```
4. **防火墙**：确保宿主机或目标 IP 的 **6820** 对 Docker 网桥/`host.docker.internal` 所在网段放行。

## 自检

在 agent 容器内（可选）：

```bash
docker compose exec slurm-web-agent slurm-web connect-check
```

## 生产建议

- 在 gateway 前加 **TLS 反向代理**（Nginx/Caddy 等），并把 `SLURM_WEB_PUBLIC_URL` 设为 `https://…`。
- 按官方文档开启 **LDAP** 等认证，勿长期依赖默认的 `authentication enabled = no`。
