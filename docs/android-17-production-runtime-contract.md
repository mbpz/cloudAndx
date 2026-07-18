# Android 17 Cuttlefish 生产运行时契约

> 契约版本：1.0.0
> 基线日期：2026-07-17
> 适用范围：Android 17 AOSP Cuttlefish 生产数据面
> 上位设计：[Google 原生 Android 17 容器化运行方案](android-17-container-architecture.md)

## 1. 契约结论

生产运行时只有一条合法的控制与所有权链：

```text
K8s Controller
  -> node-local root-owned Host Agent
    -> OCI runtime
      -> Cuttlefish host processes + crosvm
        -> Android 17 Cuttlefish KVM VM
```

任何组件不得绕过链中的上一层直接操作下一层。尤其禁止：

- K8s Controller、租户服务或运维脚本直接访问 containerd、CRI-O、Docker API、KVM、TAP、会话目录或 `cvd`；
- 租户工作负载直接调用 Host Agent；
- OCI 容器创建宿主网络、挂载宿主目录、选择设备、改变 capability 或下载运行制品；
- 容器内 entrypoint 回退到 OCI 镜像预装的另一套 `cvd`、`crosvm` 或共享库；
- 使用未登记的镜像标签、浮动标签或仅固定多架构 OCI index 而未固定当前平台 manifest。

本契约只覆盖 AOSP Cuttlefish 数据面，不授予 GMS、Google Play、Play Protect 或物理 Pixel 能力。

## 2. 规范术语与版本边界

文中的“必须”“禁止”是发布阻断条件；“建议”是默认策略，偏离时必须有书面风险接受、到期时间和回退方案。

生产发布单元是不可拆分的 `RuntimeTuple`：

```text
RuntimeTuple =
  Android guest artifact digest
  + cvd-host_package archive digest
  + runtime provenance manifest digest
  + crosvm executable digest
  + OCI index digest（若镜像为多架构）
  + 当前 linux/<arch> OCI platform manifest digest
  + seccomp policy digest
  + Host Agent policy version
  + host kernel/KVM baseline
  + GPU driver baseline（仅 GPU profile）
```

任一成员变化都产生新的候选版本并重新通过适用门禁。生产不得依赖 `stable`、`latest` 等标签解析结果作为运行身份。

### 2.1 Cloud Orchestrator 的唯一允许位置

Google Cloud Orchestrator **不属于生产链路**，不得安装在生产节点、生产管理网或灾备生产节点上，也不得作为 Host Agent 的下游适配器。

它只允许出现在 Phase 1 的隔离单机参考 PoC，用于理解 Google 官方启动流程和收集基线参数。Phase 1 结束后，进入下一阶段前必须销毁该 PoC 节点或重装节点，并提供不存在 Cloud Orchestrator 进程、镜像、socket、网络规则和持久化数据的证据。

## 3. 组件职责与禁止的旁路

| 层级 | 唯一职责 | 持有的权威状态 | 明确禁止 |
|---|---|---|---|
| K8s Controller | 校验 CR、选择节点、维护期望状态、generation、租约和 finalizer | Kubernetes API 中的期望状态与调度决定 | 直接创建 OCI 容器、执行宿主命令、修改本地文件或设备 |
| Host Agent | 在单节点上校验策略并把期望状态收敛为本地现实 | 本地资源账本、操作日志、spec hash、回收状态 | 接受任意镜像、路径、挂载、环境变量、Cuttlefish flag 或 shell 命令 |
| OCI runtime | 按 Host Agent 生成的固定 bundle 创建容器、namespace 和 cgroup | OCI 容器及其进程生命周期 | 决定设备规格、拉取未固定镜像、管理 Android 期望状态 |
| Cuttlefish host processes | 从固定 host package 启动虚拟设备服务和 `crosvm` | 单会话 Cuttlefish 内部状态 | 创建宿主级资源、读取其他会话目录、动态替换二进制 |
| Android KVM VM | 运行 Android 17 guest 和应用 | guest 内部状态 | 取得宿主或其他 VM 的控制能力 |

