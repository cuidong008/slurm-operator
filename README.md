# Kubernetes Operator for Slurm Clusters

Run [Slurm] on [Kubernetes], by [SchedMD]. A [Slinky] project.


---

## Custom image builds (aixx)

以下命令均在 **aixx 仓库根目录** 执行（构建上下文为 `.`）。需要代理时先导出 `http_proxy`、`https_proxy`、`all_proxy`；`--network=host` 常用于缓解构建阶段 DNS/代理异常。

> **Shell 续行：** 行末的反斜杠 `\` 必须是该行 **最后一个字符**，`\` 后面不能有空格再回车。否则 zsh 会把下一行当成新命令，可能出现 `unable to prepare context: path " " not found` 与 `command not found: -f`。

### `Dockerfile.hpc-tools` — MPICH 与常用 HPC 包

| `--target`   | 用途            | 基础镜像角色 |
| ------------ | --------------- | ------------ |
| `login-hpc`  | 登录节点        | `login`      |
| `worker-hpc` | 计算节点 slurmd | `slurmd`     |

```bash
# 登录节点：默认 MPI 为 MPICH（update-alternatives）
docker build --network=host \
  -f install/slurm-operator/docs/examples/Dockerfile.hpc-tools \
  --target login-hpc \
  -t harbor.aix.com:8443/slinkyproject/login:25.11-ubuntu24.04-mpich-3 \
  --build-arg http_proxy="$http_proxy" \
  --build-arg https_proxy="$https_proxy" \
  --build-arg all_proxy="$all_proxy" \
  --build-arg HTTP_PROXY="$http_proxy" \
  --build-arg HTTPS_PROXY="$https_proxy" \
  --build-arg ALL_PROXY="$all_proxy" \
  .

# 计算节点
docker build --network=host \
  -f install/slurm-operator/docs/examples/Dockerfile.hpc-tools \
  --target worker-hpc \
  -t harbor.aix.com:8443/slinkyproject/slurmd:25.11-ubuntu24.04-mpich-3 \
  --build-arg http_proxy="$http_proxy" \
  --build-arg https_proxy="$https_proxy" \
  --build-arg all_proxy="$all_proxy" \
  --build-arg HTTP_PROXY="$http_proxy" \
  --build-arg HTTPS_PROXY="$https_proxy" \
  --build-arg ALL_PROXY="$all_proxy" \
  .
```

### `Dockerfile.openmpi-slurm` — 源码 Open MPI 5.x（外部 PMIx，无 MPICH）

默认 **Open MPI 5.0.x**（`OPENMPI_VERSION` / `OPENMPI_SERIES` 可改）。v4.1 在 Slurm `srun` 下仍常走内置 **pmix3x** 并报 `pmix3x_client.c`（见 [open-mpi/ompi#10307](https://github.com/open-mpi/ompi/issues/10307)）；v5 已去掉 `--with-pmi`，用 **`--with-pmix=external`**（`libpmix-dev` / 运行时 `libpmix2`）与 Slurm 的 PMIx 对接。**升级 major 后请重新用 `mpicc` 编译应用**（`libmpi.so` 主版本号会变）。

安装目录为 `/opt/openmpi`，通过 `/usr/local/bin` 下符号链接优先于系统 `mpicc`/`mpirun`。计算节点镜像已含 Slinky 的 `slurm-smd-libpmi2-0`；最终镜像**不再** apt 安装 Ubuntu 的 `libpmi2-0`（与 Slinky 冲突且 OMPI5 不依赖）。**登录镜像**安装 `build-essential`/`gfortran`；**worker** 不装编译器。若 apt 报 `502`，Dockerfile 已对官方源配置 **DIRECT**；仍失败可设 `NO_PROXY` 或 `--build-arg APT_MIRROR_HOST=…`。

```bash
# 计算节点（slurmd）
docker build --network=host \
  -f install/slurm-operator/docs/examples/Dockerfile.openmpi-slurm \
  --target worker-openmpi-slurm \
  -t harbor.aix.com:8443/slinkyproject/slurmd:25.11-ubuntu24.04-openmpi-5 \
  --build-arg http_proxy="$http_proxy" \
  --build-arg https_proxy="$https_proxy" \
  --build-arg all_proxy="$all_proxy" \
  --build-arg HTTP_PROXY="$http_proxy" \
  --build-arg HTTPS_PROXY="$https_proxy" \
  --build-arg ALL_PROXY="$all_proxy" \
  .

