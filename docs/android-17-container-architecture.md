# Google 原生 Android 17 容器化运行方案

> 版本：1.1
> 基线日期：2026-07-17
> 目标：以 Android 手机形态为范围，在可编排的容器基础设施中运行 Google 官方来源、可验证的最新稳定 Android，并覆盖开发、测试、交互使用及真实硬件验证。

## 1. 结论先行

截至 2026-07-17，最新稳定版是 **Android 17 / API 37**；AOSP 稳定标签为 `android-17.0.0_r1`。Android 17 QPR1 Beta 7 虽然更新，但仍是预览版本，不进入生产基线。

严格意义上的以下四个条件**不能在同一个通用容器里同时成立**：

1. Google 官方原生 Android；
2. 完整 GMS、Google Play Store 与 Google 账号体系；
3. 摄像头、基带、eSIM、GNSS、NFC、安全元件、生物识别、Widevine L1、硬件证明等全部真实硬件能力；
4. 可对第三方交付或作为生产云服务合法运行。

原因不是容器参数不够，而是产品边界本身冲突：

- **AOSP 原生**是 Google 主导的开源 Android，但不包含 GMS、Play Store 和 Google 专有应用。
- **GMS/Play 原生**是专有软件，Android 兼容及 CTS 通过只是申请许可的前提，不会自动获得 GMS 许可或 Play Protect 认证。
- Android 17 GMS+GSI 的公开许可仅允许用于应用兼容性测试，并明确禁止分发 GMS。
- Cuttlefish 与物理设备的主要差异就在 HAL 和定制硬件；虚拟设备无法生成真实基带、TEE/StrongBox、硬件密钥或运营商认证能力。
- Android Emulator 的通用支持文档说明，VM 加速 Emulator 不支持运行在 Docker 等另一层环境；Google 同时提供了 Linux-only、标记为 experimental 的 Emulator Container Scripts。后者证明技术 PoC 可行，但不是生产支持或 GMS 交付承诺。

因此推荐采用一套**三池混合架构**：

- **主轨：Android 17 AOSP + Cuttlefish + KVM + Google 官方 Cuttlefish 容器镜像**，负责高保真 Framework/API、规模化运行、远程交互与自动测试。
- **补全池 A：裸机 Google Play AVD 测试池**，覆盖许可允许范围内的 GMS/Play 应用兼容性测试。
- **补全池 B：物理 Pixel 设备池**，覆盖真实硬件、Play Integrity、运营商、DRM 和生物识别验证。

这不是降低目标，而是唯一不伪造“完整功能”、同时满足技术与许可边界的方案。若业务要求把含 GMS 的虚拟 Android 作为产品交付，必须先进入 Google/OEM 的正式 GMS 许可与设备认证流程，再决定产品形态。

> 许可部分依据 Google/Android 公开条款整理，用于架构决策，不替代 Google 的书面授权或正式法律意见。

## 2. “Google 原生”的三个层级

| 层级 | 定义 | 能否容器化 | 推荐用途 |
|---|---|---:|---|
| L1：AOSP 原生 | Google/AOSP 官方源码与 Cuttlefish 目标，不含 GMS | 是，官方支持 | 系统开发、应用 CI、远程 Android、Framework/API 测试 |
| L2：Google Play 测试原生 | SDK 仓库实际提供的 Google Play AVD，或受许可的 GMS+GSI | 通用支持矩阵不支持 AVD-in-Docker；有 Linux experimental 路径；GMS+GSI 不可分发 | 内部应用兼容性测试 |
| L3：Pixel/GMS 产品原生 | Google 书面授权、Play Protect 认证、厂商签名、硬件根信任 | 无公开自助容器认证路径；虚拟产品能否获批取决于 Google/OEM | 生产用户体验、银行/DRM/运营商/硬件安全验证 |

本方案的容器集群实现 L1 的高保真目标；具体覆盖度由镜像声明、虚拟 HAL 和测试结果决定。系统整体通过 L2、L3 池补齐验证覆盖。

### 2.1 “完整功能”的验收口径

- 本方案的目标形态是 Android 手机。Android TV、Wear OS、Android Automotive、Android XR 等具有不同 CDD、系统镜像、HAL 与认证流程，必须作为独立产品线设计，不能用手机池的结果替代。
- “完整”指三池联合覆盖一个**版本化、可枚举的能力目录**，不表示任何单个容器或单台 Pixel 同时具备所有 Android 可选能力。
- 每个能力必须记录 `capability_id`、适用机型/地区/运营商、资源池、真实/高保真/模拟/条件性/不支持状态、前置条件、测试、预期结果、证据摘要、有效期和不适用理由；未知能力默认不支持，不能默认为通过。
- AOSP 公共 API 与 Framework 行为由 Cuttlefish 池证明；GMS/Play 行为由许可允许的 Google Play AVD 或认证 Pixel 证明；基带、TEE、DRM、射频与安全硬件行为只接受对应物理设备证据。
- Pixel 专属 AI、相机、Wallet、卫星、运营商或云端功能受 SKU、地区、账号、服务端开关和授权约束，只有实际满足前置条件并通过测试的组合才计入覆盖。
- 若验收合同坚持“同一个通用容器必须同时提供完整 GMS、真实硬件根信任和全部手机能力”，结果必须判定为 `FAIL—外部技术/许可约束不可满足`，不能把三池联合结果伪装成单容器通过。

## 3. 总体架构