Host Agent 是专用节点上的 root-owned system service，不运行在租户 Pod 中。它通过独立的 containerd namespace 或等价 OCI runtime 隔离域工作；kubelet 不得同时声明这些容器的所有权。

Controller 只能通过节点管理网的 mTLS Host Agent API 发出高层请求。API 不监听互联网、租户网络或 Android 会话网络，并由节点防火墙限制为控制面身份。

## 4. Host Agent API 契约

机器可读定义位于 [`contracts/host-agent-api.openapi.yaml`](../contracts/host-agent-api.openapi.yaml)，安全示例位于 [`contracts/android-device.example.yaml`](../contracts/android-device.example.yaml)。

API 仅提供四种操作：

| 操作 | 语义 | 幂等键 | 成功后的期望状态 |
|---|---|---|---|
| `create` | 创建一个不可变设备规格并收敛到运行态 | `Idempotency-Key` + `deviceId` + `generation` | `RUNNING` |
| `get` | 读取期望状态、观察状态和稳定 reason code | 无 | 不改变状态 |
| `delete` | 撤销租约并收敛到完全清理 | `Idempotency-Key` + expected generation | `DELETED` |
| `reconcile` | 对已登记设备重新执行现实检查和收敛 | `Idempotency-Key` + expected generation | 保持原期望状态 |

API 请求不得携带以下字段：

- OCI command、entrypoint、环境变量或任意参数；
- host path、mount、device path、UID/GID 或 capability；
- Cuttlefish flag、内核参数、网络命令、端口号或 TAP 名称；
- registry credential、私钥、ADB credential、Google 账号或其他秘密；
- shell 片段、模板表达式或策略覆盖。

这些低层值只能由 Host Agent 的签名策略根据固定高层字段派生。

### 4.1 幂等规则

1. Host Agent 在执行副作用前，以 `(deviceId, generation, operation, idempotencyKey)` 建立原子操作记录，并保存规范化请求的 SHA-256。
2. 相同键与相同请求哈希返回同一个资源或操作结果，不重复分配 CID、IP、TAP、磁盘或容器。
3. 相同键但请求哈希不同返回 `409 IDEMPOTENCY_CONFLICT`。
4. 已存在的 `deviceId/generation` 与不同 spec hash 返回 `409 IMMUTABLE_SPEC_CONFLICT`；运行规格不做原地修改。
5. `delete` 对不存在、正在删除或已经删除的资源都成功收敛；重复请求返回现有 tombstone。
6. `reconcile` 只能修复当前登记规格，不能借机升级制品、放宽策略或改变 placement。
7. Host Agent 崩溃后从 durable journal 重放未提交操作。每一步先记录 intent，再执行副作用，最后记录实际资源标识和 commit。

## 5. Host Agent 状态机

Controller 只设置 `desiredState=RUNNING|DELETED`。Host Agent 维护以下观察状态：

| 状态 | 含义 | 允许的下一状态 |
|---|---|---|
| `ABSENT` | 本地没有账本或资源 | `ALLOCATING`、`DELETED` |
| `ALLOCATING` | 保留 CID、IP、TAP 名、目录和资源额度 | `PREPARING`、`RECOVERING`、`DELETING` |
| `PREPARING` | 校验制品并构建只读 OCI bundle 与会话盘 | `STARTING`、`RECOVERING`、`DELETING` |
| `STARTING` | OCI 容器和 Cuttlefish VM 正在启动 | `READY`、`RECOVERING`、`DELETING` |
| `READY` | provenance、ADB、boot 和声明的健康检查均通过 | `DEGRADED`、`RECOVERING`、`DELETING` |
| `DEGRADED` | VM 仍存在但一个可恢复健康检查失败 | `READY`、`RECOVERING`、`DELETING` |
| `RECOVERING` | 正在终止漂移资源并按同一规格重建 | `PREPARING`、`STARTING`、`READY`、`FAILED`、`DELETING` |
| `FAILED` | 达到有限重试阈值，等待显式 reconcile 或 delete | `RECOVERING`、`DELETING` |
| `DELETING` | 正按逆序回收所有本地资源 | `DELETED`、`RECOVERING` |
| `DELETED` | 清理证明完成，保留有限期 tombstone | 无；重建必须使用新 `deviceId` |
| `QUARANTINED` | 检测到来源、所有权或隔离异常 | `DELETING`；人工取证后才能清理 |

