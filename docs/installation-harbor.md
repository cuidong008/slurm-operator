# Slurm（Slinky）安装说明：Harbor 镜像与常见问题

本文档基于在**内网 / 无外网镜像拉取**环境下的部署实践整理，与官方 [installation.md](./installation.md) 配合使用。

## 目录

- [架构说明](#架构说明)
- [前置条件](#前置条件)
- [一、同步镜像到 Harbor](#一同步镜像到 Harbor)
- [二、配置 Helm values 使用 Harbor](#二配置-helm-values-使用-harbor)
- [三、安装 Operator 与 Slurm](#三安装-operator-与-slurm)
- [四、Controller 持久化与存储（BeeGFS CSI）](#四controller-持久化与存储beegfs-csi)
- [五、验证集群](#五验证集群)
- [六、SSSD 与 LDAP 说明](#六sssd-与-ldap-说明)
- [七、Accounting（账务）](#七accounting账务)
- [八、常见问题](#八常见问题)

---

## 架构说明

- 使用本仓库 `**./helm/slurm`**（或历史上的 `oci://ghcr.io/slinkyproject/charts/slurm`）会在**已有 Kubernetes 集群**的命名空间内安装 **Slurm 集群**（容器化 slurmctld、slurmd、slurmrestd 等），**不会**创建新的 Kubernetes 集群。
- 小规模（例如 2 台机器）可以跑通，主要受 **CPU/内存** 与 **镜像是否可拉取** 约束。

---

## 前置条件

- Kubernetes ≥ 1.29（与项目 README 一致）
- 已安装 [cert-manager](https://cert-manager.io/)（若未安装，见官方 `installation.md`）
- 集群节点能访问你的 **Harbor**（或事先在节点上导入镜像）
- 建议先安装 **slurm-operator** 与 CRDs（见下文）
- （可选）若集群已部署 **BeeGFS CSI**，可为 `slurmctld` 提供持久卷，避免控制器 Pod 重建后丢失状态目录；见 [第四节](#四controller-持久化与存储beegfs-csi)

---

## 一、同步镜像到 Harbor

集群若无法直连 `docker.io`、`ghcr.io`，需在一台能访问外网的机器上拉取镜像并推送到 Harbor。

仓库内脚本：`hack/push-slurm-operator-images-to-harbor.sh`

默认会同步（可通过环境变量覆盖）：

- Operator：`slurm-operator`、`slurm-operator-webhook`
- Slurm 组件：`slurmctld`、`slurmd`、`slurmrestd`、`slurmdbd`、`login`
- 侧车：`docker.io/library/alpine`（对应 Harbor 中 `alpine:latest`）

常用环境变量：


| 变量                                    | 说明                                                                                           |
| ------------------------------------- | -------------------------------------------------------------------------------------------- |
| `HARBOR_REGISTRY`                     | Harbor 地址，如 `harbor.example.com:8443`                                                        |
| `HARBOR_PROJECT`                      | 项目名，如 `slinkyproject`                                                                        |
| `HARBOR_USERNAME` / `HARBOR_PASSWORD` | Harbor 登录                                                                                    |
| `SLINKY_VERSION`                      | Slurm 镜像 tag，默认 `25.11-ubuntu24.04`                                                          |
| `OPERATOR_VERSION`                    | Operator / webhook 镜像 tag，默认 `1.1.0-rc1`（应与 `helm/slurm-operator/Chart.yaml` 的 `version` 一致） |
| `EXTRA_SOURCE_IMAGES`                 | 逗号分隔的额外镜像（如 cert-manager 等）                                                                  |


示例：

```bash
export HARBOR_REGISTRY="harbor.example.com:8443"
export HARBOR_PROJECT="slinkyproject"
export HARBOR_USERNAME="admin"
export HARBOR_PASSWORD='你的密码'

bash hack/push-slurm-operator-images-to-harbor.sh
```

推送后，Harbor 中镜像路径形如：

`{HARBOR_REGISTRY}/{HARBOR_PROJECT}/{镜像名}:{tag}`

例如：`harbor.example.com:8443/slinkyproject/alpine:latest`

---

## 二、配置 Helm values 使用 Harbor

将 chart 默认的 `ghcr.io/slinkyproject/...` 与 `docker.io/library/alpine` 改为 Harbor 仓库地址。

本仓库已提供示例修改（请按实际 Harbor 地址替换）：

- `helm/slurm/values.yaml`：各组件 `repository` 指向 Harbor
- `helm/slurm-operator/values.yaml`：operator / webhook 镜像

若 Harbor 为私有仓库，需在对应 `values` 中配置 `imagePullSecrets`（与 Kubernetes `docker-registry` 类型 Secret 一致）。

---

## 三、安装 Operator 与 Slurm

在**本仓库根目录**执行（与 chart 版本、模板一致，推荐）。cert-manager 仍使用上游 chart；CRDs、Operator、Slurm 使用本地路径 `**helm/slurm-operator-crds`**、`**helm/slurm-operator**`、`**helm/slurm**`：

```bash
cd /path/to/slurm-operator   # 替换为克隆路径

helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

helm install slurm-operator-crds ./helm/slurm-operator-crds

helm install slurm-operator ./helm/slurm-operator \
  --namespace=slinky --create-namespace \
  -f helm/slurm-operator/values.yaml

helm install slurm ./helm/slurm \
  --namespace=slurm --create-namespace \
  -f helm/slurm/values.yaml
```

升级时把 `helm install` 改为 `**helm upgrade --install**`，并保持相同 chart 路径与 `-f` 文件即可。

> **注意**：若 cert-manager 未安装且不想用，可对 `slurm-operator` 使用 `--set certManager.enabled=false`（见官方 `installation.md`）。

> **OCI chart**：若仍需从 `oci://ghcr.io/slinkyproject/charts/...` 安装，请注意 **Slurm chart 发布版本**（如 1.0.2）可能与当前仓库 `helm/slurm` 的 `Chart.yaml` 版本、模板不一致；LDAP/SSSD 等与 `values` 键路径相关的说明见 [第六节](#六sssd-与-ldap-说明)。

---

## 四、Controller 持久化与存储（BeeGFS CSI）

`slurmctld` 可将状态目录落在 PVC 上，控制器 Pod 删除/重建后仍能保留数据。chart 通过 `controller.persistence` 配置动态供给或已有 PVC。

### 4.1 已部署 BeeGFS CSI：推荐开启持久化

若集群中 **BeeGFS CSI** 已就绪（存在可用的 `StorageClass`），建议在 **首次安装 Slurm** 前，在 `helm/slurm/values.yaml` 中显式指定 BeeGFS 的 StorageClass，并开启持久化：

1. **确认 StorageClass 名称**（以你集群实际为准）：

```bash
kubectl get storageclass
```

记下 BeeGFS CSI 对应的 `NAME`（例如 `beegfs-sc`、`beegfs` 等，以你的安装为准）。

1. **在 values 中配置**（示例，请替换 `storageClassName` 与容量）：

```yaml
controller:
  persistence:
    enabled: true
    # 使用 BeeGFS CSI 提供的 StorageClass
    storageClassName: beegfs-sc   # 改为你的 StorageClass 名称
    accessModes:
      - ReadWriteOnce              # 单副本 slurmctld 通常使用 RWO；若你的 CSI 仅支持 RWX，请按存储说明调整
    resources:
      requests:
        storage: 4Gi              # 按需调整
```

1. **安装后检查 PVC 与绑定**：

```bash
kubectl get pvc -n slurm
kubectl describe pvc -n slurm  # 确认 STATUS 为 Bound，STORAGECLASS 为你的 BeeGFS SC
```

**说明：**

- BeeGFS 为并行文件系统，具体 **accessMode**、是否支持 **ReadWriteMany** 取决于你安装的 BeeGFS CSI 与后端配置；`slurmctld` 为单 Pod 时 **ReadWriteOnce** 通常即可。
- 若 `storageClassName` 留空（`null`），会使用集群 **默认 StorageClass**；只有默认 SC 指向 BeeGFS 时才会落到 BeeGFS 上，否则建议显式填写 `storageClassName`。
- **作业共享目录**（如 `/home`、数据集）如需挂载 BeeGFS，可在 chart 的 `nodesets.*.podSpec.volumes` / `volumeMounts`、`loginsets` 等处自行增加 PVC 或 CSI 卷定义，详见 `helm/slurm/values.yaml` 注释与官方 [installation.md](./installation.md)。

### 4.2 无可用 StorageClass：关闭 Controller 持久化

若集群**没有**可用的动态供给（含 BeeGFS CSI 未就绪、无默认 SC），会出现：

`pod has unbound immediate PersistentVolumeClaims`

处理方式：在 `helm/slurm/values.yaml` 中关闭持久化：

```yaml
controller:
  persistence:
    enabled: false
```

> **重要**：Operator 的 Admission Webhook 会限制 `**persistence.enabled` 在首次部署后无法直接改为相反值**。若已用 `enabled: false` 部署过，再改为 `enabled: true`（或反过来）可能 `helm upgrade` 失败，需：
>
> - **卸载** `slurm` release 后**重新安装**（会重建 CRD 管理的资源，生产环境请先评估数据与备份），或
> - 首次安装前就按本节选好是否持久化及 `storageClassName`。

**建议**：若你**已部署 BeeGFS CSI**，优先在**第一次** `helm install slurm` 时使用 `4.1` 的配置，避免后续因 webhook 无法在线切换持久化开关。

---

## 五、验证集群

```bash
kubectl get pods -n slurm
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- scontrol ping
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- sinfo -N -l
```

提交测试作业：

```bash
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
  sbatch --wrap="hostname; sleep 3; echo hello-slurm"
```

查看作业（不依赖 accounting 时）：

```bash
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- squeue
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- scontrol show job <JOBID>
```

Worker 日志：

```bash
kubectl logs -n slurm slurm-worker-<nodeset>-0 -c slurmd --tail=100
```

---

## 六、SSSD 与 LDAP 说明

- chart 默认 `sssd.conf` 中的 `ldap://ldap.example.com` 等为 **示例占位**，**不会**自动安装 LDAP 服务器。
- 未接入真实 LDAP 时，`sssd` 可能报错 `No domain is enabled`，一般**不影响**仅验证 Slurm 调度与 `sbatch`。
- 要让 **LoginSet** 通过 LDAP 做 NSS/PAM（`getent passwd`、SSH 用 LDAP 用户等），需要：
  1. 有可达的 LDAP（例如 `examples/openldap-bitnami-minimal.yaml`）；
  2. 在 **Helm `values`** 里改顶层 `**sssd.conf**`（键名：`sssd.conf`，与 `helm/slurm/values.yaml` 中 `sssd:` 段一致）；
  3. 启用 `**loginsets.<name>.enabled: true**`（如 `loginsets.slinky.enabled`），否则不会起带 sssd 的登录 Pod。

### 6.0 若仍使用 OCI 的 Slurm chart（如 `ghcr.io/.../slurm:1.0.2`）

本仓库 **第三节** 推荐 `**./helm/slurm`**，其模板使用顶层 `**sssd.conf**` 与 Secret `**slurm-sssd-conf**`。

若你改用 `**oci://ghcr.io/slinkyproject/charts/slurm**` 的**旧发布版**（例如 1.0.2），需注意：Secret `**slurm-login-<loginset>-sssd-conf`** 往往来自 `**loginsets.<loginset>.sssdConf**`，**不会**读取顶层 `**sssd.conf`**。此时必须在对应 `**loginsets.*.sssdConf**` 中写入完整 `sssd.conf` 正文，否则 Pod 内会一直仍是默认 `ldap.example.com`。

修改 Secret 后，建议 `**kubectl rollout restart deployment -n slurm slurm-login-slinky**`（或删除对应 Login Pod），确保新 Pod 挂载更新后的配置。

### 6.1 改哪里

在 **安装/升级 Slurm chart 时使用的 `values` 文件** 中设置 sssd，取决于 chart 来源：


| Chart                      | 应修改的键                                        |
| -------------------------- | -------------------------------------------- |
| **本仓库 `./helm/slurm`（推荐）** | 顶层 `**sssd.conf`**（及可选 `**sssd.secretRef**`） |
| **OCI slurm-1.0.x**（旧发布）   | `**loginsets.<名称>.sssdConf`**（否则 Secret 不更新） |



| 方式                     | 说明                                                                                  |
| ---------------------- | ----------------------------------------------------------------------------------- |
| `**sssd.conf**`（多行字符串） | 本仓库 `./helm/slurm`：把整个 `[sssd]` / `[domain/DEFAULT]` 配好即可。                          |
| `**sssd.secretRef**`   | 指向已有 Secret 的 `sssd.conf`；**若设置了非空 `secretRef`，会覆盖 `sssd.conf` 字符串**。生产更建议用 Secret。 |


OCI 旧版 Slurm chart 若无顶层 `sssd` 模板，`**sssd.secretRef` 可能不适用**，请用 `**loginsets.*.sssdConf`**（见 §6.0）。

### 6.2 与 `examples/openldap-bitnami-minimal.yaml` 对齐的示例

该示例部署 **Bitnami 系 OpenLDAP**（Harbor：`./hack/push-bitnami-openldap-to-harbor.sh`）与 **phpLDAPadmin v2**（`phpldapadmin/phpldapadmin`，Harbor：`./hack/push-phpldapadmin-to-harbor.sh`）。NodePort **30880** 对应浏览器 `http://<节点IP>:30880/`（v2 为 Laravel 应用，非旧版 `/phpldapadmin` 路径）。需先用 `./hack/gen-openldap-bitnami-tls-secret.sh <namespace>` 生成 Secret **`openldap-bitnami-tls`**，再 `kubectl apply` 清单。目录根为 `**dc=example,dc=org**`；**OpenLDAP 根 DN** 为 `**cn=admin,dc=example,dc=org**`，密码默认 `**admin**`（与 `LDAP_ADMIN_PASSWORD` 一致，仅实验环境）。**phpLDAPadmin 网页登录**请用预置 **`user01` / `bitnami1`**（uid），勿在登录框使用 **`cn=admin`**（见下文 **phpLDAPadmin v2 网页登录**）。

**Docker Compose（与清单功能对齐）**：`examples/docker-compose.openldap.yml` 提供同一组合（Bitnami OpenLDAP + phpLDAPadmin v2 + TLS）。先执行 `./hack/gen-openldap-compose-certs.sh` 生成 `examples/openldap-certs/`，再 `docker compose -f examples/docker-compose.openldap.yml up -d`；浏览器访问 **`phpldapadmin`** 映射端口（清单中常见 **`8080:8080`** 或 **`18080:8080`**，以 compose 为准）。OpenLDAP 在 Compose 内直接监听 **389/636**，**`cap_add: [NET_BIND_SERVICE]`**，phpLDAPadmin 使用 **`LDAP_HOST=openldap`**、**`LDAP_PORT=389`**。持久化使用 **`LDAP_DATA_ROOT`**（默认 `examples/data/`）下 **`ldap/`** 与 **`slapd.d/`** 两个子目录分别挂载 **`/bitnami/openldap/data`** 与 **`/bitnami/openldap/slapd.d`**；仅挂 **`data`** 会在 **`docker compose down`** 后丢失容器层里的 **`slapd.d`**，导致再次 **`up`** 时出现 **「Using persisted data」后 slapd 立刻退出**。Compose 内含 **`openldap-data-init`** 做 **mkdir + chown 1001**。**phpLDAPadmin** 仅 **`depends_on: service_started`**（勿强依赖 **`service_healthy`**：首次 slapadd+TLS 较慢，否则 Compose 易整条栈失败）。镜像可通过 **`OPENLDAP_IMAGE` / `PHPLDAPADMIN_IMAGE`** 指向 Harbor，与推送脚本一致。

**phpLDAPadmin v2 网页登录**：默认 **`LDAP_LOGIN_ATTR=uid`**（按 **uid** 登录，不是 **`cn=admin`**）。**`LDAP_USERNAME`/`LDAP_PASSWORD`** 是 PLA **连目录**用的根 DN（`cn=admin,dc=example,dc=org` / `admin`），**目录树里没有** `cn=admin` 这条目，**不能**在登录框当用户用。Bitnami 预置测试用户：**`user01` / `bitnami1`**，**`user02` / `bitnami2`**。若要用完整 DN 登录，将 **`LDAP_LOGIN_ATTR`** 设为 **`DN`**。

假设 OpenLDAP 在命名空间 `**openldap-test**`，Service 名 `**openldap**`；Slurm 在 `**slurm**`。集群内应用应使用 **FQDN** 访问 LDAP：

```text
ldap://openldap.openldap-test.svc.cluster.local
```

用户在 phpLDAPadmin 里若建在 `**ou=people**`、组在 `**ou=groups**`（请按你实际 OU 修改），`values` 中可写成：

```yaml
sssd:
  conf: |
    [sssd]
    config_file_version = 2
    services = nss,pam
    domains = DEFAULT

    [nss]
    filter_groups = root,slurm
    filter_users = root,slurm

    [pam]

    [domain/DEFAULT]
    auth_provider = ldap
    id_provider = ldap
    ldap_uri = ldap://openldap.openldap-test.svc.cluster.local
    ldap_search_base = dc=example,dc=org
    ldap_user_search_base = ou=people,dc=example,dc=org
    ldap_group_search_base = ou=groups,dc=example,dc=org
    ldap_default_bind_dn = cn=admin,dc=example,dc=org
    ldap_default_authtok_type = password
    ldap_default_authtok = admin
    ldap_id_mapping = false
    ldap_schema = rfc2307bis
    ldap_id_use_start_tls = true
    ldap_tls_reqcert = never
    ldap_tls_cipher_suite = "NORMAL:-VERS-TLS1.3"
```

说明：

- `**ldap_uri**`：必须是 **LoginSet Pod 能解析并访问** 的地址；LDAP 与 Slurm **同命名空间** 时可简写为 `ldap://openldap`（仅当 DNS search 能解析到该 Service 时可靠，跨 namespace 请用 **完整 `*.svc.cluster.local`**）。
- `**ldap_user_search_base` / `ldap_group_search_base**`：必须覆盖你在 LDAP 里建用户、建 `**posixGroup**` 的位置；若只有 `ou=people` 没有单独 `ou=groups`，可把 `ldap_group_search_base` 也设为 `ou=people` 或先建 `ou=groups`。
- `**ldap_default_bind_dn` / `ldap_default_authtok**`：给 sssd 用于查目录；密码写在 `values` 里仅适合实验，生产请改用 `**sssd.secretRef**` 或外部 Secret 注入完整 `sssd.conf`。
- `**ldap_id_mapping = false**`：与你在 LDAP 里手填的 `**uidNumber` / `gidNumber**` 一致时，常用此设置；若改用 AD 等再查文档是否改为 `true`。
- **SSSD 与「明文 ldap://」**：SSSD 的 **LDAP 口令认证**需要**加密通道**（[官方 FAQ](https://docs.pagure.org/sssd.sssd/users/faq.html)）。仅关 `**ldap_id_use_start_tls`** 仍走明文时，**SSH/PAM** 会失败并常出现 `**No available servers for service 'LDAP'`** / `**SSSD is offline**`，而 `**getent**` 有时仍因缓存看似正常。**实验环境**推荐：LDAP 端在 389 上启用 **StartTLS**（本示例中 Bitnami 设 `**LDAP_ENABLE_TLS=yes**` 并提供证书 Secret），客户端设 `**ldap_id_use_start_tls = true`**、`**ldap_tls_reqcert = never**`。**勿**在 `sssd.conf` 里写 `**ldap_auth_disable_tls_never_use_in_production`**：Ubuntu 24.04 自带的 SSSD 2.9 **配置校验会报该选项 not allowed**，整段域配置可能异常。
- **Ubuntu 24.04 Login + 旧 osixia OpenLDAP（遗留环境）**：若 slapd 仍是很老的 **osixia** 镜像，`libldap`（**GnuTLS**）与容器内 **OpenSSL 1.1** 的 **StartTLS** 可能异常断开（`-11` / SSSD **offline**）。在 `**[domain/DEFAULT]**` 可试 `**ldap_tls_cipher_suite = "NORMAL:-VERS-TLS1.3"**`（**须加双引号**）。根本办法是换 **Bitnami/bitnamilegacy**（本仓库示例）或排查 **MTU**。
- **镜像与 Harbor**：Broadcom 将 Debian 一代放在 `**docker.io/bitnamilegacy/openldap**`；`docker.io/bitnami/openldap` 上同名 `**2.6.x-debian-12-rNN**` 常 **manifest unknown**。示例默认 **`harbor.aix.com:8443/library/bitnami-openldap:2.6.10-debian-12-r1`**，需先 `./hack/push-bitnami-openldap-to-harbor.sh`。证书仍需自行轮换（`gen-openldap-bitnami-tls-secret.sh`）；**cleanstart/openldap** 等第三方镜像**不能**直接套用本示例的 `LDAP_*` env，见 [cleanstart-containers/openldap](https://github.com/cleanstart-containers/openldap)。
- **SSSD 2.9+（如 Login 镜像基于 Ubuntu 24.04）**：若 `kubectl logs` 出现 `**pam_passkey_get_user_done`**、`**No such file or directory**`，且密码登录始终失败，在 `**[pam]**` 段增加 `**pam_passkey_auth = false**`（容器内无 FIDO 设备时 passkey 分支会报错）。
- `**ldap_group_search_base**`：若目录中**没有**对应 OU（例如未建 `ou=groups`），可改为 `**dc=example,dc=org`** 等更宽的 base，避免 SSSD 异常。
- **多 URI / referral**：`ldap_uri` 可配置 **ClusterIP 与 FQDN 双 URI**（逗号分隔）作备份；`**ldap_referrals = false`** 可减少 referral 带来的连接问题。
- `**sudo_provider = none**`：`id_provider=ldap` 时 SSSD 默认会从 LDAP 拉 **sudoers**，可能与 SSH 认证并发连同一后端，在轻量 OpenLDAP 上易触发 `**No available servers for LDAP`**；Login 节点若不需要 LDAP sudo，建议关闭。

同时启用 LoginSet，例如：

```yaml
loginsets:
  slinky:
    enabled: true
```

升级 release 后，在 **LoginSet 对应 Pod**（名称含 `login`，具体以 `kubectl get pods -n slurm` 为准）内执行：

```bash
kubectl get pods -n slurm | grep login
kubectl exec -n slurm <login-pod> -- getent passwd <你的LDAP用户名>
```

若 Pod 多容器，需加 `-c <容器名>`。若 `getent` 无输出，检查 OU、base、`ldap_uri` 网络连通及 sssd 日志。

- **SSH 能连、`getent passwd` 有用户，但密码总错 / `PAM: Authentication failure`，且日志仍有 `No available servers for service 'LDAP'`**：[SSSD FAQ](https://docs.pagure.org/sssd.sssd/users/faq.html) 要求 **`ldap://` 时口令认证也必须经 TLS**；仅设 **`ldap_id_use_start_tls = false`** 不能绕过 PAM（往往仍尝试 StartTLS 或拒绝明文口令）。Ubuntu 24.04 自带 **SSSD 2.9.4** 还会在配置校验里**拒绝** **`ldap_auth_disable_tls_never_use_in_production`**（域段报 *Attribute is not allowed*）。**结论**：必须让 **StartTLS 在客户端与 slapd 之间真正成功**（Login Pod 内 **`openssl s_client -connect <IP>:389 -starttls ldap`** 不再报 **`LDAP Result Code: 2`**），或改用可工作的 **LDAPS:636**、或排查 slapd/`BITNAMI_DEBUG` 日志。在修通前可临时用 **`loginsets.slinky.rootSshAuthorizedKeys`** SSH **root** 进 Login，再查集群。
- **OpenLDAP 日志出现 `do_extended: unsupported operation`（StartTLS OID）/ `kubectl logs` 仍 `ldap_install_tls failed`**：常见原因是 **`cn=config` 未写入 `olcTLSCertificate*`**。Bitnami 以 **UID 1001** 读 **`/certs/tls.key`**；若宿主机上私钥为 **600** 且属主不是 **1001**，首次初始化不会把 TLS 写进 slapd，**StartTLS 与 LDAPS 均异常**。处理：**`sudo chown 1001:1001` 证书三文件、`chmod 640 tls.key`**，再 **`./hack/apply-openldap-slapd-tls.sh`**（或清空 `slapd.d` 后重建）。SSSD 侧推荐 **`ldaps://<IP>:636`** + **`ldap_id_use_start_tls = false`**；若 **`ldap_install_tls` / unknown error**，把 **`ldap_tls_cipher_suite`** 改为 **`NORMAL`**（见当前 `helm/slurm/values.yaml`）。

---

## 七、Accounting（账务）

默认 `accounting.enabled: false` 时，`sacct` 会提示类似：

`Slurm accounting storage is disabled`

需要账务历史时，在 `values` 中启用 accounting，并配置 slurmdbd 与数据库（如 MariaDB），详见官方 [installation.md](./installation.md) 中 *With Accounting* 章节。

---

## 八、常见问题

### 1. Init 容器拉取 `docker.io/library/alpine:latest` 失败

- 原因：节点无法访问 Docker Hub。
- 处理：将 `alpine` 同步到 Harbor，并在 `values` 中把 logfile 等侧车镜像改为 Harbor 路径；或使用 `hack/push-slurm-operator-images-to-harbor.sh` 一并推送。

### 2. 已改 values 但 Pod 仍用旧镜像

- 旧 Pod 可能仍使用旧模板。可删除对应 Pod 让控制器重建；若仍异常，检查 `helm get values` 与 `kubectl get nodeset -n slurm -o yaml` 中的镜像字段。

### 3. `helm upgrade` 修改 `persistence.enabled` 失败

- 见 [第四节](#四controller-持久化与存储beegfs-csi)。

### 4. PVC 已 Bound 但 slurm-controller 仍 Pending（含 BeeGFS）

- 检查 Pod 事件：`kubectl describe pod slurm-controller-0 -n slurm`。
- 确认节点可挂载 BeeGFS 客户端、CSI 驱动 Pod 正常、以及 StorageClass / PVC 的 accessMode 与调度策略是否匹配。

### 5. NodeSet 无 Worker Pod、Operator 报错

- 若 `slurm-controller` 已就绪但长时间无 worker，可尝试重启 `slurm-operator` Deployment 触发 reconcile：

```bash
kubectl rollout restart deploy/slurm-operator -n slinky
```

### 6. Operator 日志中与 ServiceMonitor 相关错误

- 若集群未安装 Prometheus Operator CRD，可能出现 `ServiceMonitor` 相关错误。可按需安装对应 CRD 或关闭 chart 中与 metrics/ServiceMonitor 相关的选项（以实际 chart 版本为准）。

### 7. `examples/openldap-bitnami-minimal.yaml` 部署后 openldap **ContainerCreating** / **CrashLoopBackOff** / phpLDAPadmin **Ready 0/1**

- **openldap 长期 ContainerCreating**，`kubectl describe pod` 事件为 **`secret "openldap-bitnami-tls" not found`**：必须先执行 `./hack/gen-openldap-bitnami-tls-secret.sh <namespace>` 再 apply，或补建同名 Secret 后删除 Pod 重建。
- **网上镜像是不是坏的？**：**不是。** 官方路径应为 **`docker.io/bitnamilegacy/openldap`**（Debian 一代）。勿与 **`docker.io/bitnami/openldap`**（新代/Photon）混淆。推送前可在联网机器执行 `./hack/verify-bitnami-openldap-image.sh`。
- **Docker Hub 的 digest 与 Harbor 的 digest 为何不同？**：**正常现象。** 同一镜像 `docker tag` 后 `docker push` 到 Harbor，`docker push` 结尾打印的 digest（例如 **`sha256:627f63…`**）与 **Docker Hub** 上该 tag 的 digest（例如 **`sha256:687f14…`**）**可以不同**：OCI **manifest** 内容含 registry/仓库名等元数据，跨 registry **顶层 digest** 会变；**层（layer）**一致即可。因此 **不要在 `image` 里把 `harbor.../bitnami-openldap` 写成 `...@sha256:687f14…`（那是 Docker Hub 的 manifest digest）**；应使用 Harbor 的 tag，或 **`...@sha256:<Harbor 推送后显示的 digest>`**。
- **openldap CrashLoopBackOff**，**`BITNAMI_DEBUG=true`** 时日志出现 **`slapadd: could not add entry dn="cn=config"`**（或停在 **`Creating slapd.ldif`**）：**勿用 emptyDir/PVC 整卷挂载 `/bitnami/openldap`**（会触发非 root + LMDB 在部分节点上的初始化失败）。本仓库示例已改为**不挂该路径**（最小演示数据在容器层，删 Pod 即丢）；生产请 **只挂 `/bitnami/openldap/data`** 并做好 **fsGroup / initContainer 权限**（可参考 Bitnami OpenLDAP Helm）。若仍怀疑镜像，再核对 Harbor 与 **`./hack/verify-bitnami-openldap-image.sh`**。
- **`daemon: bind(6) failed errno=13 (Permission denied)`** / **`OpenLDAP failed to start`**（已通过 **`Creating slapd.ldif`** 之后）：Bitnami 以 **UID 1001** 运行，**默认不能绑定 389/636**；单机 Docker 常未 drop **capabilities**，镜像可能内部改用 **1389** 等高端口，而 **Kubernetes** 里若仍尝试绑定特权端口会失败。示例已改为容器内 **`LDAP_PORT_NUMBER=1389`、`LDAP_LDAPS_PORT_NUMBER=1636`**，**Service 仍对外 389/636**（`targetPort` 指向 Pod 的 1389/1636），客户端 **`ldap://…:389`** 无需改。若坚持容器内监听 389，可为容器 **`capabilities.add: [NET_BIND_SERVICE]`**（部分受限集群上能力可能仍不生效）。
- **phpLDAPadmin 探针失败 HTTP 500**：若健康检查指向 `/` 会重定向到 `/login`，在 LDAP 未就绪时易 500。示例已改为探针访问 Laravel **`/up`**（不依赖 LDAP）。若 openldap 仍未 Running，浏览器打开 `/login` 仍可能 500，属「连不上 LDAP」，待 openldap Ready 后刷新即可。

---

## 参考

- 官方安装：`docs/installation.md`
- 项目 README：`README.md`

