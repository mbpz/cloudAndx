# Android 17 三池方案验收与证据契约

> 契约版本：1.0.0
> 基线日期：2026-07-17
> 适用形态：Android 手机
> 上位设计：[Google 原生 Android 17 容器化运行方案](android-17-container-architecture.md)
> 运行时契约：[Android 17 Cuttlefish 生产运行时契约](android-17-production-runtime-contract.md)

## 1. 契约目的

本契约定义怎样证明以下设计目标，而不把“写过文档”或“单次启动成功”误当成交付证据：

1. 运行的是验收时 Google 已正式发布的最新稳定 Android；
2. AOSP、Cuttlefish、host package、OCI 与派生镜像身份可追溯且不冒充 Google 签名；
3. Android 主运行池确实通过官方 Cuttlefish 容器外壳和 KVM/crosvm 运行；
4. Android 软件、GMS/Play 与真实硬件能力分别由正确资源池证明；
5. “完整”是版本化能力目录中所有适用条目均有有效证据，而不是单容器模拟全部硬件；
6. 许可、隔离、可靠性、容量和运维条件均为 fail-closed 发布门禁。

本文是**可执行验收设计**，不是已经产生的运行结果。没有实际 KVM、AVD、Pixel 和授权证据时，平台状态只能是 `DESIGN_READY`，不能标记为 `DELIVERED`。

## 2. 权威制品

每次候选发布必须生成并内容寻址保存以下制品：

| 制品 | 机器约束 | 用途 |
|---|---|---|
| Image Manifest | [`android-image-manifest.schema.json`](../contracts/android-image-manifest.schema.json) | 最新版本观察、官方来源、派生身份、guest/host/OCI 版本元组、补丁、SBOM、provenance、许可和晋级门禁 |
| Capability Evidence Bundle | [`android-capability-evidence.schema.json`](../contracts/android-capability-evidence.schema.json) | 每个能力的范围、资源池、支持级别、前置条件、测试、结果、证据、有效期与完整性聚合 |
| Host Agent API | [`host-agent-api.openapi.yaml`](../contracts/host-agent-api.openapi.yaml) | 限定生产节点仅接受固定高层设备规格 |
| Runtime Evidence | 运行时契约 Gate 0–7/G 的不可变输出 | 证明最小权限 OCI、KVM/crosvm、网络、恢复和清理路径 |
| Authorization Record | Image Manifest 中的 authorization scope | 证明 GMS/Play 的用途、SKU、地区、用户、期限与再分发范围 |
| Pixel Matrix | Capability Bundle 中的 `device_sku` 或 `sku_region_carrier` scope | 证明物理硬件能力对应具体实体，而非泛化到全部 Pixel |

证据 URI 必须指向不可变对象；同时记录摘要、媒体类型、生产者、产生/采集时间和有效期。可变 Wiki 页面、截图文件名、CI “绿色”链接或人工口头确认不能单独作为发布证据。

## 3. 状态模型与 fail-closed 聚合

平台发布状态只有以下值：

| 状态 | 含义 |
|---|---|
| `DESIGN_READY` | 架构、契约和 schema 已完成，但未运行全部门禁 |
| `CANDIDATE` | 制品已固定，正在生成运行证据 |
| `AOSP_READY` | Cuttlefish 主池全部适用门禁通过，但不声明 GMS 或真实硬件完整性 |
| `TEST_GMS_READY` | AOSP_READY，且 Android 17 Play 测试镜像、许可范围和 GMS 测试门禁通过 |
| `FULL_MATRIX_READY` | AOSP_READY，且冻结业务范围内的 GMS 与 Pixel 实体矩阵全部有有效证据 |
| `INCOMPLETE` | 至少一个适用能力缺失、失败、重复、过期或 N/A 无效 |
| `REJECTED` | 来源、许可、隔离或不可满足的单容器要求触发固定否决 |

整体完整性算法：

1. 读取已签名 capability catalog 的唯一 `capability_ids` 集合 `C`。
2. 以 `capability_id + target_scope` 为键连接 evidence bundle；重复记录立即失败。
3. 对每条记录检查前置条件、测试 procedure 版本、expected result、证据摘要和有效期。
4. `PASS` 只在实测结果满足 expected result 时计入；`NOT_SUPPORTED`、`FAIL`、`BLOCKED` 不计入完整覆盖。
5. `NOT_APPLICABLE` 必须包含范围、权威依据、批准人、复核日期和到期时间；过期或缺字段即无效。
6. 只有 missing、duplicate、stale、invalid-N/A、failed 五个集合都为空时，`completeness.status` 才能为 `complete`。
7. Schema 校验通过仅证明结构正确，不会自动把结果提升为 `PASS`。