### 5.1 READY 的必要条件

Host Agent 只有同时满足下列条件才能报告 `READY`：

- 当前 spec hash、generation 和 Controller 租约一致；
- OCI 实际运行的 platform manifest digest 与请求及准入清单一致；
- `/proc/<pid>/exe`、进程树、加载库和命令行通过 provenance 校验；
- `crosvm` 实际存在且沙箱开启，未出现 VMM 回退；
- 容器安全策略、设备映射、cgroup 和网络 namespace 与期望一致；
- ADB online、`sys.boot_completed=1`，并通过该 profile 声明的附加检查；
- 未发现未登记的进程、mount、TAP、vsock CID、端口或可写基线制品。

## 6. 资源所有权与恢复

### 6.1 唯一所有者

| 资源 | 创建和删除者 | 持久标识 |
|---|---|---|
| device placement、generation、租约 | K8s Controller | CR UID + generation |
| 本地操作 journal、tombstone | Host Agent | device ID + spec hash |
| vsock CID、IP、TAP、netns | Host Agent | Host Agent 资源账本 |
| OCI bundle、container、cgroup、namespace | Host Agent 经 OCI runtime | OCI label + device ID + generation |
| overlay、userdata、session log | Host Agent | `owner.json` + device ID |
| `cvd`、`crosvm` 与子进程 | OCI runtime 内的固定 entrypoint | PID、exe digest、cgroup |
| Android guest 数据 | 单个 Cuttlefish VM | 独立 userdata/overlay |

每个本地资源都必须带有 `deviceId`、CR UID、generation、spec hash 和 Host Agent instance ID。缺少标签或标签互相矛盾的资源不得自动接管，必须进入 `QUARANTINED`。

### 6.2 节点重启恢复顺序

1. Host Agent 取得全局单实例锁并拒绝新建请求。
2. 读取 durable journal、tombstone 和资源账本。
3. 枚举专用 OCI namespace、cgroup、session 目录、netns、TAP、vsock CID 和 device allocation。
4. 以所有权元数据做三方比对：Controller 期望、本地账本、现实资源。
5. 对 `RUNNING` 且租约有效的资源执行 provenance 和隔离复验；一致则重新纳管，不一致则终止并按相同 tuple 重建。
6. 对 `DELETED` 或租约已撤销的资源按逆序清理。
7. 对 Controller 无记录的资源先隔离网络并标记 orphan；超过配置的取证宽限期且再次确认无租约后清理。
8. 完成全节点残留检查后才恢复 create 请求。

Controller 暂时不可用时，Host Agent不得创建新设备或改变版本。已运行设备只能在本地租约宽限期内保持运行；宽限期到期后进入受控删除，不能无限期“孤儿运行”。

### 6.3 删除的固定逆序

1. 撤销 ADB、WebRTC、工作负载身份和网络入口；
2. 停止 Cuttlefish VM，等待有限超时后强制终止 OCI cgroup；
3. 删除 OCI 容器、bundle 和临时 namespace；
4. 删除 TAP、netns、IP/CID allocation 和设备授权；
5. 销毁会话数据密钥并删除 overlay、userdata 和 session tmp；
6. 检查进程、mount、端口、cgroup、网络设备和文件残留；
7. 写入不可变清理证据和本地 tombstone；
8. Controller 看到 `DELETED` 证据后才移除 finalizer。

## 7. 调度矩阵