# 登录节点（login；`-t` 需与集群 LoginSet 使用的镜像一致）
docker build --network=host \
  -f install/slurm-operator/docs/examples/Dockerfile.openmpi-slurm \
  --target login-openmpi-slurm \
  -t harbor.aix.com:8443/slinkyproject/login:25.11-ubuntu24.04-openmpi-4 \
  --build-arg http_proxy="$http_proxy" \
  --build-arg https_proxy="$https_proxy" \
  --build-arg all_proxy="$all_proxy" \
  --build-arg HTTP_PROXY="$http_proxy" \
  --build-arg HTTPS_PROXY="$https_proxy" \
  --build-arg ALL_PROXY="$all_proxy" \
  .
```

**多节点 `srun ./prog` 报 “not built with SLURM's PMI support” / `pmix3x_client.c` 时：**  
1）**计算节点**必须使用 **`worker-openmpi-slurm`**；`ldd ./prog` 中 `libmpi` 须来自 **`/opt/openmpi/lib`**。  
2）若已用 **Open MPI 4.1 + 外部 PMIx** 仍出现 **`pmix3x_client`**：属 v4 已知问题（内部 PMIx 与外部混用）。请改用本仓库默认的 **Open MPI 5.x** 镜像并全量滚动节点。  
3）作业中可优先用 **`mpirun ./prog`**（在 Slurm 已分配资源的前提下），一般不必再写 `-np`。  
4）若必须用 `srun`，按站点 **`srun --mpi=list`** 尝试 **`--mpi=pmix`** / **`pmix_v3`** 等。

### SCOW Slurm Adapter（`Dockerfile.login`）

构建上下文目录须包含 `scow-slurm-adapter-amd64` 及 Dockerfile 中 `COPY` 所引用的文件（见该目录下 Dockerfile 注释）。从仓库根目录执行：

```bash
docker build \
  -f install/slurm-operator/deploy/scow-slurm-adapter/Dockerfile.login \
  -t harbor.aix.com:8443/library/scow-slurm-adapter-login:1.6.2 \
  install/slurm-operator/deploy/scow-slurm-adapter
