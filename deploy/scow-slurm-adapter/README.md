# scow-slurm-adapter 部署目录

本目录用于部署 OpenSCOW 所需的 `scow-slurm-adapter`。

**默认方式：在本机用 Docker Compose 跑 adapter**。若改用 **集群内 Deployment**（见 `scow-slurm-adapter.k8s.yaml`），一般不再需要 accounting 的 NodePort；镜像需 **重新 build** 以包含默认 `entrypoint.sh`（sackd + 渲染配置）。

若你此前用 K8s 部署过且启用了 `hostNetwork`，或改用 Compose 后，请删掉 K8s 资源，避免与宿主机 **8972** 端口冲突：

```bash
kubectl delete -f install/slurm-operator/deploy/scow-slurm-adapter/scow-slurm-adapter.k8s.yaml
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `docker-compose.yml` | **默认**：用 Docker 启动 adapter，映射 `8972:8972` |
| `config.yaml.tmpl` | 配置模板；`MYSQL_HOST` / `__MYSQL_USER__` / `DB_PASSWORD` 由 entrypoint 从环境注入 |
| `entrypoint.sh` | 渲染 `config.yaml` 后启动二进制 |
| `.env.example` | 复制为 `.env` 并填写数据库密码 |
| `Dockerfile` | 构建 `harbor.aix.com:8443/library/scow-slurm-adapter:1.6.1-glibc`（或本地 tag） |
| `config.yaml` | 手写全量配置时的参考（Compose 路径以 tmpl + `.env` 为准） |
| `scow-slurm-adapter.k8s.yaml` | **可选**：把 adapter 跑在 **与 Slurm 同 namespace** 的 Deployment；可用集群 DNS 连 `slurm-accounting`，通常 **不必** 再给 accounting 开 NodePort |
| `docker-compose.hostnet.yml` | **可选**：`network_mode: host`，避免 MySQL 拒绝 `slurm@172.17.0.1` |
| `docker-compose.slurm.yml` | **推荐与 OpenSCOW 仪表盘同用**：挂载 `slurm.conf` + `munge.key`，使 `scontrol` 能列分区 |
| `hack/fetch-slurm-conf-for-adapter.sh` | 从 `slurmctld` Pod 导出 `slurm.conf` 到本目录（需 kubectl） |

## OpenSCOW 仪表盘 `getClusterInfo` 500：`Exec command failed or don't set partitions`

Adapter **已能连上 gRPC** 时，该错误来自 **scow-slurm-adapter** 内部执行 **`scontrol show partition`** 失败或得到空分区（见上游 `services/config/config.go`）。仅 MySQL **不够**，容器内需要：

1. **`slurm-client`（scontrol）** — 已写入本目录 `Dockerfile`，请 **`docker compose build`** 重建镜像。  
2. **`/etc/slurm/slurm.conf`** — 与集群一致；可用 `bash hack/fetch-slurm-conf-for-adapter.sh` 导出到 **本目录 `slurm.conf`**。若其中 **`SlurmctldHost`** 为集群内 DNS，在 Docker 内解析不到时，请改为从本机可达的 **slurmctld 地址**（如 Service ClusterIP、NodePort 所在 IP 等）。  
3. **`munge.key`** — 与集群 Munge 一致，复制为 **`munge.key`** 与本目录 `docker-compose.slurm.yml` 一并挂载；`entrypoint.sh` 会在启动 adapter 前拉起 **`munged`**。

启动示例（在本目录）：

```bash
docker compose -f docker-compose.yml -f docker-compose.slurm.yml up -d --build
# 若同时需要 host 网络连 MySQL：再叠加 -f docker-compose.hostnet.yml，且 .env 中 MYSQL_HOST=127.0.0.1
```

**说明**：Debian 镜像中的 `slurm-client` 版本（如 22.05）若与控制器 **大版本差过多**，可能出现 RPC 不兼容；此时宜改用与 **slurmctld 同系列** 的基础镜像或把 adapter 放回能直接跑 `scontrol` 的环境（例如集群内 Pod）。

## MySQL `1045`：`Access denied for user 'slurm'@'172.17.0.1'`

Adapter 在 **默认 bridge 网络**里连库时，MySQL 服务器看到的客户端主机常落在 **172.17.x.x / 172.17.0.1**（Docker 网段）。若库里只给过 **`slurm@'%'`** 以外的账号（例如仅 **`slurm@'10.%'`** 或 **`slurm@'localhost'`**），就会 1045。

**做法一（推荐，库侧授权）** 在 MySQL 执行（库名、密码按你环境改）：