Controller 必须从以下固定 runtime class 中选择；Host Agent 根据节点标签和本地事实再次校验，二者不一致时 fail closed。

| Runtime class | 宿主/guest | 信任与密度 | 镜像变体 | GPU | 快照 | 硬隔离要求 |
|---|---|---|---|---|---|---|
| `x86-untrusted` | x86_64 / x86_64 | 一 VM、一 OCI 容器、一 netns、一卷；默认一租户一节点 | 仅 release-key `user` | 默认 SwiftShader；硬件 GPU 仅通过 GPU 独占门禁 | 禁止 | 专用 untrusted taint；不与 CI、ARM 或普通业务 Pod 混跑 |
| `x86-trusted-ci` | x86_64 / x86_64 | v1 仍为一 VM、一 OCI 容器、一节点 | `userdebug` 或 `user` | SwiftShader；硬件 GPU 仅通过 GPU 独占门禁 | 仅经验证的 x86 + SwiftShader profile | 专用 CI taint；不得与不可信租户共节点 |
| `arm64` | arm64 / arm64 | 每 VM 独立 OCI 容器；多容器/节点只有通过并发 PoC 后开放；untrusted 与 trusted CI 使用不同节点池 | 按 trust class 选择 `user`/`userdebug` | 默认软件渲染；硬件 GPU 必须单独过门禁 | 禁止 | 禁止跨架构模拟替代；ARM kernel/KVM/host package 单独晋级 |

本契约 v1 禁止在一个 Cuttlefish host container 中使用 `--num_instances` 承载多个设备。受官方 x86_64 多 Docker 实例 `vhost_user_vsock` 限制影响，x86 v1 不通过节点内多容器提高密度；ARM64 也要在并发 PoC 通过后才开放节点内多个独立容器。未来若启用 Cuttlefish multi-tenancy，必须发布新的契约版本和成组生命周期 API。

必需节点标签至少包括：

```text
android.runtime/host-arch = x86_64 | arm64
android.runtime/kvm = ready
android.runtime/trust-zone = untrusted | trusted-ci
android.runtime/gpu-mode = none | dedicated | trusted-shared
android.runtime/runtime-tuple = <approved tuple id>
android.runtime/agent-policy = <policy version>
```

节点必须使用 taint 阻止普通 Pod 调度。Controller 的调度结果不是授权；Host Agent 必须用本机架构、KVM API、IOMMU、GPU、内核和策略版本重新验证。

## 8. 固定文件系统布局

API 不能指定路径。Host Agent 只使用以下布局，并对 `deviceId` 采用受限字符集后直接拼接固定路径，不接受路径分隔符、`.`、`..`、符号链接或模板展开。

```text
/etc/android-host-agent/
  policy.bundle                 root:root 0444，签名准入策略
  trust/                        root:root 0555，制品签名验证材料

/opt/android-runtime/artifacts/<artifact-set-id>/
  manifest.json                 root:root 0444，RuntimeTuple 和逐文件摘要
  host/                         root:root 0555，同 guest build 的 host package
  guest/                        root:root 0555，guest images 与 config

/var/lib/android-host-agent/
  journal/                      root:root 0700，幂等操作 WAL
  state/                        root:root 0700，设备账本和 tombstone
  allocations/                  root:root 0700，CID/IP/TAP/device allocation
  sessions/<device-id>/
    owner.json                  root:root 0400，CR UID/generation/spec hash
    oci-bundle/                 root:root 0700，Host Agent 生成
    overlay/                    runtime UID 0700，可写
    userdata/                   runtime UID 0700，可写、加密
    logs/                       runtime UID 0700，可写、限额
    tmp/                        runtime UID 0700，临时、限额

/run/android-host-agent/
  agent.sock                    root:root 0600，本地管理 socket
  locks/                        root:root 0700，易失锁
```

容器内固定映射：