```

---


## Table of Contents

<!-- mdformat-toc start --slug=github --no-anchors --maxlevel=6 --minlevel=1 -->

- [Kubernetes Operator for Slurm Clusters](#kubernetes-operator-for-slurm-clusters)
  - [Custom image builds (aixx)](#custom-image-builds-aixx)
    - [`Dockerfile.hpc-tools` — MPICH 与常用 HPC 包](#dockerfilehpc-tools--mpich-与常用-hpc-包)
    - [`Dockerfile.openmpi-slurm` — 源码 Open MPI 5.x（外部 PMIx，无 MPICH）](#dockerfileopenmpi-slurm--源码-open-mpi-5x外部-pmix无-mpich)
    - [SCOW Slurm Adapter（`Dockerfile.login`）](#scow-slurm-adapterdockerfilelogin)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
    - [Slurm Cluster](#slurm-cluster)
  - [Features](#features)
    - [Controller](#controller)
    - [NodeSets](#nodesets)
      - [`StatefulSet` (default)](#statefulset-default)
      - [`DaemonSet`](#daemonset)
    - [LoginSets](#loginsets)
    - [Hybrid Support](#hybrid-support)
    - [Slurm](#slurm)
  - [Compatibility](#compatibility)
  - [Quick Start](#quick-start)
  - [Upgrades](#upgrades)
    - [1.Y Releases](#1y-releases)
    - [0.Y Releases](#0y-releases)
  - [Documentation](#documentation)
  - [Support and Development](#support-and-development)
  - [License](#license)

<!-- mdformat-toc end -->

## Overview

[Slurm] and [Kubernetes] are workload managers originally designed for different
kinds of workloads. In broad strokes: Kubernetes excels at scheduling workloads
that typically run for an indefinite amount of time, with potentially vague
resource requirements, on a single node, with loose policy, but can scale its
resource pool infinitely to meet demand; Slurm excels at quickly scheduling
workloads that run for a finite amount of time, with well defined resource
requirements and topology, on multiple nodes, with strict policy, but its
resource pool is known.

This project enables the best of both workload managers, unified on Kubernetes.
It contains a [Kubernetes] operator to deploy and manage certain components of
[Slurm] clusters. This repository implements [custom-controllers] and
[custom resource definitions (CRDs)][crds] designed for the lifecycle (creation,
upgrade, graceful shutdown) of Slurm clusters.

!["Slurm Operator Architecture"](./docs/_static/images/architecture-operator.svg)

For additional architectural notes, see the [architecture] docs.

### Slurm Cluster

Slurm clusters are very flexible and can be configured in various ways. Our
Slurm helm chart provides a reference implementation that is highly customizable
and tries to expose everything Slurm has to offer.

!["Slurm Architecture"](./docs/_static/images/architecture-slurm.svg)

For additional information about Slurm, see the [slurm][slurm-docs] docs.

## Features

### Controller

The Slurm control-plane is responsible for scheduling Slurm workload onto its
worker nodes and managing their states.

Slurm [High Availability (HA)][slurm-ha] is effectively achieved though
Kubernetes regenerating the Slurm controller pod if it crashes. This is
generally faster than the time it takes for a backup controller to assume
control if the primary crashes. Because Slurm's version of HA is not being used,
a shared filesystem is not required for this.

Changes to the Slurm configuration files are automatically detected and the
Slurm cluster is reconfigured seamlessly with zero downtime of the Slurm
control-plane.

> [!NOTE]
> The kubelet's `configMapAndSecretChangeDetectionStrategy` and `syncFrequency`
> settings directly affect when pods have their mounted ConfigMaps and Secrets
> updated. By default, the kubelet is in `Watch` mode with a polling frequency
> of 60 seconds.

### NodeSets

A set of homogeneous Slurm workers (compute nodes), which are delegated to
execute the Slurm workload.

The operator will take into consideration the running workload among Slurm nodes
as it needs to scale-in, upgrade, or otherwise handle node failures. Slurm nodes
will be marked as [drain][slurm-drain] before their eventual termination pending
scale-in or upgrade.

Slurm node states (e.g. Idle, Allocated, Mixed, Down, Drain, Not Responding,
etc...) are applied to each NodeSet pod via their pod conditions; each NodeSet
pod contains a pod status that reflects their own Slurm node state.

The NodeSet CRD supports a `scalingMode` field that controls how many pods are
created and how they are scaled. This allows you to choose between replica-based
scaling (like a StatefulSet) or one-pod-per-node scaling (like a DaemonSet).

#### `StatefulSet` (default)

- **Behavior**: The controller maintains a fixed number of pods according to the
  `replicas` field.
- **Use when**: A fixed or scalable number of Slurm worker pods is needed.
  Scale-to-zero and horizontal autoscaling (e.g. HPA) apply to this mode.
- **Note**: Each pod has a stable identity (e.g. ordinal-based naming)

#### `DaemonSet`

- **Behavior**: The controller schedules one pod per Kubernetes node that
  matches the NodeSet's pod template (e.g. `nodeSelector`, `tolerations`). Pod
  count follows the number of matching nodes. Adding or removing nodes
  automatically adds or removes pods.
- **Use when**: 1:1 alignment between Kubernetes and Slurm (slurmd) nodes is
  needed.
- **Note**: The `replicas` field is ignored. Pod identity is tied to the node
  (e.g. node name) rather than an ordinal.

The operator supports NodeSet scale to zero, scaling the resource down to zero
replicas. Hence, any Horizontal Pod Autoscaler (HPA) that also support scale to
zero can be best paired with NodeSets.

NodeSets can be resolved by hostname. This enables hostname-based resolution
between login pods and worker pods, enabling direct pod-to-pod communication
using predictable hostnames (e.g., `cpu-1-0`, `gpu-2-1`).

### LoginSets

A set of homogeneous login nodes (submit node, jump host) for Slurm, which
manage user identity via SSSD.

The operator supports LoginSet scale to zero, scaling the resource down to zero
replicas. Hence, any Horizontal Pod Autoscaler (HPA) that also support scale to
zero can be best paired with LoginSets.

### Hybrid Support

Sometimes a Slurm cluster has some, but not all, of its components in
Kubernetes. The operator and its CRDs are designed support these use cases.

### Slurm

Slurm is a full featured HPC workload manager. To highlight a few features:

- [**Accounting**][slurm-accounting]: collect accounting information for every
  job and job step executed.
- [**Partitions**][slurm-arch]: job queues with sets of resources and
  constraints (e.g. job size limit, job time limit, users permitted).
- [**Reservations**][slurm-reservations]: reserve resources for jobs being
  executed by select users and/or select accounts.
- [**Job Dependencies**][slurm-dependency]: defer the start of jobs until the
  specified dependencies have been satisfied.
- [**Job Containers**][slurm-containers]: jobs which run an unprivileged OCI
  container bundle.
- [**MPI**][slurm-mpi]: launch parallel MPI jobs, supports various MPI
  implementations.
- [**Priority**][slurm-priority]: assigns priorities to jobs upon submission and
  on an ongoing basis (e.g. as they age).
- [**Preemption**][slurm-preempt]: stop one or more low-priority jobs to let a
  high-priority job run.
- [**QoS**][slurm-qos]: sets of policies affecting scheduling priority,
  preemption, and resource limits.
- [**Fairshare**][slurm-fairshare]: distribute resources equitably among users
  and accounts based on historical usage.
- [**Node Health Check**][slurm-healthcheck]: periodically check node health via
  script.

## Compatibility

| Software   |                             Minimum Version                              |
| :--------- | :----------------------------------------------------------------------: |
| Kubernetes | [v1.29](https://kubernetes.io/blog/2023/12/13/kubernetes-v1-29-release/) |
| Slurm      | [25.11](https://www.schedmd.com/slurm-version-25-11-0-is-now-available/) |
| Cgroup     |         [v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)         |

## Quick Start

Install the [cert-manager] with its CRDs:

```sh
helm install \
  cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