```sql
-- MySQL 8 示例：密码与 .env 中 DB_PASSWORD 一致
CREATE USER IF NOT EXISTS 'slurm'@'172.17.%' IDENTIFIED BY '你的密码';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'172.17.%';
FLUSH PRIVILEGES;
```

若已存在 `'slurm'@'%'`，请核对 **`.env` 的 `DB_PASSWORD`** 与库中密码一致。

**做法二（adapter 用宿主机网络）** MySQL 在本机且允许 **`slurm@'127.0.0.1'`** / **`localhost`** 时：

```bash
# .env 中取消注释并设置：
MYSQL_HOST=127.0.0.1

docker compose -f docker-compose.yml -f docker-compose.hostnet.yml up -d
```

## 已预填参数（`config.yaml.tmpl`）

`mysql:` 段在模板中**全部为占位符**，由 `entrypoint.sh` 用环境变量替换；未设置时使用下列默认（与常见 Slurm Accounting 一致）：

| 占位符 | 环境变量 | 默认 |
|--------|----------|------|
| `__MYSQL_HOST__` | `MYSQL_HOST` | `172.16.84.71` |
| `__MYSQL_PORT__` | `MYSQL_PORT` | `3306` |
| `__MYSQL_USER__` | `MYSQL_USER` 或 `DB_USER` | `slurm` |
| `__MYSQL_DBNAME__` | `MYSQL_DBNAME` 或 `MYSQL_DATABASE` | `slurm_acct_db` |
| `__DB_PASSWORD__` | `DB_PASSWORD` | （必填） |
| `__MYSQL_CLUSTERNAME__` | `MYSQL_CLUSTERNAME` | `slurm` |
| `__MYSQL_DATABASE_ENCODE__` | `MYSQL_DATABASE_ENCODE` | `latin1` |

Compose 在 **`.env`** 中设置；K8s 在 Deployment `env` 中设置。**aixx 向导** 会注入主机、用户名、密码 Secret；其余项若与默认一致可省略。
- gRPC：**v1.6.0** 配置为 `service.port: 8972`（监听 `:8972` 全网卡）；**不要**写 `service.addr`（会导致 `port=0`、实际落在随机端口，`lsof -i:8972` 为空）
- `clustername: slurm`（请用 `sacctmgr show cluster -P` 核对）

## 部署步骤（Docker Compose）

### 1) 准备镜像

将官方二进制放到本目录并构建（与此前流程相同）：

```bash
cd install/slurm-operator/deploy/scow-slurm-adapter
wget https://github.com/PKUHPC/scow-slurm-adapter/releases/download/v1.6.0/scow-slurm-adapter-amd64
chmod +x scow-slurm-adapter-amd64
docker build -t harbor.aix.com:8443/library/scow-slurm-adapter:1.6.1-glibc .
```

内网需先推 Harbor 时，打 tag 后 `docker push` 即可；`docker-compose.yml` 里 `image` 与构建产物名保持一致。

### 2) 配置密码并启动

```bash
cp .env.example .env
# 编辑 .env，填写 DB_PASSWORD=...
# 仅验证 gRPC / 部分接口：docker compose up -d
# OpenSCOW 仪表盘分区信息：先准备 slurm.conf、munge.key，再：
docker compose -f docker-compose.yml -f docker-compose.slurm.yml up -d --build
docker compose logs -f --tail=50
```

验证：

```bash
nc -zv 127.0.0.1 8972
```

### 3) OpenSCOW

与 OpenSCOW **同机**且 OpenSCOW 也在 Docker 里时，`config/clusters/slurm.yaml` 中 **`adapterUrl`** 使用 **`172.17.0.1:8972`**（或 `ip -4 addr show docker0` 中的网关地址）。修改后重启 portal-server / `compose up`。

**aixx 管理端**：超算池「Slurm 安装」页有 **「生成 OpenSCOW 配置」**，会按已保存向导生成 OpenSCOW `deploy/docker` 下的 **`config/clusters/slurm.yaml`**、**`config/auth.yml`** 草稿（另需 `install.yaml`、`common.yaml` 等，见 OpenSCOW 该目录 `README.md`）。若 OpenSCOW 跑在集群外，向导里 OpenLDAP 须选 **NodePort**（默认 LDAP **30389**、LDAPS **30636**），保存 Slurm 配置后执行 **「修复 OpenLDAP」** 更新 Service。

## 可选：Kubernetes 部署（与 Compose 二选一）

Adapter **无状态**（不依赖 PVC；配置来自 Secret/ConfigMap，Pod 重建即可），适合单副本 Deployment。