| 容器路径 | 来源 | 模式 |
|---|---|---|
| `/opt/cuttlefish/host` | 对应 artifact set 的 `host/` | 只读、可执行 |
| `/opt/cuttlefish/guest` | 对应 artifact set 的 `guest/` | 只读、宿主不可执行 |
| `/var/lib/cuttlefish/session` | 单设备 session 目录的可写子目录 | 读写、配额限制 |
| `/run/cuttlefish` | 独立 tmpfs | 读写、`nosuid,nodev`、限额 |
| `/tmp` | 独立 tmpfs | 读写、`nosuid,nodev,noexec`、限额 |

OCI root filesystem 必须只读。禁止把 `/`、`/etc`、`/usr`、`/var/run`、containerd socket、Docker socket、其他 session 目录或任意 host path 映射进容器。

## 9. OCI 与 crosvm 沙箱契约

### 9.1 OCI 容器

Host Agent 以 root 调用 OCI runtime，但容器 payload 使用固定的非 root runtime UID/GID。生产 bundle 必须满足：

- `noNewPrivileges=true`；
- rootfs read-only；
- Linux capabilities 默认全部 drop，长期运行容器不得拥有 capability；
- Host Agent 在启动容器前创建 netns、TAP、CID 和所有挂载；不得给长期运行容器 `CAP_NET_ADMIN`、`CAP_SYS_ADMIN`、`CAP_SYS_PTRACE`、`CAP_BPF` 或 `CAP_SYS_MODULE`；
- 使用与 RuntimeTuple 绑定的 default-deny seccomp profile；禁止 `mount`、`pivot_root`、`ptrace`、`bpf`、`kexec_load`、模块加载、keyring 操作和未经批准的 namespace 创建；
- 使用强制 AppArmor/SELinux profile；策略缺失或处于 complain/permissive 状态时不得启动 untrusted profile；
- 使用 cgroup v2 固定 CPU、memory、pids、IO 和 device 访问；禁止无限制资源；
- 仅映射本 profile 的 `/dev/kvm`、必要 vhost/vsock 设备，以及获准 GPU profile 的单个 render device；
- 禁止 `privileged`、host PID、host IPC、host user namespace 和 host network；mount propagation 必须为 private；
- entrypoint 必须是绝对路径的已哈希二进制，不经 shell、包管理器或网络下载器启动。

如果某个候选 Cuttlefish build 不能在上述权限下启动，它不能通过生产门禁。解决方式是收敛 Host Agent 的预创建动作或更新经过评审的精确 seccomp allowlist，不得改为 privileged 容器。

### 9.2 crosvm

- 固定 `--vm_manager=crosvm`，禁止 QEMU 或其他 VMM 回退；
- crosvm 自身沙箱/minijail 必须启用，生产命令行不得出现禁用沙箱的 flag；
- 每个 VM 使用唯一、账本化的 vsock CID、网络 namespace、TAP 和 cgroup；
- crosvm 及其设备进程使用独立 uid/gid 和最小文件访问；
- guest kernel、initramfs、boot、vendor、system 和 userdata 路径只能从本设备的只读 artifact set 或可写 session 目录解析；
- crosvm 异常退出、seccomp violation、GPU reset 或 provenance 漂移都触发隔离和有限次数重建；重复发生后进入 `FAILED` 或 `QUARANTINED`，不得无限重启。

## 10. 平台 manifest 与进程来源校验

### 10.1 OCI 平台摘要

准入清单必须同时记录 registry repository、可选 OCI index digest、当前平台 manifest digest 和平台三元组：

```text
linux/amd64       -> sha256:<platform-specific-manifest>
linux/arm64/v8    -> sha256:<platform-specific-manifest>
```

Host Agent 解析 index 后必须验证它把目标 platform 映射到请求中的 platform manifest digest，并以该 manifest digest 创建容器。只匹配 index digest、tag 或本地缓存名称都不够。节点架构与 manifest 架构不一致时返回稳定错误 `PLATFORM_MANIFEST_MISMATCH`。

### 10.2 启动前检查

Host Agent 在产生任何运行进程前必须：