Install the slurm-operator and its CRDs:

```sh
helm install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --namespace=slinky --create-namespace
```

Install a Slurm cluster:

```sh
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace=slurm --create-namespace
```

For additional instructions, see the [installation] guide.

## Upgrades

Slinky versions are expressed as **X.Y.Z**, where **X** is the major version,
**Y** is the minor version, and **Z** is the patch version, following
[Semantic Versioning][semver] terminology.

See [versioning] for more details.

### 1.Y Releases

New Slinky versions may update the Slinky [CRDs] with new fields and deprecate
old ones. During CRD version changes (e.g. `v1beta1` => `v1beta2`), deprecated
fields may be removed. Through the Kubernetes API, CRD versions are
automatically converted to the stored version. Therefore old CRD versions will
still work, but it is recommended to use the new CRD version as indicated by the
installed Slinky CRDs.

To upgrade between Slinky `v1.Y` versions (e.g. `v1.0.Z` => `v1.1.Z`), upgrade
the slurm-operator-crds chart followed by the slurm-operator chart, or both at
the same time by upgrading the slurm-operator chart when using
`crds.enabled=true`.

```bash
helm upgrade slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
  --version $SLINKY_VERSION
helm upgrade slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --namespace slinky --version $SLINKY_VERSION
```

All Slurm charts may remain on the old Slinky release series (e.g. `v1.0.x`)
despite the slurm-operator and its CRDs being on a newer Slinky release series
(e.g. `v1.1.x`). It is still recommended to upgrade Slurm charts to the new
Slinky release series coinciding with the slurm-operator's Slinky release series
to make use of the new fields, features, and functionality.