<div style="width:1200px;box-sizing:border-box;position:relative;background:#f0f4f8;padding:20px;border-radius:8px;border:1px solid #c8d6e5;">
<style scoped>
.a17-title{text-align:center;font-size:22px;font-weight:700;color:#1a365d;margin-bottom:14px;font-family:Georgia,serif}.a17-layer{margin:8px 0;padding:12px;border-radius:6px;box-shadow:0 1px 4px rgba(30,58,138,.08)}.a17-layer-title{font-size:13px;font-weight:700;margin-bottom:9px;text-align:center}.a17-grid{display:grid;gap:8px}.a17-grid-2{grid-template-columns:repeat(2,1fr)}.a17-grid-3{grid-template-columns:repeat(3,1fr)}.a17-grid-4{grid-template-columns:repeat(4,1fr)}.a17-box{border-radius:4px;padding:8px;text-align:center;font-size:11px;font-weight:600;line-height:1.4;color:#1e293b;background:#fff;border:1px solid #cbd5e1}.a17-box small{font-weight:400;color:#475569}.a17-box.official{background:linear-gradient(135deg,#dbeafe 0%,#bfdbfe 100%);border:2px solid #2563eb}.a17-box.custom{background:#fff;border:1px dashed #64748b}.a17-user{background:linear-gradient(135deg,#dbeafe 0%,#bfdbfe 100%);border:2px solid #3b82f6}.a17-user .a17-layer-title{color:#1e40af}.a17-app{background:linear-gradient(135deg,#e0f2fe 0%,#bae6fd 100%);border:2px solid #0284c7}.a17-app .a17-layer-title{color:#075985}.a17-control{background:linear-gradient(135deg,#e0e7ff 0%,#c7d2fe 100%);border:2px solid #6366f1}.a17-control .a17-layer-title{color:#3730a3}.a17-env{padding:12px;border:2px solid #7c3aed;border-radius:6px;background:linear-gradient(135deg,#f5f3ff 0%,#ede9fe 100%)}.a17-env-title{font-size:13px;font-weight:700;color:#5b21b6;text-align:center;margin-bottom:10px}.a17-zone-row{display:flex;gap:10px}.a17-zone{flex:1;padding:10px;border:1px solid #a78bfa;border-radius:5px;background:#fff}.a17-zone.main{border:2px solid #2563eb;background:#eff6ff}.a17-zone.test{border:2px solid #d97706;background:#fffbeb}.a17-zone.physical{border:2px solid #0f766e;background:#ecfdf5}.a17-zone-title{font-size:12px;font-weight:700;text-align:center;margin-bottom:7px;color:#334155}.a17-nest{padding:8px;border:1px dashed #94a3b8;border-radius:4px;background:rgba(255,255,255,.8);margin-top:7px}.a17-nest-title{font-size:10px;font-weight:700;text-align:center;color:#475569;margin-bottom:6px}.a17-data{background:linear-gradient(135deg,#ecfdf5 0%,#d1fae5 100%);border:2px solid #10b981}.a17-data .a17-layer-title{color:#065f46}.a17-flow{text-align:center;color:#64748b;font-size:17px;font-weight:700;line-height:1}.a17-legend{display:flex;gap:12px;justify-content:center;margin-top:10px;font-size:10px;color:#475569}.a17-dot{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:-1px}.a17-note{margin-top:10px;padding:8px;border-radius:4px;background:#fee2e2;border:1px solid #ef4444;color:#7f1d1d;text-align:center;font-size:11px;font-weight:700}
</style>
<div class="a17-title">Android 17 混合运行与全功能验证架构</div>
<div class="a17-layer a17-user"><div class="a17-layer-title">使用者与自动化入口</div><div class="a17-grid a17-grid-4"><div class="a17-box">Web 远程用户<br><small>浏览器 / WebRTC</small></div><div class="a17-box">应用 CI<br><small>ADB / Test Runner</small></div><div class="a17-box">系统研发<br><small>Framework / CTS / VTS</small></div><div class="a17-box">平台管理员<br><small>容量 / 版本 / 审计</small></div></div></div>
<div class="a17-flow">↓</div>
<div class="a17-layer a17-app"><div class="a17-layer-title">统一访问层（企业自研）</div><div class="a17-grid a17-grid-4"><div class="a17-box custom">API Gateway<br><small>TLS / WAF / Rate Limit</small></div><div class="a17-box custom">OIDC + RBAC<br><small>租户 / 配额 / 租约</small></div><div class="a17-box custom">WebRTC / ADB Gateway<br><small>短期凭证 / 审计</small></div><div class="a17-box custom">TURN / Egress Gateway<br><small>NAT / 出站策略</small></div></div></div>
<div class="a17-flow">↓</div>
<div class="a17-layer a17-control"><div class="a17-layer-title">控制面</div><div class="a17-grid a17-grid-4"><div class="a17-box custom">Session Service<br><small>状态机 / TTL / 回收</small></div><div class="a17-box custom">K8s Controller + CRDs<br><small>Session / Device / Image / Pool</small></div><div class="a17-box official">Cloud Orchestrator<br><small>仅 Phase 1 单机 PoC 参考</small></div><div class="a17-box custom">Image + Capability Controller<br><small>来源 / 能力证据 / 晋级</small></div></div></div>
<div class="a17-flow">↓</div>
<div class="a17-layer a17-app"><div class="a17-layer-title">Kubernetes 调度与节点执行层（企业自研）</div><div class="a17-grid a17-grid-4"><div class="a17-box custom">Node labels + Taints<br><small>arch / KVM / GPU / trust zone</small></div><div class="a17-box custom">Node Host Agent assignment<br><small>唯一节点资源所有者</small></div><div class="a17-box custom">CNI policy profile<br><small>每会话 netns / 默认拒绝</small></div><div class="a17-box custom">Quota + Lifecycle<br><small>cgroup limits / 回收 / 控制面 PDB</small></div></div></div>
<div class="a17-flow">↓</div>
<div class="a17-env"><div class="a17-env-title">专用裸机数据面（私有 DC / VPC）</div><div class="a17-zone-row"><div class="a17-zone main"><div class="a17-zone-title">主轨：AOSP Cuttlefish 容器池</div><div class="a17-box custom">本地 root-owned Host Agent<br><small>固定 schema / image / mount / flags</small></div><div class="a17-box official" style="margin-top:7px">Google 官方 Cuttlefish OCI<br><small>按 digest 固定；只作基础依赖/编排外壳</small></div><div class="a17-nest"><div class="a17-nest-title">OCI Container：同 guest build 的 host package</div><div class="a17-grid a17-grid-2"><div class="a17-box official">cvd + crosvm<br><small>匹配 host binary digest / --vm_manager=crosvm</small></div><div class="a17-box official">Environment services<br><small>OpenWrt / wmediumd / Casimir / GNSS；BT 独立控制</small></div></div><div class="a17-nest"><div class="a17-nest-title">KVM Guest VM</div><div class="a17-box official">Android 17 AOSP / API 37<br><small>pinned patched commit · Cuttlefish virtual HAL</small></div></div></div><div class="a17-grid a17-grid-3" style="margin-top:7px"><div class="a17-box official">COW overlay<br><small>Cuttlefish 每实例增量盘</small></div><div class="a17-box custom">加密会话盘<br><small>每租户 DEK / 生命周期清理</small></div><div class="a17-box official">GfxStream / Virgl / SwiftShader<br><small>Vulkan 仅 GfxStream/SwiftShader 路径</small></div></div></div><div class="a17-zone test"><div class="a17-zone-title">补全池 A：Google Play AVD 测试池</div><div class="a17-box official">SDK repository 可用性 gate<br><small>仅实际发布的 Play Store image</small></div><div class="a17-nest"><div class="a17-nest-title">推荐直接运行在裸机宿主</div><div class="a17-grid a17-grid-2"><div class="a17-box">Android Emulator<br><small>通用文档不支持 Docker 嵌套</small></div><div class="a17-box">Linux experimental 容器<br><small>可做 PoC，不作生产支持承诺</small></div></div></div><div class="a17-box custom" style="margin-top:7px">独立账号 / 网络 / 存储<br><small>严格受 SDK 与 GMS 许可约束</small></div></div><div class="a17-zone physical"><div class="a17-zone-title">补全池 B：物理 Pixel 全功能池</div><div class="a17-box official">认证 Pixel + 官方 OTA<br><small>锁定 bootloader / 原厂信任链</small></div><div class="a17-nest"><div class="a17-nest-title">真实硬件与实验设施</div><div class="a17-grid a17-grid-2"><div class="a17-box">SIM/eSIM / Carrier<br><small>电话 / 短信 / IMS</small></div><div class="a17-box">Camera / GNSS / Sensors<br><small>真实 ISP 与传感器</small></div><div class="a17-box">NFC / Biometrics<br><small>SE / TEE / StrongBox</small></div><div class="a17-box">Integrity / DRM<br><small>Play Integrity / Widevine L1</small></div></div></div><div class="a17-box custom" style="margin-top:7px">Pixel Lab Adapter<br><small>容器只负责编排，不承载 Android 本体</small></div></div></div></div>
<div class="a17-layer a17-data"><div class="a17-layer-title">共享制品与可观测性（企业自研）</div><div class="a17-grid a17-grid-4"><div class="a17-box custom">只读镜像仓库<br><small>device image + host package</small></div><div class="a17-box custom">加密会话存储<br><small>overlay / userdata / snapshot</small></div><div class="a17-box custom">日志与指标<br><small>boot / KVM / WebRTC / CTS</small></div><div class="a17-box custom">防篡改审计<br><small>digest / provenance / lifecycle</small></div></div></div>
<div class="a17-note">严格边界：Cuttlefish 容器提供官方 AOSP 目标的高保真 Framework 行为；实际覆盖由虚拟 HAL 与测试证明。GMS 产品许可、真实硬件与认证完整性必须由 Google 授权环境或物理认证设备提供。</div>
<div class="a17-legend"><span><i class="a17-dot" style="background:#bfdbfe;border:1px solid #2563eb"></i>Google / AOSP 官方组件</span><span><i class="a17-dot" style="background:#fff;border:1px dashed #64748b"></i>企业自研编排与安全胶水</span><span><i class="a17-dot" style="background:#fff;border:1px solid #cbd5e1"></i>外部/运行时资源</span><span><i class="a17-dot" style="background:#fee2e2;border:1px solid #ef4444"></i>许可/硬件边界</span></div>
</div>

### 3.1 核心原则

1. **容器是运行时外壳，不是 Android 的安全边界。** 容器封装 Cuttlefish 主机工具和依赖，Android 作为 KVM 虚拟机客体运行。
2. **稳定标签固定，滚动分支只做发现。** 生产镜像固定 `android-17.0.0_r1`、构建 ID、哈希和 SBOM；`android-latest-release` 仅用于发现新版本并触发验证流水线。
3. **一份只读基线，多份独立增量盘。** 系统分区只读共享，每台虚拟设备使用独立 COW overlay 和 `userdata`，销毁时加密擦除。
4. **能力声明必须真实。** 不存在的硬件能力不得通过修改 `build.prop` 或伪造 feature flag 宣称支持。
5. **GMS 与 AOSP 供应链完全分离。** AOSP 集群不得侧载未知来源的 GMS 包；GMS 测试镜像只进入受许可、隔离的测试池。
6. **“全功能”验收以物理设备为最终判定。** 虚拟结果通过后，硬件、安全与运营商相关用例必须落到 Pixel 池复验。

## 4. 组件设计

### 4.1 入口层

- Web 门户：创建、租用、暂停、重置和销毁 Android 会话。
- 自动化 API：供 CI、测试平台和设备实验室调用。
- WebRTC 网关：画面、触控、键盘、音频；摄像头、麦克风和传感器数据属于协议可扩展能力，必须按具体 Cuttlefish build、Web UI 与虚拟 HAL 集成验证后才开放。
- ADB 网关：只提供短期、单设备、审计化的 ADB 隧道；禁止直接暴露 `5555` 或 Cuttlefish ADB 端口。
- TURN/STUN：跨 NAT 的 WebRTC 中继，凭证短期化，按租户限流。

### 4.2 控制面

- 身份与租约服务：OIDC、RBAC、租户配额、会话 TTL、并发限制。
- 设备调度器：按 `architecture`、Android build、GPU、持久化级别和能力标签选择资源池。
- Cuttlefish 适配器：生产只写入期望状态，由节点 Host Agent 调用 `cvd create/start/stop/remove`；Google Cloud Orchestrator 只用于 Phase 1 单机参考 PoC，不进入生产控制链。
- 镜像控制器：从 AOSP CI/源码构建获取 Cuttlefish 客体镜像及同构建的 host package，校验签名/哈希并生成不可变清单。
- 能力与证据控制器：维护版本化能力目录，将每个能力路由到 Cuttlefish、Google Play AVD 或 Pixel 池，并在证据缺失、过期或授权不匹配时阻断晋级。
- 场景控制器：调用 Cuttlefish Environment Control API 控制 GNSS、OpenWrt、wmediumd 与 Casimir；Bluetooth 通过 Rootcanal/netsim 的独立控制面处理。
- Pixel Lab 适配器：管理真实 Pixel、USB 电源、ADB、SIM/eSIM 测试环境和硬件清场。

> Google 的单机参考 Cloud Orchestrator 通过 Docker socket 管理容器。生产不部署该 Docker-socket 控制链，也不向远程控制面或租户提供通用 `create` 代理；节点上只有 root-owned Host Agent 能操作专用 OCI runtime namespace。Agent 接收固定高层 schema，只能选择已晋级镜像、固定设备、固定挂载和经过审核的 Cuttlefish flags，并使用 mTLS、工作负载身份、幂等请求 ID 与本地策略复核。

### 4.3 Kubernetes 调度与节点执行层

- 定义 `AndroidImage`、`AndroidDevice`、`AndroidSession`、`DevicePool` CRD；Controller 只拥有集群期望状态、配额、调度决策、终结器和审计，不直接创建 TAP、vsock 或 Cuttlefish 进程。
- 节点使用 labels、taints/tolerations 区分 `x86_64/arm64`、KVM、GPU、可信 CI 和不可信租户池；`DevicePool` 上报可分配 CPU、RAM、磁盘、instance number、vsock CID、端口与 GPU 容量。
- 生产链固定为 `K8s Controller → node-local Host Agent → 专用 OCI runtime namespace → Cuttlefish/crosvm`。Host Agent 是节点级资源的唯一写入者和 reconciler，使用 `session_uid` 标记并拥有 cgroup、netns/CNI、TAP/MAC、vsock CID、WebRTC/ADB 端口、挂载、overlay 和 OCI 容器。
- 运行时契约 v1 固定一台 Android VM 对应一个 host container、一个 cgroup、一个网络命名空间和一个会话卷。Cuttlefish multi-tenancy 只作为未来的可信 CI 优化，必须先引入显式 group API、成组生命周期语义和新契约版本。
- API/Controller 的配额和调度结果由 Agent 转换为 cgroup v2、CNI 与 nftables 默认拒绝策略；任一步骤创建失败都按相反顺序回滚。Agent 重启后从 CR 期望状态、OCI runtime 和带 `session_uid` 的节点资源三方对账，孤儿资源先隔离再清理。
- 租户无法直接创建或修改 host container。工作容器禁止 `privileged`、`hostPID`、`hostNetwork`、任意 host mount 与额外 capability；`/dev/kvm`、分配的 render node 和只读制品目录只能由 Agent 按固定 OCI spec 注入。TAP/TUN 与 CNI 操作所需权限只保留在节点 Agent/网络组件。
- PDB 只保护无状态控制面；设备会话按照持久化等级执行可重建、迁移或显式中断策略。完整 Agent API、状态机与资源回收契约见 `android-17-production-runtime-contract.md`。

节点资源所有权必须唯一：

| 组件 | 唯一拥有的状态 | 禁止事项 |
|---|---|---|
| K8s Controller | CR 期望状态、租约、调度、配额、晋级决策 | 不直接调用 Docker/CRI，不创建节点网络资源 |
| Host Agent | 节点实际状态与全部 session-scoped 资源 | 不接受任意命令、任意镜像、任意 mount/flag |
| OCI runtime | Agent 创建的容器、cgroup 与进程生命周期 | 不接受租户或远程控制面直接访问 |
| Cuttlefish/crosvm | Android VM 与客体生命周期 | 不拥有租约、授权或跨租户调度状态 |

### 4.4 Cuttlefish 数据面

每个专用 Linux 节点具备：

- x86_64 的 VT-x/AMD-V + EPT/RVI，或 ARM64 虚拟化扩展；
- `/dev/kvm`；
- Cuttlefish 所需的 TAP/TUN、vsock/vhost 与网络能力；
- 可选 `/dev/dri/renderD*`，用于 GfxStream/Virgl 图形加速；
- cgroup v2、IOMMU、独立节点网络与加密本地 NVMe；
- Google 官方 `us-docker.pkg.dev/android-cuttlefish-artifacts/cuttlefish-orchestration/cuttlefish-orchestration:stable` 容器作为来源，但部署时必须为目标架构解析并固定到**平台 manifest digest**，不能只固定多架构 index digest。

OCI 只作为基础依赖与编排外壳。实际执行的 `cvd`、crosvm 和配套 host binaries 必须来自与 guest image **同一 build** 的 `cvd-host_package.tar.gz`，以只读版本目录挂载/安装，并由 entrypoint 使用绝对路径启动；禁止静默回退到容器内不匹配的预装二进制。

每个晋级版本使用独立 artifact-set/release ID，例如 `a17-r1+asb-2026-07.9f3c2a1`，并采用固定目录布局：

- 宿主 `/opt/android-runtime/artifacts/<artifact-set-id>/{host,guest}`：同 build 的 host package 与 guest images，只读；
- 宿主 `/var/lib/android-host-agent/sessions/<device-id>`：加密 overlay、`userdata`、日志与会话状态，逐设备隔离；
- 容器 `/opt/cuttlefish/{host,guest}`：上述制品的只读映射；
- 容器 `/var/lib/cuttlefish/session`：唯一会话的配额化可写映射；`/run/cuttlefish` 与 `/tmp` 使用独立受限 tmpfs；
- 容器 rootfs 只读；基线目录与会话目录禁止重叠，API 不能传入任何路径。

Entrypoint 清空继承的 `PATH`/动态库搜索变量后，只加入固定 host runtime；以绝对路径执行 `cvd`，canonical config 固定 crosvm、只读 image 目录、可写会话目录和已审核 flags。readiness 与发布验收检查平台 OCI digest、host binary digest、实际 crosvm 进程、命令行和版本，并枚举所有 Cuttlefish 子进程的 `/proc/<pid>/exe` 与 `/proc/<pid>/maps`，确认可执行文件和已加载 host libraries 均来自固定 release 目录；任何版本漂移或 VMM/库回退都视为失败。

容器内部运行 Cuttlefish host processes，客体侧运行：

- `aosp_cf_x86_64_only_phone-userdebug`，用于最快 CI、快照和通用 Framework 测试；
- `aosp_cf_arm64_only_phone-userdebug`，用于 ARM64 ABI、接近移动端指令集的验证；
- Android 17 Framework、ART、System Server、AOSP System UI 与 Cuttlefish 虚拟 HAL。

`userdebug` 只进入隔离研发/CI 池。若 AOSP 会话面向长期生产用户，应从同一固定源码基线构建 `user` 变体，使用自有 release/AVB/OTA keys、SELinux enforcing、锁定调试入口，并重新执行完整兼容性与升级验证；不能把公开 `userdebug` 测试镜像直接当成量产安全镜像。

建议生产隔离单位为“一台 Android VM 对应一个租约”。由于官方单机 Cloud Orchestrator 当前存在 x86_64 多 Docker 实例的 `vhost_user_vsock` 限制，调度必须遵循下表，而不能自动假设一节点可运行任意数量的独立容器：

| 节点/工作负载 | 默认调度策略 | 开放条件 |
|---|---|---|
| x86_64 不可信租户 | 一台裸机节点只运行一个不可信 host container；可在该租户内部按授权使用同组 VM | 独立实例并发限制被上游修复且完成相同版本 PoC 后才能放宽 |
| x86_64 可信 CI | 运行时契约 v1 仍为一节点一 VM/host-container | 只有上游并发限制已解决，或发布带 group API/成组生命周期的新契约并完成 PoC 后才提高密度 |
| ARM64 不可信租户 | 初始仍按一节点一不可信 host container | 多容器并发、KVM、vsock、CNI、清理和故障恢复 PoC 全部通过后逐步放宽 |
| GPU 工作负载 | SwiftShader 或独占 GPU 节点 | 只有验证过的 vGPU/SR-IOV 强隔离方案才能共享物理 GPU |

若未来启用 multi-tenancy，同一次启动的实例存在组级生命周期耦合，只能用于可信 CI 或同一租户，并由新的 group API 管理。当前 Host Agent 为每台 VM 原子保留 instance number、vsock CID、TAP/MAC/IP、WebRTC/ADB/环境控制端口并检测冲突。不能把 Cuttlefish host container 本身视为强租户边界；真正的工作负载隔离依赖 KVM VM、专用节点池和网络分段。

### 4.5 存储

- 基线仓库：按 `os-version/build-id/arch/target` 保存只读客体镜像、host package、SHA-256、SBOM 和测试报告。
- 会话盘：每实例独立 overlay；短会话存本地 NVMe，长会话存加密块存储。只读 release 与可写 runtime/data 使用不同 mount，Host Agent 不允许把基线目录重新挂载为可写。
- 快照：仅作为加速手段，不作为跨版本迁移格式。Cuttlefish 当前快照只支持 x86_64，且要求关闭 VirtioFS 并使用 `guest_swiftshader`。
- 升级：绝不在既有 overlay 下替换基线盘；新版本新建资源池，应用和测试数据通过受控导出/导入迁移。
- 清理：销毁租约后撤销密钥，再删除 overlay、日志中的敏感字段和临时 TURN/ADB 凭证。

### 4.6 网络与远程交互

- 不可信会话遵循一 VM/host-container，因此每 VM 拥有独立 network namespace、DNS 和 egress policy；Host Agent 通过经审核的 CNI profile 创建网络，并以 session UID 标记 nftables/eBPF 规则。
- 若未来启用可信 multi-tenancy，组内多个 VM 将共享同一个 host-container network namespace，仅使用独立 TAP/MAC/IP 区分；此时无法提供逐 VM 的强网络策略隔离，因此不得混放不同不可信租户。
- WebRTC 默认通过 HTTPS `8443`；远程连接还需规划 TCP/UDP `15550-15599`，生产由网关/TURN 统一代理，不直接放开节点端口。
- ADB 仅监听节点回环或私有 sidecar，外部通过 mTLS gateway 映射到单一序列号。
- Wi-Fi 使用 OpenWrt + wmediumd 模拟，蓝牙使用 Rootcanal/netsim 独立模拟，GNSS 使用 `GnssGrpcProxy`，NFC 使用 Casimir；通用传感器注入需要按具体 build、前端和虚拟 HAL 单独验证。
- 需要真实外设时进入 Pixel 设备池；USB/IP、PCIe 或物理射频透传只能作为专用实验室扩展，不能据此声称容器获得完整手机硬件能力。

## 5. 镜像供应链与版本升级

### 5.1 稳定通道

1. 版本观察器读取 AOSP 官方 build/tag 信息：源码 manifest 观察 `android-latest-release`，Cuttlefish CI 制品观察 `aosp-android-latest-release`，但二者都不能直接作为生产运行标识。
2. 只以正式稳定标签作为上游基线；当前首个 Android 17 稳定标签为 `android-17.0.0_r1`，但生产运行物必须继续合入适用的 Android Security Bulletin/AOSP 安全补丁并固定到审核后的 manifest commit。
3. x86_64 与 ARM64 分别下载/构建 Cuttlefish guest images；将 Google Cuttlefish OCI 固定到目标架构的平台 manifest digest，并把**同一 guest build**的 `cvd-host_package.tar.gz` 作为实际 host runtime。三者形成不可拆分版本元组。
4. 生成 guest/host binary/OCI 的 SHA-256 或 digest、受信上游 URL、平台 manifest、kernel/GKI、WebRTC assets、target/ABI、构建工具链、SBOM、provenance/attestation、`ro.build.version.security_patch`、manifest commit、签名密钥身份及可复现记录。
5. 在隔离候选池先运行 Cuttlefish 专用 `cts-virtual-device-stable`，要求零非预期失败；再运行与声明能力相关的 CTS 17 R1 模块、CTS Verifier、VTS/STS 与内部安全扫描，并记录全部排除依据。完整 CTS 含物理设备测试，不能把虚拟设备结果表述为设备认证。
6. 通过后签名并晋级 `candidate`，灰度到 5% 节点，再晋级 `stable`。
7. 旧池保留回滚窗口；持久化会话不进行原地跨基线恢复。

安全补丁是持续门禁，不是发布一次即结束。建议初始策略为月度补丁滞后不超过 30 天；已知在野利用或高危内核/KVM/crosvm/GPU 漏洞进入紧急通道，单独定义更短的评估、灰度和全量时限。任何超过门限的镜像自动停止新建会话。

基于 Google/AOSP 标签自行合入补丁并使用组织密钥签名后，制品身份必须标记为“Google/AOSP 官方源码派生、组织构建与签名”，不得称为 Google 签名二进制或原始 `r1` 镜像。版本观察器至少每日读取官方稳定发布与 build-number 数据源；当新的稳定 major/API/tag 发布时，旧 major 在 24 小时内停止作为“latest”创建新会话，只能进入明确标注的兼容池，直到新版本通过候选门禁。观察结果、响应摘要、时间、解析器版本和决策均写入不可变证据记录。

### 5.2 预览通道

Android 17 QPR1 Beta 仅进入 `preview` 池，网络、账号和数据与稳定池隔离；不得把 Beta 的测试结果作为生产兼容结论。

## 6. 功能覆盖矩阵

图例：`完整` = 目标环境真实提供；`高保真` = Framework 行为与 AOSP 高度对齐，覆盖范围由 feature 声明、虚拟 HAL 和测试结果证明；`模拟` = 适合功能测试，不等价于真实硬件；`受限` = 取决于许可、认证、机型或应用策略；`无` = 不提供。

| 能力 | AOSP Cuttlefish 容器池 | Google Play AVD 裸机测试池 | 物理 Pixel 池 |
|---|---|---|---|
| Android 17 Framework/API 37 | 高保真，覆盖以测试为准 | 仅在 API 37 Play Store image 实际发布时成立；不存在则 Android 17 GMS 验收为 `BLOCKED`，旧版只能进入独立兼容池 | 完整 |
| AOSP System UI、Settings、Launcher | Cuttlefish 目标提供；具体覆盖以测试为准 | Google 镜像实现 | Pixel 实现 |
| Google Play services / Play Store | 无 | 对应 Play Store image 实际存在时提供，限测试用途 | 完整、已认证 |
| Google 账号、同步、Play 更新 | 无 | 可测试，受账号、地区、组织与服务策略限制 | 受账号、地区、组织与服务策略限制 |
| FCM、Play Billing、Play 应用安装/更新 | 无 | 仅使用测试项目、测试付款方式和许可允许的账号验证 | 在认证设备上验证，仍受服务端与账号策略限制 |
| Google Wallet、支付与设备凭据 | 无 | 模拟器结果不作为硬件支付/设备凭据结论 | 只在支持的 Pixel SKU、地区、账号和测试环境中验证 |
| Pixel 专属 AI、相机与云端能力 | 无 | 不作为权威覆盖环境 | 只在功能实际下发且满足机型/地区/账号前置条件的 Pixel 上计入 |
| root / 系统调试 | `userdebug` 可用 | Google Play 镜像不可 root | 量产锁定；解锁后会影响认证/完整性 |
| OpenGL ES / Vulkan / GPU | GfxStream 支持 GLES/Vulkan；Virgl 无 Vulkan；SwiftShader 为软件实现 | 宿主 GPU/软件渲染 | 真实 GPU |
| 显示、触控、键盘 | WebRTC 高保真，须按 build/前端集成验证 | Emulator UI 高保真 | 真实硬件 |
| 音频、麦克风、摄像头 | WebRTC 协议可扩展承载，须按 build/UI/虚拟 HAL 集成验证 | 模拟/宿主输入 | 真实硬件 |
| Wi-Fi | OpenWrt + wmediumd 模拟 | 模拟 | 真实射频 |
| Bluetooth | Rootcanal/netsim 独立模拟 | 模拟 | 真实射频 |
| GNSS | `GnssGrpcProxy` 场景注入 | 场景注入 | 真实接收机 |
| 其他传感器 | 按 build、前端和虚拟 HAL 单独验证 | 场景注入能力依 Emulator 版本 | 真实传感器 |
| NFC / HCE | Casimir APDU 模拟 | 模拟，能力依镜像 | 真实 NFC/安全元件 |
| 电话、短信、SIM/eSIM、紧急呼叫 | Framework + 可选模拟场景；无真实 SIM/运营商 | 模拟 | 取决于机型、地区、运营商和测试 SIM |
| 生物识别 | 无真实传感器；仅在配置支持时做测试型模拟 | 模拟 | 真实传感器与安全链 |
| TEE / StrongBox / 硬件背书 KeyMint 与 attestation | 无物理等价物 | 无物理等价物 | 取决于机型与认证状态 |
| Play Integrity 物理设备完整性 | 不满足物理认证语义 | 受限；应用仍可拒绝模拟器 | 认证、锁定且未篡改设备可满足相应 verdict |
| Widevine L1 / HDCP / 安全视频路径 | 无真实 L1 保证 | 无真实 L1 保证 | 认证设备提供，受内容方策略限制 |
| USB、UWB、卫星、硬件附件 | 无或有限模拟 | 无或有限模拟 | 取决于 Pixel 型号 |
| OTA / Mainline | 自建镜像升级流水线 | Google 测试镜像更新 | Google 官方 OTA/Play System Update |
| CTS | 首要运行 `cts-virtual-device-stable`；再跑适用 CTS 17 R1/CTS-V，不能据此声称物理设备认证 | 带 Play 标识的 Phone AVD 可为 CTS-compliant | 认证流程的一部分 |
| 面向第三方生产交付 | AOSP 许可范围内可设计产品 | 未经 Google 单独书面授权及许可审查，不得作为第三方云终端交付或分发 | 按设备与服务条款使用 |

结论：**容器池可以做到 Android Framework/API 的高保真运行，但具体完整度必须由能力声明和测试证明；它不能提供物理手机全部硬件或 GMS 产品认证。** 需要“所有功能”的验收体系必须包含物理 Pixel 池。

上表是架构级分类，不是可宣称“穷尽所有功能”的静态清单。发布时以 `android-capability-evidence.schema.json` 约束的版本化能力目录为唯一机器可判定来源；目录中的每条适用能力必须得到 `PASS` 证据，或得到有负责人、原因和有效期的 `NOT_APPLICABLE` 批准，否则整体状态为 `INCOMPLETE`。

## 7. 资源模型与容量

Google 官方 on-premise 文档给出的容量示例为每实例 `4 vCPU + 8 GB RAM`；40 实例对应至少 160 核、320 GB RAM。该数字是规划示例，不是通用最低配置。

建议从以下规格开始压测：

| Profile | vCPU | RAM | 数据增量盘 | GPU | 用途 |
|---|---:|---:|---:|---|---|
| `ci-small` | 2-4 | 4-6 GB | 8 GB | SwiftShader | 无界面/轻量应用测试 |
| `interactive` | 4 | 8 GB | 16 GB | GfxStream 或 SwiftShader | WebRTC 交互、通用应用测试 |
| `graphics` | 6-8 | 12-16 GB | 24 GB | 独占 GPU 或受控切片 | 游戏、Vulkan、视频场景 |
| `arm64-compat` | 4-8 | 8-12 GB | 16 GB | 可选 | ARM64 ABI 与原生库测试 |

容量策略：

- 内存不做激进超分，初始不超过 1.1:1；CPU 可从 1.5:1 压测起步。
- 同一节点不得混跑不可信普通容器和 Cuttlefish 特权运行时。
- GPU 模式单独建池；官方单机 Cloud Orchestrator 当前不支持 GPU 加速，GPU 池需要自建并验证 Host Agent 数据面。
- x86_64 快照仅适合 SwiftShader 场景；不能同时把 GPU 加速和快照恢复当作既定能力。
- ARM64 宿主 CPU 架构不得低于客体构建所需架构。

## 8. 安全设计

### 8.1 信任边界

- 互联网只到 API/WebRTC/ADB gateway，不到 Cuttlefish 节点。
- 控制面与节点 Host Agent 之间使用 mTLS、短期工作负载身份和操作白名单。
- Android 应用运行在 KVM 客体内；Cuttlefish 容器运行在专用节点，禁止用户取得容器 shell。
- GMS 测试池与 AOSP 池分账号、分网络、分存储、分密钥。

### 8.2 最低控制项

- `/dev/kvm`、TUN/TAP、render node 和网络 capability 只授予 Cuttlefish 运行时。
- 不可信应用池强制验证 crosvm sandbox；host container 使用只读 rootfs、`noNewPrivileges`、drop-all capabilities、固定 seccomp 与 AppArmor/SELinux profile。只有 Host Agent/专用网络组件持有创建 TAP/netns 所需权限。
- 未证明 vGPU/SR-IOV 隔离前，不可信租户不得共享同一物理 GPU render node；默认使用 SwiftShader 或独占 GPU 节点。
- 不向远程控制面或租户暴露 Docker socket/API；只允许节点本地 root-owned Host Agent 执行固定 schema、固定镜像、固定设备与固定挂载的高层操作。
- ADB 默认关闭外部入口；授权后生成单设备、短 TTL、可撤销隧道。
- 每租户 egress policy、DNS 日志、速率限制和滥用检测。
- 基线镜像只读、内容寻址、签名验证；禁止运行未登记镜像。
- `userdata`、快照、日志和对象存储使用租户级密钥；快照中不得保留平台管理员凭据。
- 会话结束执行密钥撤销、powerwash/overlay 删除和残留扫描。
- 审计记录创建者、镜像摘要、ADB 操作、场景注入、网络策略变更和销毁结果。
- 发布前执行 Host Agent schema/property fuzz、越权镜像/mount/flag/设备注入、跨租户网络/磁盘/ADB/vsock 访问、设备节点攻击面、密钥销毁后数据恢复尝试，以及审计链删除/重排/篡改检测；任何逃逸、越权或可恢复租户数据均为阻断失败。

## 9. 生命周期流程

### 9.1 创建

1. 客户端申请 `os=17`、`arch`、profile、持久化级别和功能标签。
2. 控制面检查租户配额、镜像许可类别和目标池。
3. 调度器选择有 KVM/GPU/架构能力的节点。
4. 创建只读基线引用、独立 overlay、网络命名空间和短期凭证。
5. Host Agent 以固定 `--vm_manager=crosvm` 启动 Cuttlefish，并验证实际 crosvm 进程、版本和命令行；随后等待 ADB online、`sys.boot_completed=1`，以及在启用远程 UI 的 profile 中等待 WebRTC 首帧。
6. 网关返回短期会话 URL 与可选 ADB tunnel。

### 9.2 使用

- WebRTC 处理图形与输入；ADB gateway 处理自动化。
- 场景 API 按租约控制 GNSS、Wi-Fi 和 NFC；Bluetooth 经独立 Rootcanal/netsim 控制器处理，其他传感器按已验证的 build 能力开放。
- 心跳检测包括 VM、ADB、System Server、WebRTC 和存储水位。
- 异常时先尝试客体重启，再执行 `restart_cvd`；重建前保留最小诊断证据。

### 9.3 销毁

1. 撤销 WebRTC、ADB、TURN 与工作负载身份。
2. 需要保留时创建受策略控制的快照/应用数据导出。
3. 停止并移除 Cuttlefish 实例。
4. 销毁数据密钥并删除 overlay。
5. 验证端口、进程、TAP、vsock 和挂载点无残留。
6. 写入带完整性校验并进入不可变存储的防篡改审计事件。

## 10. 可用性与可观测性

建议采集以下指标：

- 调度：队列时长、容量不足、架构/GPU 命中率。
- 启动：冷启动、恢复、ADB online、boot completed、WebRTC 首帧耗时。
- 客体：CPU steal、内存压力、ANR、crash、System Server 重启、磁盘增量。
- 图形：帧率、编码时延、丢帧、GPU reset、SwiftShader 降级次数。
- 网络：WebRTC RTT/jitter/loss、TURN 中继率、ADB 断连、租户 egress。
- 生命周期：powerwash、重启、销毁失败、资源残留。
- 兼容性：CTS 模块通过率、已知豁免、版本间回归。
- 供应链：crosvm/host package 版本漂移、`ro.build.version.security_patch`、月度补丁滞后与紧急 CVE 升级状态。

生产晋级前必须冻结负载合同：目标并发 `N_target`、交互/CI/GPU/持久会话比例、每小时创建峰值、测试 APK 与网络场景。没有该合同的压测只能作为探索数据，不能证明容量。初始 SLO 建议在 PoC 压测后校准：

- 镜像已缓存时，交互实例 P95 在 90 秒内达到 `sys.boot_completed=1`；
- 同地域 WebRTC 交互 RTT P95 小于 150 ms；
- 已分配会话月可用性不低于 99.9%；
- 销毁后 5 分钟内完成凭证撤销和资源残留检查；
- 任何租户数据残留或跨租户访问事件为零容忍。

SLI 采用以下统一口径：

- 会话可用性 = 在 30 天滚动窗口内，已成功分配且未被用户主动暂停的可用会话分钟数 / 对应应服务分钟数；平台计划维护只有在提前公告且合同明确排除时才能从分母剔除。
- 启动成功率 = 在冻结负载合同下，10 分钟内达到 ADB online、`sys.boot_completed=1` 且所请求入口可用的创建请求数 / 有效创建请求数；调度容量拒绝单独计量，不能从失败率中静默删除。
- 控制面初始 RTO 为 30 分钟、RPO 为 5 分钟；短会话不承诺数据 RPO，持久会话的 RPO/RTO 必须在具体存储 profile 中声明并通过故障注入验证。
- 容量门禁至少持续 24 小时运行 `N_target`，并以 1.2 倍每小时创建峰值进行 2 小时突发测试；期间不允许出现无法解释的 kernel panic、crosvm crash、System Server 重启、跨会话资源冲突或资源残留。

## 11. 验收标准

### 11.1 来源与版本

- 每日版本观察记录显示官方最新稳定 major/API/tag 仍为声明值；`ro.build.version.sdk == 37` 只证明客体版本，不能单独证明“最新”；
- 当官方发布新的稳定 major/API/tag 后，24 小时内阻止旧 major 继续以 `latest` 创建会话，并启动新基线候选流水线；
- build fingerprint、AOSP tag、build ID、guest digest、OCI digest、host package 与 host binary digest 均与不可拆分制品清单一致；
- manifest commit、crosvm 版本与 canonical config 一致，实际进程从同 build 的只读 host runtime 路径启动并使用 crosvm；全部 Cuttlefish 子进程及加载库的 `/proc` 来源检查通过；
- 自建补丁版本使用独立 release ID，并明确标为 Google/AOSP 源码派生、组织构建/签名；不得标为 Google 签名镜像；
- `ro.build.version.security_patch` 满足组织定义的月度补丁门禁，超期镜像不能创建新会话；
- 生产只允许稳定通道签名摘要；QPR Beta 只能进入 preview pool。

### 11.2 基础功能

- 每个架构/profile 至少执行 100 次冷启动、100 次 clean reboot、100 次 powerwash、100 次 APK 安装/卸载；单项成功率必须为 100%，否则在能力目录中记录阻断缺陷；
- 在冻结负载合同下执行 10 轮并发创建/销毁，并完成 x86_64 与 ARM64 各 24 小时稳定性测试；不得出现无法解释的 kernel panic、crosvm crash、System Server 重启、端口/vsock/TAP 冲突或残留资源，进程 RSS/文件描述符相对稳定基线漂移不得超过 2%；
- WebRTC 每 profile 连续运行 4 小时，验证视频、触控、键盘、音频和网络切换；GPU 池完成 GLES/Vulkan、视频播放、旋转、分辨率切换、GPU 故障与 SwiftShader 降级恢复；
- GNSS、Wi-Fi、Rootcanal/netsim Bluetooth、NFC 场景各注入 100 次，要求目标会话 100% 命中、非目标会话 0 次污染；摄像头、麦克风与其他传感器只验收明确集成并声明的能力。

### 11.3 兼容性

- 首先运行 `cts-virtual-device-stable`，要求零非预期失败；
- 再运行与声明能力相关的 Android 17 CTS R1 与 CTS Verifier 模块，记录所有物理设备模块的排除依据；
- 不支持的硬件 feature 不得宣称存在；
- 虚拟 CTS 结果不得表述为 GMS、Play Protect 或物理设备认证；
- Google Play/银行/DRM/运营商相关结果必须在对应的 AVD 或物理 Pixel 池复验。

### 11.4 安全与隔离

- 外网无法直连 ADB、Host Agent、Docker socket、环境控制 API；
- 租户 A 无法枚举、连接、读取或影响租户 B 的 VM、网络与磁盘；
- 凭证过期、会话超时、节点故障和强制回收路径全部验证；
- 销毁后密钥、overlay、端口、进程和网络设备残留检查通过。
- Host Agent 的 schema fuzz、重放、越权 image/mount/flag/device 注入全部被拒绝；crosvm sandbox、seccomp、LSM、`noNewPrivileges`、只读 rootfs 与 capability 集由自动策略测试核对。
- 销毁并撤销 DEK 后执行原始块恢复尝试，不得恢复租户明文；审计事件删除、重排或修改必须触发完整性告警。

### 11.5 “完整功能”最终验收

以下项目只接受物理 Pixel 结果：真实 SIM/eSIM 与运营商注册、电话/短信、紧急呼叫实验室测试、真实摄像头链路、NFC/安全元件、生物识别、硬件背书 KeyMint/StrongBox 与 attestation、Play Integrity、Widevine L1/HDCP、USB/UWB/卫星能力，以及真实功耗/温控。

Pixel 覆盖矩阵以 `model/SKU + firmware/build + bootloader lock + region + carrier + test SIM/eSIM + account/service entitlement` 为最小实体。每项结果必须为 `PASS/FAIL/NOT_SUPPORTED/NOT_APPLICABLE` 之一；`NOT_SUPPORTED` 不能计为完整覆盖，`NOT_APPLICABLE` 必须有业务范围、批准人和到期时间。紧急呼叫只允许在运营商/监管批准的屏蔽实验室或专用测试网络中执行，禁止在生产公网做自动化拨测。

### 11.6 GMS、授权与发布门禁

- Google Play AVD 必须固定 SDK package path、revision、下载来源、digest、license hash 与目标 API/ABI；API 37 Play Store image 不存在时，Android 17 GMS 能力保持 `BLOCKED`，不能以 API 36 结果通过。
- 在许可允许的内部测试范围内，分别验证账号登录/退出、Play services 更新、Play Store 安装/更新、FCM、Play Billing 测试购买与账号同步；每项使用隔离测试项目和非生产付款资料。
- 任何含 GMS 的镜像/池晋级都必须引用有效的书面授权证据，机器校验适用 SKU、用途、地区、用户群、再分发权、起止时间和撤销状态；缺失、过期或范围不匹配一律 fail closed。
- 发布清单同时覆盖 AOSP/第三方许可证 notice、适用 GPL 源码提供义务、Google 商标/品牌、出口管制以及账号与遥测数据合规；法务/合规负责人审批是发布条件，不是事后记录。

### 11.7 目标—证据追踪

| 原始目标 | 设计回答 | 机器门禁 | 判定规则 |
|---|---|---|---|
| Google 最新 Android | 每日官方稳定版本观察器 + 候选升级流水线 | 官方观察证据、image manifest、客体属性 | 观察值、制品和客体三者一致才通过 |
| 容器化运行 | 官方 Cuttlefish OCI 外壳 + 同构建 host package + KVM/crosvm | Phase 1 启动证据、Phase 2 Host Agent/OCI/网络最小权限证据 | 单机与生产链均通过才可宣称生产可用 |
| Google 原生来源 | 官方 AOSP/tag/URI/provenance；禁止侧载 GApps | `android-image-manifest.schema.json` 清单与准入策略 | 派生镜像必须如实标识组织构建/签名 |
| Android 软件功能 | Cuttlefish Framework/HAL + CTS/VTS/专项测试 | 版本化 capability evidence | 全部适用能力 PASS 或批准的 N/A |
| GMS/Play 功能 | 许可允许的 Play AVD/认证 Pixel | SDK revision/digest + 授权范围 + GMS 测试证据 | 缺镜像或授权即 BLOCKED |
| 真实硬件与安全功能 | 物理 Pixel SKU/地区/运营商矩阵 | 实验室证据与有效期 | 虚拟结果不能替代物理证据 |
| “同一容器拥有全部功能” | 外部技术/许可条件不可满足 | 固定否决规则 | 必须 FAIL，不允许以联合覆盖冒充 |

详细字段、量化阈值和 fail-closed 聚合规则见 `android-17-acceptance-contract.md` 与 `contracts/` 中的 schema。设计完成不等于这些运行证据已经生成；只有部署后所有适用门禁实际通过，平台才可宣称相应能力已交付。

## 12. 分阶段落地

### Phase 0：许可与目标冻结

- 明确产品只需 AOSP，还是需要内部 GMS 测试，还是要向第三方交付 GMS 产品。
- 如果是第三种，先启动 Google GMS/OEM 商务与认证流程；在许可明确前不制作、不分发含 GMS 的容器镜像。
- 冻结手机 form factor、能力目录、Pixel SKU/地区/运营商范围、目标并发/工作负载合同、证据有效期与 `NOT_APPLICABLE` 审批责任人。

### Phase 1：官方单机 PoC

- 一台 x86_64 KVM 裸机；
- Google 官方 Cloud Orchestrator 仅作为单机参考入口；Cuttlefish stable 容器解析并固定到目标架构的平台 OCI manifest digest；
- Android 17 `android-17.0.0_r1` x86_64 userdebug，以及同一 guest build 的 host package；
- 验证 ADB、WebRTC、COW、powerwash、`--vm_manager=crosvm`、`cts-virtual-device-stable` 冒烟和资源曲线。

### Phase 2：生产 AOSP 集群

- 关闭生产 Cloud Orchestrator/Docker-socket 链；部署 `K8s Controller → Host Agent → OCI runtime → Cuttlefish` 唯一路径、专用 KVM 节点池、租约 API、mTLS 网关、镜像晋级与审计；
- 区分 `userdebug` CI 池与 release-key 签名的 `user` 长期会话池；
- 增加 ARM64 池、GPU 池、场景注入和故障恢复；
- 完成 Host Agent 幂等/恢复、最小权限 OCI、只读/可写目录分离、全部子进程来源、租户隔离、冻结负载容量压测、`cts-virtual-device-stable` 与适用的 CTS 17 R1/CTS-V 模块。

### Phase 3：GMS 应用测试池

- 每次发布前通过 `sdkmanager --list`/SDK repository metadata 实时确认 `(API 37, google_apis_playstore, ABI)` 元组确实存在并固定 package revision/digest；不存在时 Android 17 GMS 能力保持 `BLOCKED`，不得把 API 36 Play Store image 标成 Android 17；
- 推荐 Google Play AVD 直接运行在受控裸机宿主；Linux Emulator Container Scripts 只保留为 experimental PoC，不进入生产承诺；
- 与 AOSP 池共用上层租约 API，但使用不同数据面适配器；
- 仅用于许可允许的应用开发/兼容性测试，不作为生产 Android 云终端交付。

### Phase 4：物理 Pixel 全功能池

- USB/网络 ADB、可控电源、清场、设备账号、测试 SIM/eSIM、Wi-Fi/蓝牙/NFC/GNSS 实验设施；
- 将硬件、安全、DRM、运营商和 Play Integrity 用例路由到真实设备；
- 建立型号/SKU/固件/锁定状态/地区/运营商/测试 SIM/账号与服务 entitlement 矩阵，定义证据有效期；紧急呼叫只在获批实验室执行，不用单一 Pixel 推断全部 Android 设备。

## 13. 明确拒绝的路线

| 路线 | 不采用原因 |
|---|---|
| Waydroid / Anbox / reDroid 作为主方案 | 非 Google 官方 Cuttlefish 路线；共享宿主内核，Framework/HAL、隔离和升级基线难以满足本目标 |
| 给 AOSP 容器侧载 GApps | 无法获得设备认证、硬件根信任或合法分发权，且破坏供应链可验证性 |
| 把 Pixel factory image 直接塞进 Cuttlefish | Pixel vendor/HAL 与 Cuttlefish 虚拟 HAL 不匹配；即使通过 CHD 合并，也不再等同于真实 Pixel 硬件 |
| 把 Google Play AVD-in-Docker 当成生产主线 | 通用 Emulator 支持矩阵不支持；Google 的 Linux Container Scripts 明确是 experimental，且系统镜像/GMS 许可与生产交付权并未因此扩大 |
| 使用 AVF / Microdroid 承载完整 Android UI | AVF 面向 Android 设备宿主上的隔离 VM；Microdroid 不提供完整 Java API、System Server、Zygote、图形 UI 和完整 HAL，不是手机系统客体 |
| 只通过 CTS 就宣称具备 GMS/Play | CTS 是 Android 兼容前提，GMS 许可与 Play Protect 认证是另外的 Google 流程 |
| 伪造 Play Integrity、设备指纹或硬件 feature | 技术、合规与安全风险不可接受；高价值应用仍可使用硬件背书信号识别 |

## 14. 官方资料

- [Android 17 正式发布公告](https://developer.android.com/blog/posts/android-17-is-here)
- [Android 17 官方获取方式](https://developer.android.com/about/versions/17/get)
- [Android 17 QPR1 Beta 发布记录](https://developer.android.com/about/versions/17/qpr1/release-notes)
- [AOSP build tags 与 `android-17.0.0_r1`](https://source.android.com/docs/setup/reference/build-numbers)
- [Cuttlefish 概览](https://source.android.com/docs/devices/cuttlefish)
- [Cuttlefish Get started / KVM / 官方构建制品](https://source.android.com/docs/devices/cuttlefish/get-started)
- [Cuttlefish on-premise 与官方容器方案](https://source.android.com/docs/devices/cuttlefish/on-premises)
- [Google Cuttlefish stable 容器镜像](https://github.com/google/android-cuttlefish/blob/main/container/README.md)
- [Cloud Orchestrator 单机限制](https://github.com/google/cloud-android-orchestration/blob/main/scripts/on-premises/single-server/README.md)
- [Cuttlefish multi-tenancy](https://source.android.com/docs/devices/cuttlefish/multi-tenancy)
- [Cuttlefish GPU](https://source.android.com/docs/devices/cuttlefish/gpu)
- [Cuttlefish WebRTC](https://source.android.com/docs/devices/cuttlefish/webrtc)
- [Cuttlefish Environment Control](https://source.android.com/docs/devices/cuttlefish/control-environment)
- [Cuttlefish NFC](https://source.android.com/docs/devices/cuttlefish/nfc)
- [Cuttlefish snapshot/restore](https://source.android.com/docs/devices/cuttlefish/snapshot-restore)
- [Cuttlefish 专用 CTS 计划](https://source.android.com/docs/devices/cuttlefish/cts)
- [AVD 镜像类型与 Google Play 镜像](https://developer.android.com/studio/run/managing-avds)
- [Android Emulator VM 加速限制](https://developer.android.com/studio/run/emulator-acceleration)
- [Google experimental Emulator Container Scripts](https://github.com/google/android-emulator-container-scripts)
- [Android Virtualization Framework](https://source.android.com/docs/core/virtualization)
- [Microdroid 的能力边界](https://source.android.com/docs/core/virtualization/microdroid)
- [Android 17 GMS+GSI 许可](https://developer.android.com/about/versions/17/gsi-release-notes)
- [Android 兼容计划](https://source.android.com/docs/compatibility/overview)
- [Android 17 CDD](https://source.android.com/docs/compatibility/17/android-17-cdd)
- [CTS 17 R1 下载](https://source.android.com/docs/compatibility/cts/downloads)
- [Android Security and Update Bulletins](https://source.android.com/docs/security/bulletin)
- [GMS / Google Play 许可 FAQ](https://source.android.com/docs/compatibility/compatibility-faq)
- [Play Protect 认证说明](https://support.google.com/googleplay/answer/7165974?hl=en)
- [Play Integrity verdict 说明](https://developer.android.com/google/play/integrity/setup)

## 15. 最终建议

如果需求中的“Google 原生”是指**基于 Google/AOSP 官方源码目标、受控构建且不侧载 GMS 的 Android**，立即采用 Android 17 Cuttlefish 官方容器路线。

如果它是指**消费者看到的 Pixel + Play Store + 全部硬件功能**，不要承诺单容器方案；采用“Cuttlefish 容器集群 + 裸机 Google Play AVD + 物理 Pixel 池”，或者先取得 Google GMS/OEM 授权并按认证产品重新立项。