1. 校验 artifact manifest 的签名、完整 RuntimeTuple 和准入状态；
2. 对 entrypoint、`cvd`、`crosvm` 及 profile 声明的每个可执行文件计算 SHA-256，并匹配 provenance manifest；
3. 用 `realpath` 验证所有可执行文件和库位于只读 `host/` 根下，不允许符号链接逃逸；
4. 验证 owner 为 root，制品目录和文件均不可被 group/world 写入；
5. 验证 ELF build ID、解释器、SONAME、RPATH/RUNPATH 和依赖库集合；
6. 生成最小环境：固定 `PATH` 和库搜索路径，清除 `LD_PRELOAD`、`LD_AUDIT`、语言运行时注入变量和用户 profile；
7. 验证 guest 所有镜像摘要、AVB 元数据和目标架构；
8. 验证 seccomp、LSM 和 OCI bundle digest 与 RuntimeTuple 一致。

### 10.3 启动后检查

在报告 `READY` 前，Host Agent 必须从 host `/proc` 视角检查：

- 进程树只包含该 profile provenance manifest 允许的 executable digest；
- `/proc/<pid>/exe` 解析到预期只读 host package；
- `/proc/<pid>/maps` 中的 ELF 共享库只来自已批准的 host package 或 OCI platform manifest 中明确批准的只读系统库；
- crosvm 命令行、sandbox 状态、PID namespace、cgroup、UID/GID 和打开的 device node 与策略一致；
- 不存在 shell、包管理器、下载器、调试器或未登记 side process。

定期 reconcile 重复上述检查。发现不匹配时先切断会话网络，再保存最小取证证据并进入 `QUARANTINED`；不得仅记录告警后继续服务。

## 11. GPU 隔离策略

GPU 不是默认能力，准入顺序如下：

1. `x86-untrusted` 和 `arm64-untrusted` 默认使用 SwiftShader，不映射 `/dev/dri`。
2. 不可信硬件 GPU 只允许独占一个可独立复位、位于独立 IOMMU group 的物理 GPU、SR-IOV VF 或已证明等效隔离的设备实例；一台物理 GPU 不同时服务两个不可信会话。
3. 可信 CI 可以在独立 CI 节点共享指定 render node，但所有会话必须属于同一书面批准的信任域，并接受 GPU DoS 和驱动共享风险；不得与不可信会话或普通业务 Pod 混跑。
4. 容器只映射分配到的 `/dev/dri/renderD*`，禁止映射 `/dev/dri/card*`、整个 `/dev/dri`、`/dev/mem` 或其他 PCI 设备。
5. Host Agent 必须把 GPU allocation、IOMMU group、driver/firmware 版本和 reset domain 写入账本，并在容器退出后执行 reset 与残留检查。
6. GPU hang、reset failure、驱动 oops 或跨会话数据残留测试失败会立即 drain 并 quarantine 整个节点。

启用硬件 GPU 前必须独立通过 Gate G；不能把功能测试成功当作租户隔离证明。

## 12. 网络、存储与秘密边界

- Host Agent 创建逐设备 netns、TAP、MAC、IP 和防火墙规则；容器不能创建或重配置它们。
- 默认拒绝所有入口和出口。WebRTC、ADB 和测试出口只能由固定 `networkPolicyId` 映射到平台侧网关/代理。
- ADB、WebRTC、TURN 和工作负载身份由上层短期凭证服务提供，API 和本地账本不保存明文长期秘密。
- 基线制品绝不写入；会话数据只写入单设备加密目录，使用每会话 DEK 和明确容量上限。
- 日志必须做租户数据和凭据脱敏，并有字节上限与保留期，避免通过日志填满宿主盘。
- 不允许 guest 或容器直接访问云 metadata service、节点管理网、registry、containerd 或 Host Agent API。

## 13. 确定性 reconcile 算法

每次 create、显式 reconcile、周期检查、Agent 重启和 Controller generation 变化都执行同一算法：