Please review changes made to the CRDs and the Slurm chart. Update your
`values.yaml` appropriately and upgrade the Slurm chart.

```sh
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace slurm --version $SLINKY_VERSION
```

### 0.Y Releases

Breaking changes may be introduced into existing Slinky [CRDs] versions. To
upgrade between `v0.Y` versions (e.g. `v0.1.Z` => `v0.2.Z`), uninstall all
Slinky charts and delete Slinky CRDs, then install the new release like normal.

```bash
helm --namespace=slurm uninstall slurm
helm --namespace=slinky uninstall slurm-operator
helm uninstall slurm-operator-crds
```

If the CRDs were not installed via `slurm-operator-crds` helm chart:

```bash
kubectl delete customresourcedefinitions.apiextensions.k8s.io accountings.slinky.slurm.net
kubectl delete customresourcedefinitions.apiextensions.k8s.io clusters.slinky.slurm.net # defunct
kubectl delete customresourcedefinitions.apiextensions.k8s.io loginsets.slinky.slurm.net
kubectl delete customresourcedefinitions.apiextensions.k8s.io nodesets.slinky.slurm.net
kubectl delete customresourcedefinitions.apiextensions.k8s.io restapis.slinky.slurm.net
kubectl delete customresourcedefinitions.apiextensions.k8s.io tokens.slinky.slurm.net
```

## Documentation

Project documentation is located in the docs directory of this repository.

- Harbor / air-gapped install notes (Chinese): [installation-harbor](./docs/installation-harbor.md)

[Slinky documentation][slinky-docs] is hosted on the web.

## Support and Development

Feature requests, code contributions, and bug reports are welcome!

Github/Gitlab submitted issues and PRs/MRs are handled on a best effort basis.

The SchedMD official issue tracker is at <https://support.schedmd.com/>.

To schedule a demo or simply to reach out, please
[contact SchedMD][contact-schedmd].

## License

Copyright (C) SchedMD LLC.

Licensed under the
[Apache License, Version 2.0](http://www.apache.org/licenses/LICENSE-2.0) you
may not use project except in compliance with the license.

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

<!-- links -->

[architecture]: ./docs/concepts/architecture.md
[cert-manager]: https://cert-manager.io/docs/installation/helm/
[contact-schedmd]: https://www.schedmd.com/slurm-resources/contact-schedmd/
[crds]: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/#customresourcedefinitions
[custom-controllers]: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/#custom-controllers
[installation]: ./docs/installation.md
[kubernetes]: https://kubernetes.io/
[schedmd]: https://schedmd.com/
[semver]: https://semver.org/
[slinky]: https://slinky.ai/
[slinky-docs]: https://slinky.schedmd.com/
[slurm]: https://slurm.schedmd.com/overview.html
[slurm-accounting]: https://slurm.schedmd.com/accounting.html
[slurm-arch]: https://slurm.schedmd.com/quickstart.html#arch
[slurm-containers]: https://slurm.schedmd.com/containers.html
[slurm-dependency]: https://slurm.schedmd.com/sbatch.html#OPT_dependency
[slurm-docs]: ./docs/concepts/slurm.md
[slurm-drain]: https://slurm.schedmd.com/scontrol.html#OPT_DRAIN
[slurm-fairshare]: https://slurm.schedmd.com/fair_tree.html
[slurm-ha]: https://slurm.schedmd.com/quickstart_admin.html#HA
[slurm-healthcheck]: https://slurm.schedmd.com/slurm.conf.html#OPT_HealthCheckProgram
[slurm-mpi]: https://slurm.schedmd.com/mpi_guide.html
[slurm-preempt]: https://slurm.schedmd.com/preempt.html
[slurm-priority]: https://slurm.schedmd.com/priority_multifactor.html
[slurm-qos]: https://slurm.schedmd.com/qos.html
[slurm-reservations]: https://slurm.schedmd.com/reservations.html
[versioning]: ./docs/versioning.md