若合同要求“同一个通用容器同时提供完整 GMS、真实基带/TEE/DRM/射频能力和合法第三方交付”，聚合器必须直接输出 `REJECTED: SINGLE_CONTAINER_REQUIREMENT_IMPOSSIBLE`。

## 4. 动态最新稳定版本门禁

### 4.1 权威来源

版本观察器至少每日读取并存证：

- Android Developers 正式发布公告/版本页；
- AOSP build numbers/tag 表；
- AOSP manifest/tag 与 Cuttlefish 构建制品元数据；
- Android Security Bulletin。

### 4.2 判定算法

1. 只接受标记为正式发布或 stable 的 major Android 版本；Developer Preview、Beta、QPR Beta 和 Canary 不参加生产 latest 比较。
2. 从至少两个官方来源解析 major、API、stable tag、build ID、发布日期和安全补丁日期。
3. 两个来源不一致、任一来源不可用或解析器不识别新格式时，状态为 `BLOCKED_SOURCE_DISAGREEMENT`，不得沿用缓存结果静默通过。
4. 保存原始响应摘要、HTTP 获取时间、解析器版本、规范化结果和决策摘要；观察证据默认 24 小时过期。
5. Image Manifest 的 Android version/API/tag 必须与观察结果一致；客体 `ro.build.version.sdk`、fingerprint 和 security patch 再与 Image Manifest 一致。
6. 新稳定 major/API/tag 发布后 24 小时内，旧 major 停止以 `latest` 接受新会话，只能进入显式兼容池；新版本在通过全部适用门禁前保持 `CANDIDATE`。

截至本契约基线日，观察值应为 Android 17、API 37、`android-17.0.0_r1`。这是带时间戳的基线，不是永远硬编码的真值。

## 5. Google/AOSP 来源与镜像身份门禁

Image Manifest 必须同时证明：

- 受信官方 URI、AOSP tag、manifest commit、target、ABI 和 build ID；
- guest digest、同 build 的 `cvd-host_package` digest、crosvm/host binaries digest；
- 目标架构 OCI **platform manifest digest**，不能只记录 tag 或多架构 index；
- kernel/GKI、WebRTC assets、构建工具链、source date epoch 和可复现记录；
- SBOM、provenance/attestation、漏洞报告和签名验证；
- AVB/OTA/release key 的公开身份或证书摘要，不包含私钥；
- GMS/Play 的存在或不存在以及对应授权状态。

身份分类只有三类：

- `google_binary`：必须有 Google 官方 artifact 与签名/摘要证据；
- `aosp_unmodified_source_build`：官方源码构建，使用组织构建环境和签名；
- `aosp_derived_source_build`：官方源码派生，必须列出补丁、backport 和组织签名身份。

后二者只能表述为“Google/AOSP 官方源码派生、组织构建/签名”，不能表述为 Google 签名镜像、Pixel 镜像或 Google 认证产品。

## 6. Cuttlefish 容器主路径门禁

生产必须证明唯一链路：

```text
K8s Controller -> node-local Host Agent -> OCI runtime -> Cuttlefish/crosvm -> KVM guest
```

Google Cloud Orchestrator 只允许 Phase 1 隔离 PoC。生产门禁必须证明生产和灾备节点上均不存在其进程、Docker-socket 控制链或持久状态。

最小通过条件：

- OpenAPI create/get/delete/reconcile 幂等、冲突和恢复语义通过；任意 command、env、mount、device path 或 Cuttlefish flag 均无法由 API 注入；
- host/guest 制品只读，会话 runtime、overlay、userdata 与日志逐设备可写且配额化；
- rootfs 只读、`noNewPrivileges`、capability 全 drop、固定 seccomp/LSM、crosvm sandbox 生效；
- `/proc/<pid>/exe` 与 maps 证明所有 Cuttlefish 子进程和加载库来自固定 artifact set；
- x86 v1 一节点一 VM/host-container；ARM64 多容器只有并发 PoC 通过后开放；
- 不可信 GPU 默认 SwiftShader，硬件 GPU 只有独占设备/IOMMU/reset domain 或经过证明的强隔离路径才能开放；
- 节点重启、Controller 断连、Agent 重启和中途删除后，账本、现实资源与 CR 能完成三方对账；
- 逆序清理后进程、mount、TAP/netns、vsock CID、端口、cgroup、设备授权、密钥和数据残留均为零。

## 7. 能力目录最小覆盖面

Phone catalog 至少包含以下类别；产品需求、CDD、公开 API、镜像 feature 声明或 Pixel SKU 引入的新能力必须追加，不能因为下表未列出而忽略：