1. **Authenticate**：验证 Controller 工作负载身份、mTLS 和节点授权。
2. **Validate**：验证 schema、generation、idempotency、runtime class、tuple 准入和 example-only 拒绝规则。
3. **Lock**：取得 `(deviceId, generation)` 排他锁并开始 journal transaction。
4. **Observe**：读取 Controller 期望、本地账本和现实资源，不信任缓存状态。
5. **Classify**：分类为一致、缺失、部分创建、漂移、孤儿、冲突或已删除。
6. **Plan**：仅生成固定动作集合 `allocate/verify/start/stop/clean/quarantine`，不执行任意命令。
7. **Apply**：逐步记录 intent、执行、记录实际 ID 和结果；每步可安全重放。
8. **Verify**：执行来源、沙箱、健康和残留检查。
9. **Commit**：原子写入新状态、condition 和证据摘要，再响应 Controller。

失败重试使用有上限的指数退避。稳定 reason code 至少包括：

```text
POLICY_DENIED
EXAMPLE_ONLY_REQUEST
IDEMPOTENCY_CONFLICT
IMMUTABLE_SPEC_CONFLICT
LEASE_EXPIRED
ARTIFACT_NOT_APPROVED
PLATFORM_MANIFEST_MISMATCH
PROVENANCE_MISMATCH
SANDBOX_NOT_ENFORCED
DEVICE_ALLOCATION_CONFLICT
BOOT_TIMEOUT
CLEANUP_INCOMPLETE
ORPHAN_QUARANTINED
```

## 14. Phase Gate 清单

每个 gate 都是阻断式检查。证据必须包含原始命令输出或机器报告、RuntimeTuple、执行时间、执行环境和负责人审批；仅有截图或口头结论不算通过。

### Gate 0：需求、许可和契约冻结

- [ ] 产品范围明确为 AOSP Cuttlefish；不把 GMS、Play、Pixel 硬件能力写入本运行时承诺。
- [ ] OpenAPI、状态机、runtime class、目录布局和错误码完成工程与安全评审。
- [ ] 节点、制品、日志、会话数据的所有者和保留期已批准。
- [ ] 未通过本 gate 前不得连接生产网络或使用生产租户数据。

### Gate 1：Google 单机参考 PoC

- [ ] Cloud Orchestrator 仅存在于隔离、无生产凭据的单机 PoC。
- [ ] 记录 Android guest、同 build host package、crosvm 和 OCI platform manifest 摘要。
- [ ] 验证 ADB、boot completed、WebRTC、powerwash 和基础资源曲线。
- [ ] PoC 结束后销毁或重装节点，并证明不存在 Cloud Orchestrator 进程、镜像、socket、规则和数据。
- [ ] 本 gate 只证明参考流程，不允许生产流量。

### Gate 2：Host Agent 最小生产链

- [ ] Controller 只能通过 mTLS OpenAPI 调用 Host Agent；旁路 OCI/KVM/host path 访问测试失败。
- [ ] create/get/delete/reconcile 的相同请求重复至少 100 次，无重复 CID、IP、TAP、目录、容器或数据盘。
- [ ] 相同 idempotency key 不同 payload 返回 `409`，immutable spec 漂移返回 `409`。
- [ ] 在每个状态转换点注入 Host Agent/OCI/节点崩溃，重启后收敛且没有孤儿资源。
- [ ] Cloud Orchestrator 未安装且生产构建、配置和网络策略均不引用它。

### Gate 3：来源与沙箱

- [ ] x86_64 与 ARM64 分别固定 OCI platform manifest digest，并验证架构错配 fail closed。
- [ ] 篡改 host binary、共享库、guest image、seccomp 或 OCI bundle 都触发拒绝或 quarantine。
- [ ] 运行中替换文件、注入 `LD_PRELOAD`、符号链接逃逸和 PATH 劫持测试全部失败。
- [ ] rootfs read-only、noNewPrivileges、capabilities 全 drop、seccomp 和 LSM 均由运行时证据确认。
- [ ] 生产 crosvm 沙箱已启用，实际进程/库/命令行与 provenance manifest 一致。