把 adapter 放在 **与 Slurm 同一 namespace** 时，`slurm.conf` 里可继续使用 **`AccountingStorageHost=slurm-accounting`** 等集群内 DNS，**一般不必** 再给 slurmdbd 开 NodePort；若已仅为「宿主机 Docker adapter」开过 NodePort，可在确认迁移完成后把 Helm `accounting.service` 改回 `ClusterIP`。

1. **重新构建镜像**（镜像内须含 `entrypoint.sh` / `config.yaml.tmpl`，见本目录 `Dockerfile`）。  
2. **准备 `slurm.conf`**：`K8S_ADAPTER=1 NS=slurm bash hack/fetch-slurm-conf-for-adapter.sh`（会写 `SlurmctldHost=slurm-controller`；**不要**再设 `ACCOUNTING_NODE_*`）。也可手改已存在的 `slurm.conf` 中该行。  
3. **创建 ConfigMap**：`kubectl -n slurm create configmap scow-slurm-adapter-slurm-conf --from-file=slurm.conf=./slurm.conf`（路径按你导出文件调整）。  
4. 编辑 `scow-slurm-adapter.k8s.yaml` 中的 **`MYSQL_HOST`**、**`MYSQL_USER`**（以及 **`slurm-auth-*` Secret 名** 若 Helm release 不是 `slurm`）。**推荐**：用 aixx 管理端「安装 SCOW Adapter」向导生成/应用 Deployment，与账务用户名一致。  
5. `kubectl apply -f install/slurm-operator/deploy/scow-slurm-adapter/scow-slurm-adapter.k8s.yaml`  

验证：`kubectl -n slurm exec deploy/scow-slurm-adapter -- sacctmgr ping`

**OpenSCOW**：若 portal 也在集群内，`adapterUrl` 可用 `http://scow-slurm-adapter.slurm.svc.cluster.local:8972`；若仍在宿主机 Docker，可为 `scow-slurm-adapter` Service 改为 **NodePort** 或 `kubectl port-forward`。

勿与 Compose 同时在同一节点占 **8972**（除非一方未监听该端口）。

## LDAP 说明

Adapter 主要依赖 Slurm Accounting（MySQL）等，不直接依赖 LDAP。LDAP 在 OpenSCOW 的 `auth.yml` 中配置。

## MIS 创建账户报 `Exec command failed` / 容器内 `sacctmgr ping` 失败

**集群外**（宿主机 Docker）里的 `sacctmgr` 依赖 **`slurm.conf` 中的 `AccountingStorageHost` / `AccountingStoragePort`** 访问 **slurmdbd**；集群内 DNS 名（如 `slurm-accounting`）在宿主机容器里不可用。**若 adapter 已部署在 K8s 同 namespace，则仍可用 `slurm-accounting`，通常不需要 NodePort。**

**Helm**：`helm/slurm/values.yaml` 中 `accounting.service` 已默认 **`type: NodePort`**、`nodePort: 30819`（与现有 login NodePort 冲突时请改 `nodePort`）。升级 release 后执行：

```bash
kubectl -n slurm get svc slurm-accounting
```

确认 `PORT(S)` 含 `6819:30819/TCP`（或你自定义的 NodePort）。

**重写 adapter 的 `slurm.conf`**（将记账指向「可从本机访问的节点 IP + NodePort」）：

```bash
# 将 172.16.84.71 换成任一 K8s 节点内网 IP；30819 与 svc 上 NodePort 一致
ACCOUNTING_NODE_HOST=172.16.84.71 ACCOUNTING_NODE_PORT=30819 NS=slurm \
  bash hack/fetch-slurm-conf-for-adapter.sh
```

然后重建/重启 adapter，验证：

```bash
docker exec -it scow-slurm-adapter-scow-slurm-adapter-1 bash -lc 'sacctmgr ping'
```

**安全**：slurmdbd NodePort 应对外限制来源 IP（防火墙/安全组），勿对公网全开。

## 同机曾出现的 NodePort / Docker 问题（备忘）

若 OpenSCOW 在 Docker 内、adapter 若在 K8s 仅用 NodePort，可能出现容器访问 NodePort 失败；**改用本目录 Compose 在宿主机映射 8972** 后，OpenSCOW 走 `172.17.0.1:8972` 通常更简单。

## 常见问题

- `ImagePullBackOff`：先 `docker compose build` 或推 Harbor 后再 `up`。
- `scow-slurm-adapter-amd64` 与基础镜像不兼容：请用本目录 `Dockerfile`（`ubuntu:24.04` + 自 Slinky slurmd 镜像复制 `scontrol` / Slurm 插件库，glibc）。
- 密码含 `|`、`&` 等字符：`sed` 模板可能异常，宜换不含特殊字符的密码或改用挂载已渲染的 `config.yaml`（自行维护文件并改 compose 挂载方式）。
