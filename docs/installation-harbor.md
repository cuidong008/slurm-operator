# Slurm（Slinky）安装说明：Harbor 镜像与常见问题

本文档基于在**内网 / 无外网镜像拉取**环境下的部署实践整理，与官方 [installation.md](./installation.md) 配合使用。

## 目录

- [架构说明](#架构说明)
- [前置条件](#前置条件)
- [一、同步镜像到 Harbor](#一同步镜像到 Harbor)
- [二、配置 Helm values 使用 Harbor](#二配置-helm-values-使用-harbor)
- [二点五、不同分区使用不同镜像（策略）](#二点五不同分区使用不同镜像策略)
- [三、安装 Operator 与 Slurm](#三安装-operator-与-slurm)
- [三点五、时间同步（强烈建议）](#三点五时间同步强烈建议)
- [四、Controller 持久化与存储（BeeGFS CSI）](#四controller-持久化与存储beegfs-csi)（**4.2** 含共享家目录与「共享卷上为 LDAP 用户创建家目录」；**4.3** 为 existingClaim。）
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

## 二点五、不同分区使用不同镜像（策略）

Slurm 里**分区（partition）**可以把不同节点划给不同队列；在 Slinky Operator 模型里，**计算节点镜像不是按「分区名」单独配置**，而是按 **NodeSet**：每个 NodeSet 的 `nodesets.<名称>.slurmd.image`（`repository` / `tag`）决定该组 `slurmd` Pod 使用的镜像。Helm 顶层 **`partitions`** 只是把 **Slurm 分区**与 **哪些 NodeSet 属于该分区**关联起来，本身不携带镜像字段。

因此，若希望「不同分区对应不同软件栈 / 不同镜像」，推荐策略如下：

1. **为每种环境定义一个 NodeSet**（例如 `cpu`、`gpu`、`legacy`），在每个 NodeSet 下设置各自的 **`slurmd.image`**，指向 Harbor 中已推送的镜像（路径形如 `{HARBOR_REGISTRY}/{HARBOR_PROJECT}/slurmd:...`，与 [第一节](#一同步镜像到-harbor) 一致）。
2. **在 `partitions` 里为每个 Slurm 分区指定 `nodesets`**，只包含对应的 NodeSet 名称（与 `values.yaml` 里 `nodesets:` 下的键一致）；需要多个 NodeSet 同属一个分区时，在同一分区下列多个名称即可。**不要写 `ALL`**：chart 会生成 Slurm 的 `Nodes=ALL`，容易把所有 NodeSet 都归进该分区；本仓库 chart 已对 `nodesets` 中的字面量 `ALL` **直接报错**，请显式列举（如 `slinky`、`gpu`）。
3. **同步镜像**：除默认 `slurmd` 外，每增加一种自定义 Worker 镜像，都要能从内网拉取；可用 `hack/push-slurm-operator-images-to-harbor.sh` 的 `EXTRA_SOURCE_IMAGES` 推送额外 tag，或单独 `docker pull/tag/push` 到 Harbor。
4. **作业侧再选容器（可选）**：若已启用 Pyxis/enroot 等，作业可通过 `--container-image=...` 在计算节点上启动**另一层** OCI 镜像，与节点基础镜像叠加；详见仓库内 [`docs/usage/pyxis.md`](./usage/pyxis.md)。插件与镜像需在各目标 NodeSet 上一致，并用 `--partition` / `--constraint` 等约束作业落点。

**Login 节点是否也要不同镜像？**  
与 Slurm **分区**直接相关的是 **Worker（NodeSet / `slurmd`）** 镜像。**Login** 由 **`loginsets.<名称>.login.image`** 单独配置，**不会**随分区名自动切换；用户 SSH 到的是某个 LoginSet 暴露的 Service，不是「按 `-p 分区名` 选登录机」。

- 若只关心**批处理作业**跑在不同 Worker 镜像上：**只配多个 NodeSet + 分区**即可，Login 可以仍用一个镜像（例如通用交互、仅编辑与提交作业）。
- 若希望**登录环境与某类计算环境一致**（同款编译器/CUDA/模块、`srun`/`sbatch` 预检与 Worker 对齐、或 Login 上也要跑 enroot/pyxis 客户端等）：应为 **多个 LoginSet** 分别设置 `login.image`，与各类 Worker 镜像配套，并通过不同 Service / 入口让用户连到对应登录 Pod；或 **一个** LoginSet + **较全**的 `login` 镜像，再配合共享家目录、Environment Modules 等统一交互体验。

自定义 `login` 镜像同样需要推送到 Harbor（与 [第一节](#一同步镜像到-harbor) 相同流程）。

> **小结**：**镜像粒度是 NodeSet**；**分区**通过包含哪些 NodeSet 来间接决定「该分区上的作业跑在哪类镜像里」。同一 NodeSet 内所有副本共用同一 `slurmd` 镜像，无法在「仅改分区名」的前提下自动切换镜像。**Login** 按 LoginSet 配镜像，与分区无自动绑定；是否多套 `login` 镜像取决于你是否要强对齐交互式环境与各类 Worker。

---

## 三、安装 Operator 与 Slurm

在**本仓库根目录**执行（与 chart 版本、模板一致，推荐）。cert-manager 仍使用上游 chart；CRDs、Operator、Slurm 使用本地路径 `**helm/slurm-operator-crds`**、`**helm/slurm-operator`**、`**helm/slurm**`：

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

## 三点五、时间同步（强烈建议）

Slurm 组件（尤其 `slurmd` 与 `slurmctld`）使用基于时间的认证；若节点时间漂移（即使 2~3 分钟），常见报错为：

- `decode_jwt: token expired`
- `Protocol authentication error`

建议在 **master 与所有 worker/login 所在节点**统一启用可靠 NTP。下面给出 Ubuntu 上推荐的 `chrony` 方案（master 可直接执行，node1 替换主机名后同样执行）。

1. **安装并启用 chrony（替代 timesyncd）**

```bash
sudo apt-get update
sudo apt-get install -y chrony
sudo systemctl disable --now systemd-timesyncd || true
sudo systemctl enable --now chrony
```

2. **立即校时并查看状态**

```bash
sudo chronyc -a makestep
chronyc tracking
chronyc sources -v
```

3. **统一时区（可选，但建议一致）**

```bash
sudo timedatectl set-timezone Asia/Shanghai
timedatectl status
```

4. **验收标准**

- 两台机器 `date -u` 时间差尽量小于 1 秒（几秒内通常可接受）。
- `chronyc tracking` 显示 `Leap status     : Normal`。

5. **若已出现 worker 启动失败，校时后重建 Pod**

```bash
kubectl delete pod -n slurm <失败的worker或login-pod名>
kubectl get pod -n slurm -o wide -w
```

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
- **用户家目录**（与 LDAP `homeDirectory` 一致、Login 与计算节点同路径）见下文 **4.2** 及其中 **「共享卷上为 LDAP 用户创建家目录」**；其它数据集目录仍可按需在各 `nodesets.*.podSpec` / `loginsets.`* 上追加卷。

### 4.2 用户共享家目录（Login / 计算节点）

生产上常要求 SSH 登录节点与作业运行节点看到**同一套** `/home/...`。chart 提供顶层 `sharedHome`：在 **所有** 已启用的 LoginSet 与 NodeSet 上挂载同一块 PVC（默认路径 `/home`，卷名 `shared-home`）。

1. **LDAP**：用户 `homeDirectory` 必须落在挂载路径下（例如 `homeDirectory: /home/cuidong`）。
2. **存储**：需 **ReadWriteMany**（或你的 CSI 对多 Pod 挂载的等价能力）。BeeGFS 等并行文件系统通常配合动态 SC；也可由运维预先创建 PVC，再在 values 里引用。
3. **values 示例**（与 BeeGFS SC 名称以你集群为准）：

```yaml
sharedHome:
  enabled: true
  mountPath: /home
  volumeName: shared-home
  persistence:
    enabled: true
    create: true
    # storageClassName: csi-beegfs-dyn-sc-root   # 示例，按实际 SC 填写
    existingClaim: null                         # 若用已有 PVC，填名称并将 create: false
    accessModes:
      - ReadWriteMany
    size: 100Gi
```

Helm 会渲染 PVC，名称为 `**<slurm.fullname>-shared-home**`（可用 `helm template` 核对；随 `nameOverride` / `fullnameOverride` 变化），并在 LoginSet / NodeSet 的 Pod 上注入同一 `claimName`。`controller.persistence` 仅用于 **slurmctld 状态**，与 `sharedHome` 无关。

#### 共享卷上为 LDAP 用户创建家目录（`mkdir` / `chown`）

RWX 家目录卷挂载后，**PVC 根下默认没有** `/home/<用户名>` 这类子目录（chart 只挂载整卷到 `sharedHome.mountPath`，不会按 LDAP 自动建目录）。若 LDAP 中 `homeDirectory` 为 `/home/cuidong` 等而该路径不存在，SSH 登录常见：

`Could not chdir to home directory /home/...: No such file or directory`

> 若希望「用户首次 SSH 登录自动创建 `/home/<user>`」而不是手工 `mkdir/chown`，需要在 **login 镜像**内启用 `pam_mkhomedir`。当前 chart 仅挂载 `sshd_config`、`sssd.conf`，**不会挂载/覆盖** `/etc/pam.d/common-session`，因此要通过镜像层修改。

在 login 镜像 Dockerfile 中添加（Ubuntu/Debian）：

```dockerfile
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpam-modules \
 && rm -rf /var/lib/apt/lists/* \
 && grep -q "pam_mkhomedir.so" /etc/pam.d/common-session \
 || echo "session required pam_mkhomedir.so skel=/etc/skel umask=0027" >> /etc/pam.d/common-session
```

构建并推送该 login 镜像到 Harbor 后，在 `helm/slurm/values.yaml` 更新：

```yaml
loginsets:
  slinky:
    login:
      image:
        repository: <你的harbor>/<project>/login
        tag: <新tag>
```

然后执行 `helm upgrade --install` 让 Login Pod 重建。可在 Pod 内验证：

```bash
kubectl exec -n slurm deploy/slurm-login-slinky -- grep pam_mkhomedir /etc/pam.d/common-session
```

在**任意已挂载同一块家目录 PVC 的 Pod**里执行即可（所有 Login / Worker 会看到同一路径），一般以 **root** 操作：

1. **确认 UID/GID**（须与 LDAP `posixAccount` 的 `uidNumber` / `gidNumber` 一致）：
  - Login Pod 上 SSSD 已就绪时：
     记下输出里的 `uid=`、`gid=` 数字。
  - 若暂时无法 `id`，在 LDAP 上查该用户的 `uidNumber`、`gidNumber`。
2. **创建目录并改属主**（将 `cuidong`、`10001`、`10001` 换成实际用户名与 uid/gid；`/home` 与 values 里 `sharedHome.mountPath` 一致）：
  ```bash
   kubectl exec -n slurm deploy/slurm-login-slinky -- sh -c 'install -d -o 10001 -g 10001 -m 0750 /home/cuidong'
  ```
   若镜像里没有 `install`，可改用：
3. **说明**：在 BeeGFS 等共享文件系统上**只需做一次**；新增用户时重复上述步骤。`chmod` 可按单位安全策略改为 `0700` 等。

### 4.3 使用已有 PVC 作为共享家目录（existingClaim，不扩展 Operator）

若希望 **PVC 不由 Helm chart 创建**（例如：`helm uninstall` 时不随 release 删除、由运维或 GitOps 单独管理生命周期），使用顶层 `**sharedHome.persistence.existingClaim`**：**无需改 Operator**，chart 已支持只引用已有 PVC。

**操作顺序：**

1. **在目标命名空间**（例如 `slurm`）创建 PVC，**访问模式需 RWX**（或与你的 BeeGFS/并行文件系统要求一致），`storageClassName` 指向你的 BeeGFS 动态类等：

```yaml
# 示例：保存为 shared-home-pvc.yaml 后执行 kubectl apply -f
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: slurm-shared-home          # 名称自定，与下方 existingClaim 一致即可
  namespace: slurm
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: csi-beegfs-dyn-sc-root   # 改为集群实际 SC
  resources:
    requests:
      storage: 100Gi
```

```bash
kubectl apply -f shared-home-pvc.yaml
kubectl get pvc -n slurm slurm-shared-home   # 确认 Bound
```

1. **在 `helm/slurm/values.yaml` 中**关闭 chart 侧创建、填写已有 PVC 名：

```yaml
sharedHome:
  enabled: true
  mountPath: /home
  volumeName: shared-home
  persistence:
    enabled: true
    create: false                    # 关键：不让 Helm 再渲染 PVC 模板
    existingClaim: slurm-shared-home # 与上面 metadata.name 一致
    # 以下在 existingClaim 模式下仅作文档参考，实际以已建 PVC 为准
    storageClassName: null
    accessModes:
      - ReadWriteMany
    size: 100Gi
```

1. `**helm install` / `helm upgrade**` 安装 Slurm。LoginSet / NodeSet 会通过 `**claimName: <existingClaim>**` 挂载同一块卷。

**说明：**

- 与 **Helm 动态创建**（`create: true`、无 `existingClaim`）相比，**数据保留策略**由你管理 PVC 的方式决定；卸载 Slurm release **不会**自动删除你手工/GitOps 创建的 PVC（除非你在别处配置了级联删除）。
- PVC **名称不必**与 `<slurm.fullname>-shared-home` 相同；只要 `**existingClaim` 写对** 即可。
- 若希望名称与 Helm 默认一致（便于记忆），仍可用 `helm template` 查看当前 release 下 `<slurm.fullname>-shared-home` 的解析结果，创建同名 PVC 后再设 `existingClaim`。

### 4.4 无可用 StorageClass：关闭 Controller 持久化

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

本仓库 **第三节** 推荐 `**./helm/slurm`**，其模板使用顶层 `**sssd.conf`** 与 Secret `**slurm-sssd-conf**`。

若你改用 `**oci://ghcr.io/slinkyproject/charts/slurm**` 的**旧发布版**（例如 1.0.2），需注意：Secret `**slurm-login-<loginset>-sssd-conf`** 往往来自 `**loginsets.<loginset>.sssdConf`**，不会读取顶层 `**sssd.conf`**。此时必须在对应 `**loginsets.*.sssdConf`** 中写入完整 `sssd.conf` 正文，否则 Pod 内会一直仍是默认 `ldap.example.com`。

修改 Secret 后，建议 `**kubectl rollout restart deployment -n slurm slurm-login-slinky`**（或删除对应 Login Pod），确保新 Pod 挂载更新后的配置。

### 6.1 改哪里

在 **安装/升级 Slurm chart 时使用的 `values` 文件** 中设置 sssd，取决于 chart 来源：


| Chart                      | 应修改的键                                        |
| -------------------------- | -------------------------------------------- |
| **本仓库 `./helm/slurm`（推荐）** | 顶层 `**sssd.conf`**（及可选 `**sssd.secretRef`**） |
| **OCI slurm-1.0.x**（旧发布）   | `**loginsets.<名称>.sssdConf`**（否则 Secret 不更新） |



| 方式                     | 说明                                                                                  |
| ---------------------- | ----------------------------------------------------------------------------------- |
| `**sssd.conf`**（多行字符串） | 本仓库 `./helm/slurm`：把整个 `[sssd]` / `[domain/DEFAULT]` 配好即可。                          |
| `**sssd.secretRef`**   | 指向已有 Secret 的 `sssd.conf`；**若设置了非空 `secretRef`，会覆盖 `sssd.conf` 字符串**。生产更建议用 Secret。 |


OCI 旧版 Slurm chart 若无顶层 `sssd` 模板，`**sssd.secretRef` 可能不适用**，请用 `**loginsets.*.sssdConf`**（见 §6.0）。

### 6.2 与 `examples/openldap-bitnami-minimal.yaml` 对齐的示例

该示例部署 **Bitnami 系 OpenLDAP**（Harbor：`./hack/push-bitnami-openldap-to-harbor.sh`）与 **phpLDAPadmin v2**（`phpldapadmin/phpldapadmin`，Harbor：`./hack/push-phpldapadmin-to-harbor.sh`）。NodePort **30880** 对应浏览器 `http://<节点IP>:30880/`（v2 为 Laravel 应用，非旧版 `/phpldapadmin` 路径）。需先用 `./hack/gen-openldap-bitnami-tls-secret.sh <namespace>` 生成 Secret `**openldap-bitnami-tls`**，再 `kubectl apply` 清单。目录根为 `**dc=example,dc=org`**；OpenLDAP 根 DN 为 `**cn=admin,dc=example,dc=org**`，密码默认 `**admin**`（与 `LDAP_ADMIN_PASSWORD` 一致，仅实验环境）。**phpLDAPadmin 网页登录**请用预置 `**user01` / `bitnami1`**（uid），勿在登录框使用 `**cn=admin`**（见下文 **phpLDAPadmin v2 网页登录**）。

**Docker Compose（与清单功能对齐）**：`examples/docker-compose.openldap.yml` 提供同一组合（Bitnami OpenLDAP + phpLDAPadmin v2 + TLS）。先执行 `./hack/gen-openldap-compose-certs.sh` 生成 `examples/openldap-certs/`，再 `docker compose -f examples/docker-compose.openldap.yml up -d`；浏览器访问 `**phpldapadmin`** 映射端口（清单中常见 `**8080:8080`** 或 `**18080:8080`**，以 compose 为准）。OpenLDAP 在 Compose 内直接监听 **389/636**，`**cap_add: [NET_BIND_SERVICE]`**，phpLDAPadmin 使用 `**LDAP_HOST=openldap`**、`**LDAP_PORT=389**`。持久化使用 `**LDAP_DATA_ROOT**`（默认 `examples/data/`）下 `**ldap/**` 与 `**slapd.d/**` 两个子目录分别挂载 `**/bitnami/openldap/data**` 与 `**/bitnami/openldap/slapd.d**`；仅挂 `**data**` 会在 `**docker compose down**` 后丢失容器层里的 `**slapd.d**`，导致再次 `**up**` 时出现 「Using persisted data」后 slapd 立刻退出。Compose 内含 `**openldap-data-init**` 做 **mkdir + chown 1001**。**phpLDAPadmin** 仅 `**depends_on: service_started`**（勿强依赖 `**service_healthy`**：首次 slapadd+TLS 较慢，否则 Compose 易整条栈失败）。镜像可通过 `**OPENLDAP_IMAGE` / `PHPLDAPADMIN_IMAGE**` 指向 Harbor，与推送脚本一致。

**phpLDAPadmin v2 网页登录**：默认 `**LDAP_LOGIN_ATTR=uid`**（按 uid 登录，不是 `**cn=admin`**）。`**LDAP_USERNAME`/`LDAP_PASSWORD**` 是 PLA **连目录**用的根 DN（`cn=admin,dc=example,dc=org` / `admin`），**目录树里没有** `cn=admin` 这条目，**不能**在登录框当用户用。Bitnami 预置测试用户：`**user01` / `bitnami1`**，`**user02` / `bitnami2`**。若要用完整 DN 登录，将 `**LDAP_LOGIN_ATTR**` 设为 `**DN**`。

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
- **SSSD 与「明文 ldap://」**：SSSD 的 **LDAP 口令认证**需要**加密通道**（[官方 FAQ](https://docs.pagure.org/sssd.sssd/users/faq.html)）。仅关 `**ldap_id_use_start_tls`** 仍走明文时，**SSH/PAM** 会失败并常出现 `**No available servers for service 'LDAP'`** / `**SSSD is offline`**，而 `**getent`** 有时仍因缓存看似正常。实验环境推荐：LDAP 端在 389 上启用 StartTLS（本示例中 Bitnami 设 `**LDAP_ENABLE_TLS=yes**` 并提供证书 Secret），客户端设 `**ldap_id_use_start_tls = true`**、`**ldap_tls_reqcert = never`**。勿在 `sssd.conf` 里写 `**ldap_auth_disable_tls_never_use_in_production**`：Ubuntu 24.04 自带的 SSSD 2.9 **配置校验会报该选项 not allowed**，整段域配置可能异常。
- **Ubuntu 24.04 Login + 旧 osixia OpenLDAP（遗留环境）**：若 slapd 仍是很老的 **osixia** 镜像，`libldap`（**GnuTLS**）与容器内 **OpenSSL 1.1** 的 **StartTLS** 可能异常断开（`-11` / SSSD **offline**）。在 `**[domain/DEFAULT]`** 可试 `**ldap_tls_cipher_suite = "NORMAL:-VERS-TLS1.3"`**（**须加双引号**）。根本办法是换 **Bitnami/bitnamilegacy**（本仓库示例）或排查 **MTU**。
- **镜像与 Harbor**：Broadcom 将 Debian 一代放在 `**docker.io/bitnamilegacy/openldap`**；`docker.io/bitnami/openldap` 上同名 `**2.6.x-debian-12-rNN`** 常 manifest unknown。示例默认 `**harbor.aix.com:8443/library/bitnami-openldap:2.6.10-debian-12-r1**`，需先 `./hack/push-bitnami-openldap-to-harbor.sh`。证书仍需自行轮换（`gen-openldap-bitnami-tls-secret.sh`）；**cleanstart/openldap** 等第三方镜像**不能**直接套用本示例的 `LDAP_*` env，见 [cleanstart-containers/openldap](https://github.com/cleanstart-containers/openldap)。
- **SSSD 2.9+（如 Login 镜像基于 Ubuntu 24.04）**：若 `kubectl logs` 出现 `**pam_passkey_get_user_done`**、`**No such file or directory`**，且密码登录始终失败，在 `**[pam]**` 段增加 `**pam_passkey_auth = false**`（容器内无 FIDO 设备时 passkey 分支会报错）。
- `**ldap_group_search_base**`：若目录中**没有**对应 OU（例如未建 `ou=groups`），可改为 `**dc=example,dc=org`** 等更宽的 base，避免 SSSD 异常。
- **多 URI / referral**：`ldap_uri` 可配置 **ClusterIP 与 FQDN 双 URI**（逗号分隔）作备份；`**ldap_referrals = false`** 可减少 referral 带来的连接问题。
- `**sudo_provider = none`**：`id_provider=ldap` 时 SSSD 默认会从 LDAP 拉 sudoers，可能与 SSH 认证并发连同一后端，在轻量 OpenLDAP 上易触发 `**No available servers for LDAP`**；Login 节点若不需要 LDAP sudo，建议关闭。

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

- **SSH 能连、`getent passwd` 有用户，但密码总错 / `PAM: Authentication failure`，且日志仍有 `No available servers for service 'LDAP'`**：[SSSD FAQ](https://docs.pagure.org/sssd.sssd/users/faq.html) 要求 `**ldap://` 时口令认证也必须经 TLS**；仅设 `**ldap_id_use_start_tls = false`** 不能绕过 PAM（往往仍尝试 StartTLS 或拒绝明文口令）。Ubuntu 24.04 自带 **SSSD 2.9.4** 还会在配置校验里**拒绝** `**ldap_auth_disable_tls_never_use_in_production`*（域段报 Attribute is not allowed）。**结论**：必须让 **StartTLS 在客户端与 slapd 之间真正成功**（Login Pod 内 `**openssl s_client -connect <IP>:389 -starttls ldap*` 不再报 `**LDAP Result Code: 2`**），或改用可工作的 **LDAPS:636**、或排查 slapd/`BITNAMI_DEBUG` 日志。在修通前可临时用 `**loginsets.slinky.rootSshAuthorizedKeys`** SSH **root** 进 Login，再查集群。
- **OpenLDAP 日志出现 `do_extended: unsupported operation`（StartTLS OID）/ `kubectl logs` 仍 `ldap_install_tls failed`**：常见原因是 `**cn=config` 未写入 `olcTLSCertificate***`。Bitnami 以 **UID 1001** 读 `**/certs/tls.key`**；若宿主机上私钥为 600 且属主不是 1001，首次初始化不会把 TLS 写进 slapd，StartTLS 与 LDAPS 均异常。处理：`**sudo chown 1001:1001` 证书三文件、`chmod 640 tls.key`**，再 `**./hack/apply-openldap-slapd-tls.sh**`（或清空 `slapd.d` 后重建）。SSSD 侧推荐 `**ldaps://<IP>:636**` + `**ldap_id_use_start_tls = false**`；若 `**ldap_install_tls` / unknown error**，把 `**ldap_tls_cipher_suite`** 改为 `**NORMAL`**（见当前 `helm/slurm/values.yaml`）。

---

## 七、Accounting（账务）

未启用账务时，`sacct` 等会提示类似：`Slurm accounting storage is disabled`。启用后由集群内 `**slurmdbd` Pod** 写入 **MariaDB/MySQL**；本仓库 `helm/slurm/values.yaml` 可配置为 **slurmdbd 在集群内、数据库在集群外**。

### 7.1 模式说明


| 方式                        | `accounting.external` | 说明                                                        |
| ------------------------- | --------------------- | --------------------------------------------------------- |
| **库在外、slurmdbd 在集群内**（本节） | `false`               | `storageConfig.host` 指向外部 DB；密码用 **Secret**，勿写入 git。      |
| **整台 slurmdbd 在外**        | `true`                | 只配 `externalConfig`（外部 slurmdbd 地址），其它 accounting 内嵌字段忽略。 |


Controller CR 会在 `accounting.enabled: true` 时增加对同 release 下 **Accounting** 资源的引用；升级 `helm/slurm` 后等待 Operator 拉起 **slurmdbd** Pod。

### 7.2 在外部 MariaDB 上建库

**需要**先有空库（表一般由 **slurmdbd 首次连接**时初始化；若版本差异导致失败，再查 [Slurm accounting](https://slurm.schedmd.com/accounting.html) 与发行说明）。

在数据库主机上（示例库名 `slurm_acct_db` 与 chart 默认一致）：

```sql
CREATE DATABASE IF NOT EXISTS slurm_acct_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
```

**推荐**：专用账号（在 `values` 里把 `accounting.storageConfig.username` 设为 `slurm`）：

```sql
CREATE USER IF NOT EXISTS 'slurm'@'%' IDENTIFIED BY '你的强密码';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'%';
FLUSH PRIVILEGES;
```

若暂时使用 `root` 从 K8s 网段连接（**不推荐生产**），需保证存在可从 Pod 访问的账号（如 `root@'%'`）且对该库有权限；MariaDB 默认 `root` 仅 `localhost` 时，集群内 slurmdbd **连不上**。

### 7.3 在 Kubernetes 中创建数据库密码 Secret

**不要把数据库密码写进 `values.yaml` 提交到仓库。** chart 通过 `accounting.storageConfig.passwordKeyRef` 引用 Secret。

与本仓库当前示例一致时（Secret 名 `slurm-accounting-db`、键 `password`）：

```bash
kubectl create secret generic slurm-accounting-db -n slurm \
  --from-literal=password='你的数据库密码'
```

密码中含 `#` 等字符时，外层用**单引号**包住整段字面量。

### 7.4 `values` 中与外部库相关的字段（示例）

与「外部库在 `172.16.84.71:3306`」一类环境对应时，典型配置为：

```yaml
accounting:
  enabled: true
  external: false
  storageConfig:
    host: 172.16.84.71      # 改为你的 MariaDB 地址或 DNS
    port: 3306
    database: slurm_acct_db
    username: slurm         # 或 root（仅实验）；与 7.2 中创建的账号一致
    passwordKeyRef:
      name: slurm-accounting-db
      key: password
```

具体以你当前 `helm/slurm/values.yaml` 为准；镜像仓库若用 Harbor，仍需保证 `**slurmdbd` 镜像**可拉取（见 [第一节](#一同步镜像到-harbor)）。

### 7.5 网络与安全检查清单

- MariaDB `**bind-address`**：需监听可被 **Kubernetes 节点或 Pod 网段** 访问的地址（不能仅 `127.0.0.1`，否则 slurmdbd Pod 无法访问 `172.16.84.71:3306`）。
- **防火墙 / 安全组**：放行从集群到数据库端口的 TCP。
- 生产环境优先 **专用 DB 用户 + 最小权限**，避免 `root` + `%`。

### 7.6 安装顺序建议

1. 在外部 MariaDB 执行 [7.2](#72-在外部-mariadb-上建库)。
2. 创建 [7.3](#73-在-kubernetes-中创建数据库密码-secret)。
3. 确认 `values` 中 [7.4](#74-values-中与外部库相关的字段示例) 与 Secret 名、键一致。
4. `helm upgrade --install slurm ./helm/slurm -n slurm -f helm/slurm/values.yaml`（路径按实际）。
5. `kubectl get pods -n slurm`、`kubectl logs -n slurm -l ...`（slurmdbd 相关 Pod）确认连库成功；再在 Login 上试 `sacct`。

更通用的上游说明见官方 [installation.md](./installation.md) 中 *With Accounting* 章节。

### 7.7 `slurmdbd` 报 `1045`，但 `mysql` 客户端能连上

Slurm 的 `**slurmdbd.conf` 把 `#` 当作行内注释**。若数据库密码里含有 `**#`**（例如 `AbCd#1234`），未加引号时写成 `StoragePass=AbCd#1234` 会被解析成密码只有 `**AbCd`**，MySQL 即报 `**1045 Access denied**`，而你在 shell 里用 `mysql -p'AbCd#1234'` 仍可能正常。

**处理**：使用 **本仓库已修复的 slurm-operator 镜像**（生成配置时对 `StoragePass` 做双引号转义），**重新构建/部署 Operator** 后删除 `slurm-accounting-0` 重建；或 **临时**把数据库用户密码改成**不含 `#`** 的字符串，并同步更新 Secret。

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

- **openldap 长期 ContainerCreating**，`kubectl describe pod` 事件为 `**secret "openldap-bitnami-tls" not found`**：必须先执行 `./hack/gen-openldap-bitnami-tls-secret.sh <namespace>` 再 apply，或补建同名 Secret 后删除 Pod 重建。
- **网上镜像是不是坏的？**：**不是。** 官方路径应为 `**docker.io/bitnamilegacy/openldap`**（Debian 一代）。勿与 `**docker.io/bitnami/openldap`**（新代/Photon）混淆。推送前可在联网机器执行 `./hack/verify-bitnami-openldap-image.sh`。
- **Docker Hub 的 digest 与 Harbor 的 digest 为何不同？**：**正常现象。** 同一镜像 `docker tag` 后 `docker push` 到 Harbor，`docker push` 结尾打印的 digest（例如 `**sha256:627f63…`**）与 Docker Hub 上该 tag 的 digest（例如 `**sha256:687f14…`**）**可以不同**：OCI **manifest** 内容含 registry/仓库名等元数据，跨 registry **顶层 digest** 会变；**层（layer）**一致即可。因此 不要在 `image` 里把 `harbor.../bitnami-openldap` 写成 `...@sha256:687f14…`（那是 Docker Hub 的 manifest digest）；应使用 Harbor 的 tag，或 `**...@sha256:<Harbor 推送后显示的 digest>`**。
- **openldap CrashLoopBackOff**，`**BITNAMI_DEBUG=true`** 时日志出现 `**slapadd: could not add entry dn="cn=config"`**（或停在 `**Creating slapd.ldif`**）：勿用 emptyDir/PVC 整卷挂载 `/bitnami/openldap`（会触发非 root + LMDB 在部分节点上的初始化失败）。本仓库示例已改为**不挂该路径**（最小演示数据在容器层，删 Pod 即丢）；生产请 **只挂 `/bitnami/openldap/data`** 并做好 **fsGroup / initContainer 权限**（可参考 Bitnami OpenLDAP Helm）。若仍怀疑镜像，再核对 Harbor 与 `**./hack/verify-bitnami-openldap-image.sh`**。
- `**daemon: bind(6) failed errno=13 (Permission denied)`** / `**OpenLDAP failed to start`**（已通过 `**Creating slapd.ldif**` 之后）：Bitnami 以 **UID 1001** 运行，**默认不能绑定 389/636**；单机 Docker 常未 drop **capabilities**，镜像可能内部改用 **1389** 等高端口，而 **Kubernetes** 里若仍尝试绑定特权端口会失败。示例已改为容器内 `**LDAP_PORT_NUMBER=1389`、`LDAP_LDAPS_PORT_NUMBER=1636`**，Service 仍对外 389/636（`targetPort` 指向 Pod 的 1389/1636），客户端 `**ldap://…:389`** 无需改。若坚持容器内监听 389，可为容器 `**capabilities.add: [NET_BIND_SERVICE]**`（部分受限集群上能力可能仍不生效）。
- **phpLDAPadmin 探针失败 HTTP 500**：若健康检查指向 `/` 会重定向到 `/login`，在 LDAP 未就绪时易 500。示例已改为探针访问 Laravel `**/up`**（不依赖 LDAP）。若 openldap 仍未 Running，浏览器打开 `/login` 仍可能 500，属「连不上 LDAP」，待 openldap Ready 后刷新即可。

### 8. 自建 Operator 镜像：`go mod download` 超时（IPv6 / 代理 / 国内网络）

- `**Multi-platform build is not supported for the docker driver`**：`docker-bake.hcl` 默认只构建 `**linux/amd64`**，可直接用默认 `docker` 驱动执行 `docker buildx bake`。若你要 **amd64+arm64** 多架构，需使用支持多平台的 buildx 驱动（如 `docker-container`），并在 `docker-bake.hcl` 的 `PLATFORMS` 变量里加入 `linux/arm64`。
- **现象**：构建在 `RUN go mod download` 失败，日志类似 `dial tcp [2607:f8b0:...]:443: i/o timeout`（走 **IPv6** 访问 `proxy.golang.org`）或直连外网超时。
- **原因**：BuildKit 构建容器内 **Go 不一定自动使用** 你在宿主机 `export` 的 `http_proxy`；且部分环境 **IPv6 不可用** 时，Go 仍可能优先尝试 IPv6。
- **处理（任选其一或组合）**：
  1. **显式传入代理**（与宿主机代理一致）。`docker buildx bake` **没有** `--build-arg`，需用 `--set` 写到 **所有 bake target** 的 Dockerfile `ARG` 上，例如：
    ```bash
     docker buildx bake --push \
       --set "*.args.HTTP_PROXY=${http_proxy}" \
       --set "*.args.HTTPS_PROXY=${https_proxy}" \
       --set "*.args.NO_PROXY=${no_proxy}"
    ```
     （`*.args` 表示 bake 文件里**所有** target；`http_proxy` 等用小写时请与宿主机环境变量名一致。）
  2. **换模块代理**（国内或自建），例如：
    ```bash
     docker buildx bake --push --set "*.args.GOPROXY=https://goproxy.cn,direct"
    ```
  3. 本仓库 `Dockerfile` 已默认设置 `GODEBUG=netpreferipv4=1`；若你仍在旧分支上构建，可同步该 `Dockerfile` 或自行加入同等 `ENV`。
- **仅在完全无法访问 sum.golang.org 时**（不推荐长期）：可临时 `GOSUMDB=off` 构建，需自行承担校验被跳过的风险。

---

## 九、镜像工具体检记录（实测）

以下结果来自一次在线检查（`2026-03-24`，命名空间 `slurm`），用于评估 Login/Worker 镜像需补充的常用 HPC 工具。可作为后续镜像基线参考。

检查命令示例（Login）：

```bash
kubectl exec -n slurm deploy/slurm-login-slinky -- sh -lc 'for c in apptainer singularity module ml modulecmd mpirun mpiexec gcc g++ gfortran make cmake python3 pip3 jq rsync; do command -v "$c" >/dev/null 2>&1 && echo "OK $c" || echo "MISS $c"; done'
```

检查命令示例（Worker）：

```bash
kubectl exec -n slurm slurm-worker-slinky-0 -c slurmd -- sh -lc 'for c in apptainer singularity module ml modulecmd mpirun mpiexec gcc g++ gfortran make cmake python3 pip3 jq rsync; do command -v "$c" >/dev/null 2>&1 && echo "OK $c" || echo "MISS $c"; done'
```

### 9.1 Login Pod（`deploy/slurm-login-slinky`）结果

- `OK`：`mpirun`、`mpiexec`、`python3`、`pam_mkhomedir`
- `MISS`：`apptainer`、`singularity`、`module`、`ml`、`modulecmd`、`gcc`、`g++`、`gfortran`、`make`、`cmake`、`pip3`、`jq`、`rsync`

### 9.2 Worker Pod（`slurm-worker-slinky-0`，容器 `slurmd`）结果

- `OK`：`mpirun`、`mpiexec`、`python3`
- `MISS`：`apptainer`、`singularity`、`module`、`ml`、`modulecmd`、`gcc`、`g++`、`gfortran`、`make`、`cmake`、`pip3`、`jq`、`rsync`、`pam_mkhomedir`

### 9.3 结论与补充建议

- 若要支持常见 HPC 工作流（容器 + 模块 + 编译），建议在 Login/Worker 镜像统一补齐：
  - 容器运行时：`apptainer`（或 `singularity`，二选一并统一）
  - 环境模块：`lmod` / `environment-modules`（提供 `module`/`ml`）
  - 构建链：`gcc` `g++` `gfortran` `make` `cmake`
  - 常用运维工具：`pip3` `jq` `rsync`
- `pam_mkhomedir`：
  - Login 已生效（可用于首次登录自动建家目录）。
  - Worker 当前缺失；若环境存在「首次会话可能直达计算节点」路径，建议在 Worker 镜像同步启用以避免边界场景失败。

---

## 十、补齐 HPC 工具的 Dockerfile 与使用方法

仓库已提供示例文件：`docs/examples/Dockerfile.hpc-tools`，用于在现有 Slurm 镜像上补齐常见工具，并分别产出：

- `login-hpc`（基于 `login`）
- `worker-hpc`（基于 `slurmd`）

该示例会安装：

- 容器运行时：优先 `apptainer`；若仓库无该包名则回退 `singularity-container`，并自动提供 `apptainer` / `singularity` 兼容命令
- 模块系统：`lmod`（提供 `module` / `ml` / `modulecmd`）
- 编译链：`build-essential`、`gfortran`、`cmake`
- 常用工具：`python3-pip`、`jq`、`rsync`
- PAM：`libpam-modules` 并追加 `pam_mkhomedir` 到 `/etc/pam.d/common-session`（不存在时才追加）

### 10.1 构建并推送到 Harbor

按你实际 Harbor 与版本替换变量：

```bash
export HARBOR_REGISTRY="harbor.aix.com:8443"
export HARBOR_PROJECT="slinkyproject"
export BASE_TAG="25.11-ubuntu24.04"
export NEW_TAG="25.11-ubuntu24.04-hpc-tools-v3"
export https_proxy="http://127.0.0.1:7890"
export http_proxy="http://127.0.0.1:7890"
export all_proxy="socks5://127.0.0.1:7890"
# 推送 Harbor 建议直连，勿走本机代理（按你的域名改）：
export NO_PROXY="127.0.0.1,localhost,harbor.aix.com,.aix.com,.svc,.cluster.local"
export no_proxy="${NO_PROXY}"
# 若代理访问 archive.ubuntu.com 频繁 502，可改用国内镜像（与 Dockerfile 中 APT_MIRROR_HOST 一致）：
export APT_MIRROR_HOST="mirrors.aliyun.com"

docker buildx build \
  -f docs/examples/Dockerfile.hpc-tools \
  --target login-hpc \
  --network=host \
  --build-arg APT_MIRROR_HOST="${APT_MIRROR_HOST}" \
  --build-arg HTTP_PROXY="${http_proxy}" \
  --build-arg HTTPS_PROXY="${https_proxy}" \
  --build-arg ALL_PROXY="${all_proxy}" \
  --build-arg NO_PROXY="${NO_PROXY}" \
  --build-arg http_proxy="${http_proxy}" \
  --build-arg https_proxy="${https_proxy}" \
  --build-arg all_proxy="${all_proxy}" \
  --build-arg no_proxy="${no_proxy}" \
  --build-arg BASE_LOGIN_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/login:${BASE_TAG}" \
  -t "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/login:${NEW_TAG}" \
  --push .

docker buildx build \
  -f docs/examples/Dockerfile.hpc-tools \
  --target worker-hpc \
  --network=host \
  --build-arg APT_MIRROR_HOST="${APT_MIRROR_HOST}" \
  --build-arg HTTP_PROXY="${http_proxy}" \
  --build-arg HTTPS_PROXY="${https_proxy}" \
  --build-arg ALL_PROXY="${all_proxy}" \
  --build-arg NO_PROXY="${NO_PROXY}" \
  --build-arg http_proxy="${http_proxy}" \
  --build-arg https_proxy="${https_proxy}" \
  --build-arg all_proxy="${all_proxy}" \
  --build-arg no_proxy="${no_proxy}" \
  --build-arg BASE_WORKER_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/slurmd:${BASE_TAG}" \
  -t "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/slurmd:${NEW_TAG}" \
  --push .
```

说明：

- `--network=host` 可减少构建阶段 DNS/代理转发问题（需宿主机允许）。
- `--build-arg HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/NO_PROXY` 将代理显式传入 build 阶段，避免 `apt-get` 在 BuildKit 中不走代理；小写 `http_proxy` 等同传入，容器内 `apt` 更稳定。
- `APT_MIRROR_HOST` 将 `archive.ubuntu.com` / `security.ubuntu.com` 替换为镜像站，**可显著降低**「HTTP 代理 → 官方 Ubuntu 源」导致的 `502 Bad Gateway`；不需要时可设为空字符串。
- `NO_PROXY` 含 Harbor 域名时，`docker push` 可走内网直连，避免大层经本机代理失败。
- 若构建日志出现 `E: Unable to locate package apptainer`（Ubuntu 24.04 常见），当前示例会自动回退安装 `singularity-container` 并创建 `apptainer` 兼容命令，无需手工改 Dockerfile。
- 若仍遇 `502`，可保留 `APT_MIRROR_HOST` 后重试；Dockerfile 内仍有 apt 重试与 `--fix-missing`。

> 已在环境中用上述参数完成一次构建并推送：`${HARBOR_REGISTRY}/${HARBOR_PROJECT}/login:25.11-ubuntu24.04-hpc-tools-v3` 与 `.../slurmd:25.11-ubuntu24.04-hpc-tools-v3`（以你本机 `docker login` 与网络为准）。

### 10.2 在 `values.yaml` 使用新镜像

更新 `helm/slurm/values.yaml`（示例）：

```yaml
loginsets:
  slinky:
    login:
      image:
        repository: harbor.example.com:8443/slinkyproject/login
        tag: 25.11-ubuntu24.04-hpc-tools-v3

nodesets:
  slinky:
    slurmd:
      image:
        repository: harbor.example.com:8443/slinkyproject/slurmd
        tag: 25.11-ubuntu24.04-hpc-tools-v3
```

执行升级：

```bash
helm upgrade --install slurm ./helm/slurm \
  --namespace slurm \
  -f helm/slurm/values.yaml
```

### 10.3 升级后快速验证

```bash
kubectl exec -n slurm deploy/slurm-login-slinky -- sh -lc 'command -v apptainer module gcc gfortran cmake pip3 jq rsync'
kubectl exec -n slurm slurm-worker-slinky-0 -c slurmd -- sh -lc 'command -v apptainer module gcc gfortran cmake pip3 jq rsync'
kubectl exec -n slurm deploy/slurm-login-slinky -- grep pam_mkhomedir /etc/pam.d/common-session
kubectl exec -n slurm slurm-worker-slinky-0 -c slurmd -- grep pam_mkhomedir /etc/pam.d/common-session
kubectl exec -n slurm deploy/slurm-login-slinky -- sh -lc 'apptainer --version || singularity --version'
```

若验证缺少 `module` 命令，可先在 shell 中加载初始化脚本再试：

```bash
source /etc/profile.d/lmod.sh 2>/dev/null || true
source /etc/profile.d/modules.sh 2>/dev/null || true
module --version || true
```

---

## 参考

- 官方安装：`docs/installation.md`
- 项目 README：`README.md`