| 类别 | 主要证明池 |
|---|---|
| Framework/API、ART、System Server、权限、存储、通知、后台执行 | Cuttlefish |
| System UI、Settings、Launcher、显示、触控、键盘、无障碍 | Cuttlefish + 适用 Pixel 复验 |
| GLES/Vulkan、编解码、音频、摄像头、屏幕旋转/多显示 | Cuttlefish 专项 + Pixel 硬件 |
| Wi-Fi、Bluetooth、GNSS、传感器、NFC/HCE | Cuttlefish 模拟 + Pixel 射频/硬件 |
| 电话、短信、SIM/eSIM、IMS、紧急呼叫 | 运营商批准的 Pixel 实验室矩阵 |
| 生物识别、KeyMint、StrongBox、attestation、TEE/SE | 对应认证 Pixel SKU |
| Play services、Play Store、账号、同步、FCM、Billing、应用更新 | 许可允许的 Play AVD + Pixel |
| Play Integrity、Widevine L1/HDCP、Wallet/支付凭据 | 锁定认证 Pixel 与受控测试环境 |
| UWB、卫星、USB、Pixel 专属 AI/相机/云能力 | 实际支持且已下发功能的 Pixel 实体组合 |
| OTA/Mainline、备份恢复、生命周期、安全、可靠性、性能 | 对应主池与物理池专项 |

每个条目必须指定 `real/high_fidelity/simulated/conditional/not_supported/not_applicable`。虚拟 `high_fidelity` 或 `simulated` 结果不能聚合为物理 `real` 结果。

## 8. Android Framework/HAL 量化门禁

每个架构和 runtime profile 至少执行：

- 100 次冷启动、100 次 clean reboot、100 次 powerwash、100 次 APK 安装/卸载，单项 100% 成功；
- 冻结目标负载下 10 轮并发创建/销毁；
- x86_64 与 ARM64 各 24 小时稳定运行；
- WebRTC 每 profile 连续 4 小时，覆盖视频、触控、键盘、音频和网络切换；
- GNSS、Wi-Fi、Bluetooth、NFC 场景各注入 100 次，目标会话 100% 命中、非目标会话零污染；
- GLES/Vulkan、视频播放、旋转、分辨率切换、GPU reset/降级恢复；
- `cts-virtual-device-stable` 零非预期失败，再运行适用 CTS 17 R1、CTS Verifier、VTS 和 STS；所有排除项有模块级理由。

稳定测试期间不允许无法解释的 kernel panic、crosvm crash、System Server 重启、端口/vsock/TAP 冲突或资源残留；进程 RSS/文件描述符相对稳定基线漂移不超过 2%。任何失败都必须进入 capability result，不能以总体 CTS 绿色掩盖专项失败。

## 9. GMS/Play 门禁

### 9.1 镜像可用性

发布时实时读取 SDK repository metadata，固定 `(API, sort, ABI, package revision, source URL, digest, license hash)`。若不存在 API 37 `google_apis_playstore` image：

- Android 17 GMS 能力状态必须为 `BLOCKED_IMAGE_UNAVAILABLE`；
- API 36 Play image 只能进入显式旧版兼容池；
- 不能把 API 36 结果合并进 Android 17 完整性结论。

### 9.2 测试目录

在许可允许的内部测试范围内，分别验证：账号登录/退出、账号同步、Play services 版本/更新、Play Store 安装/更新、FCM 收发、Play Billing 测试购买与恢复、Play 应用更新。使用隔离测试项目、测试账号和非生产付款资料；应用仍可根据模拟器或 Integrity verdict 拒绝运行，这种结果必须如实记录。

### 9.3 授权准入

任何含 GMS 的 artifact/pool 必须绑定有效书面授权记录，至少包括用途、SKU/镜像、地区、用户群、内部测试或第三方交付、再分发权、起止时间、撤销状态和批准责任人。缺失、过期或范围不匹配一律拒绝晋级。公开 GMS+GSI 许可只能支持条款允许的应用兼容性测试，不能推导出云终端分发权。

## 10. Pixel 实体矩阵门禁

物理证据的最小实体键是：

```text
model + SKU + firmware/build + bootloader-lock-state + region
+ carrier + test-SIM/eSIM + account + service-entitlement
```

每项结果只能是 `PASS`、`FAIL`、`NOT_SUPPORTED` 或 `NOT_APPLICABLE`。单一 Pixel、单一运营商或单一地区不得外推为全部覆盖；`NOT_SUPPORTED` 不计入完整覆盖。Pixel 专属功能只有在服务端实际下发、账号有权且目标 SKU/地区支持时才能测试。

紧急呼叫、运营商注册和支付相关测试必须绑定实验室安全批准。紧急呼叫只能在运营商/监管批准的屏蔽实验室或专用测试网络执行，禁止自动化拨打生产紧急号码。

证据有效期默认不超过目标固件或服务版本生命周期；OTA、运营商配置、Play services、DRM policy 或服务 entitlement 变化会使相关记录立即失效并触发复验。

## 11. 安全负面测试