### Gate 4：不可信 x86 发布

- [ ] `x86-untrusted` 只使用 `user` 镜像、一 VM/容器/netns/卷和默认 SwiftShader。
- [ ] 跨租户网络、存储、进程、vsock、ADB/WebRTC 和资源耗尽隔离测试通过。
- [ ] 删除后进程、mount、TAP、CID/IP、端口、cgroup、密钥和文件残留均为零。
- [ ] 72 小时故障注入与压力测试内没有未解释的逃逸、宿主崩溃或账本漂移。
- [ ] 安全评审明确接受 KVM 与共享宿主内核风险后才可进入有限灰度。

### Gate 5：可信 CI 发布

- [ ] 只在 `trusted-ci` 节点运行，无法与 untrusted 或普通 Pod 共节点。
- [ ] x86 v1 维持一节点一 OCI/container/VM/netns/卷，不以多容器或 multi-tenancy 提高密度。
- [ ] 完成 7 天 soak、并发跨节点启动、磁盘满、内存压力和节点重启测试。
- [ ] x86 快照只在已批准的 SwiftShader profile 开启，并证明恢复后版本与来源不漂移。

### Gate 6：ARM64 发布

- [ ] 节点、OCI manifest、host package 和 guest 全部为 ARM64，不使用跨架构模拟代替。
- [ ] ARM64 独立完成 API 37、ABI、24 小时稳定性、重启、清理和适用 CTS 门禁。
- [ ] 若开放一节点多容器，先在目标最大密度完成 7 天 soak、并发启动、单设备回收、CID/端口冲突、磁盘满、内存压力与节点重启测试。
- [ ] ARM64 不宣称支持 x86 专有快照或未经验证的 GPU 路径。

### Gate G：可选硬件 GPU

- [ ] 不可信模式证明设备/IOMMU/reset domain 独占；可信共享模式证明只含单一信任域。
- [ ] 容器只看到分配的 render node，无法打开 card node 或其他 GPU/VF。
- [ ] GPU reset、hang、driver crash 和节点重启后的显存/资源残留测试通过。
- [ ] GPU driver、firmware、crosvm 和 OCI platform manifest 均进入 RuntimeTuple。
- [ ] 任一 reset 或隔离检查失败会自动 drain/quarantine 节点。

### Gate 7：生产晋级与持续门禁

- [ ] `cts-virtual-device-stable` 零非预期失败，并完成声明能力相关的 CTS/VTS/STS。
- [ ] Android security patch、host kernel、KVM、crosvm、OCI base 和 GPU driver 满足补丁 SLA。
- [ ] 灰度、回滚、Controller 不可用、Agent 重启、节点断电和灾备恢复演练通过。
- [ ] 监控覆盖状态转换、来源漂移、seccomp/LSM 拒绝、资源残留、GPU reset 和孤儿资源。
- [ ] 每次 RuntimeTuple 变化自动回到 Gate 3，并按影响重新执行 Gate 4、5、6 或 G。

## 15. 发布不变量

生产系统必须持续证明：

1. 一个设备只有一个 Controller 期望、一个 Host Agent 所有者、一个 OCI 容器和一个 Cuttlefish VM。
2. 所有副作用都能关联到 CR UID、device ID、generation、spec hash、idempotency key 和 RuntimeTuple。
3. 没有任何生产路径依赖 Google Cloud Orchestrator。
4. OCI 运行的是当前平台 manifest digest，不是仅凭 tag 或 index 猜测的平台变体。
5. guest、host package、crosvm、进程树和加载库来源一致且可验证。
6. 不可信 profile 不共享 GPU，且容器没有 privileged、额外 capability、可写 rootfs 或禁用的沙箱。
7. 删除完成的含义是所有权限、身份、进程、网络、设备、mount 和数据均已验证清除。
8. 任何无法证明的条件都视为未通过，而不是“默认正常”。