发布前至少执行：

- Host Agent JSON/YAML schema fuzz、属性边界、重复键、重放与乱序请求；
- 越权 image、mount、flag、device、environment、runtime class 和 tenant ID 注入；
- 租户 A 对租户 B 的网络、DNS、ADB、WebRTC、vsock、磁盘、快照、日志和环境控制访问；
- `/dev/kvm`、render node、TAP/netns、cgroup、seccomp、LSM 与 crosvm sandbox 的策略一致性；
- VM/容器逃逸面、恶意 APK 的资源耗尽、磁盘满、PID/FD 耗尽和 GPU hang；
- 销毁并撤销 DEK 后对原始块、快照和日志执行数据恢复尝试；
- 审计事件删除、重排、截断和内容篡改检测。

任一跨租户访问、宿主逃逸、策略绕过、可恢复租户明文或无法检测的审计篡改均为零容忍阻断失败。

## 12. 负载、SLI、HA 与灾备

生产压测前必须冻结：`N_target`、交互/CI/GPU/持久会话比例、每小时平均与峰值创建量、APK/测试负载、网络 RTT/带宽/丢包和存储 profile。没有该合同不能宣布容量通过。

统一 SLI：

- 会话可用性 = 可用会话分钟 / 应服务会话分钟，30 天滚动窗口；只有合同明确且提前公告的维护可排除。
- 启动成功率 = 10 分钟内达到 ADB online、boot completed 和请求入口可用的创建数 / 有效创建请求数；容量拒绝单独计量，不能静默移出分母。
- 启动延迟从 API 接受请求到完整 readiness；分别报告 P50/P95/P99，镜像未缓存样本不能混入缓存 profile。
- 销毁成功率要求 5 分钟内凭证撤销并完成零残留证明。

初始门禁：

- 在 `N_target` 持续运行 24 小时，并以 1.2 倍每小时创建峰值突发 2 小时；
- 交互 profile 在镜像已缓存条件下 boot-complete P95 不超过 90 秒；
- 同地域 WebRTC RTT P95 小于 150 ms；
- 已分配会话月可用性目标不低于 99.9%；
- 控制面 RTO 30 分钟、RPO 5 分钟；短会话不承诺数据 RPO，持久 profile 必须单独声明并验证；
- 完成 Controller 主实例故障、存储故障、Agent 重启、节点断电、网络分区、容量耗尽、回滚和备份恢复演练。

SLO 必须包含分子、分母、窗口、排除项、数据源和告警阈值；只写“99.9%”而没有计算定义不能通过评审。

## 13. 法律与合规发布门禁

除 GMS 书面授权外，发布清单必须覆盖：

- AOSP 与第三方开源许可证 notice；
- 适用 GPL/LGPL 源码、修改与构建材料提供义务；
- Google/Android/Pixel/Play 商标和品牌使用范围；
- 出口管制、制裁与密码产品要求；
- Google 账号、遥测、日志、录屏、音频、位置和测试 SIM 数据的隐私与数据驻留要求；
- 授权到期、撤销、地区变化或合同终止后的停止新建、隔离、删除和通知流程。

每个批准记录必须有责任人、适用范围、证据摘要、签发与到期时间；控制面根据范围执行准入，不能只依赖人工 runbook。

## 14. 证据生命周期

- 版本观察证据：24 小时；
- 安全补丁/漏洞证据：随新 ASB、在野利用或相关 KVM/crosvm/GPU 公告立即失效；
- RuntimeTuple 任一 digest、内核、驱动、策略或工具链变化：全部相关运行证据失效；
- GMS package/license/authorization 变化：全部相关 GMS 证据失效；
- Pixel OTA、SKU、运营商配置、地区、账号或服务 entitlement 变化：相关实体证据失效；
- 测试 procedure 或 capability catalog 版本变化：受影响条目重新运行。

失效不会自动降级为“上次通过”；聚合状态立即变为 `INCOMPLETE`，直到新证据晋级。

## 15. 设计完成与实际交付判定

本设计包在以下条件下可判定为**设计完成**：

- 主架构、生产运行时契约、Host Agent OpenAPI、Image Manifest schema 和 Capability Evidence schema 相互一致；
- 单容器不可满足项、GMS 许可边界和物理硬件边界没有被隐藏；
- 每个原始目标都有明确资源池、机器门禁、失败状态和证据路径；
- 所有 schema/契约通过语法、引用和交叉一致性检查。

实际平台只有在目标环境中生成全部证据并通过本契约后，才可标记为 `AOSP_READY`、`TEST_GMS_READY` 或 `FULL_MATRIX_READY`。当前工作区没有 Linux KVM 节点、Google 授权记录或 Pixel 实验室结果，因此只能证明设计完成，不能声称 Android 平台已部署或“全部功能已经运行”。
