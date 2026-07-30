# CloudAndx 项目约束

## Docker Android 远程管理

- 默认运行拓扑必须始终只有一个 `android` 运行容器和一个最终运行镜像。noVNC、WebSocket/VNC bridge、ReDroid 16、ADB 入口、Device Bridge 和证据门禁必须在该容器内由同一 fail-closed 入口监督；不得为远程界面恢复 sidecar 或辅助运行容器。
- 浏览器交互界面固定使用官方稳定版 **noVNC 1.7.0** 和 **websockify 0.13.0**，版本与 SHA-256 必须锁定，禁止使用 `latest`、分支或未校验下载。浏览器必须能看到 Android 实时画面，并支持鼠标点击、拖动/滑动、键盘和断线重连；仅提供静态截图不算完成。
- noVNC 默认入口必须使用 HTTPS/WSS 加密，并在持久化数据卷中保存独立的 TLS 证书与私钥；除隔离的自动化测试外禁止回退到 HTTP/WS 明文传输。
- noVNC 的显示源必须连接同一 ReDroid Android 实例。实现时必须提供经过验证的实时显示/输入 bridge，禁止用空桌面、周期截图或另一台 Android 实例冒充实时交互。
- 本地远程界面最低基线为官方 **scrcpy 4.0**（Apache-2.0，tag `v4.0`，提交 `2322868`）；本机已验证版本为 4.1。直接连接 Compose 仅绑定在 `127.0.0.1` 的 ADB 端口，scrcpy client/server 必须同版；不得向局域网或公网暴露 ADB server、scrcpy socket 或任意 shell。scrcpy 必须在设备 ready 后快速建立视频与控制 socket，支持鼠标操作；ARM TCG 下不得依赖上游客户端固定 10 秒连接窗口而稳定失败。
- 单设备本地运行不引入租约 Controller。设备生命周期由标准 Docker Compose 管理；健康、截图、触控、按键、文本输入、应用及设备操作复用 `services/device-bridge` 的受限 API。未来引入多用户、排队或租约时再单独设计控制面。
- 禁止向 noVNC、浏览器或远程用户暴露 Docker Socket/API、容器 Shell、宿主机 Shell、未鉴权的 ADB、binder/ashmem/DMA-BUF 设备或宿主网络管理能力。
- 跨主机远程入口必须经过身份认证和授权，使用 SSH、VPN 或零信任通道；访问令牌不得写入镜像、源码、URL、持久化存储或日志。
- Compose 默认端口继续绑定 `127.0.0.1`。noVNC 的 HTTPS/WSS 入口也必须绑定回环地址。需要跨主机访问时，只能通过受控的 HTTPS 反向代理、VPN 或零信任网关发布 noVNC，不得直接把内部控制端口绑定到 `0.0.0.0`。
- Android 基线固定为 ARM64-only ReDroid 16 镜像 `redroid/redroid@sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b`。scrcpy 集成不得改变镜像来源、摘要校验、ARM64 运行架构、持久化卷或现有 fail-closed 门禁；远程管理层不能绕过 Compose 和证据门禁启动未验证的 Android 运行时。
- 项目只使用 Docker Engine/CLI 与 Docker Compose 作为运行时入口；项目脚本、CI 和文档不得调用、安装、启动或硬编码 Colima、OrbStack 或其他 provider CLI，也不得自行切换 Docker context。Docker server 必须提供 ARM64 Linux、4 KiB 页、IPv6、ashmem、binderfs 及 DMA-BUF heaps；启动 Android 前必须由 `scripts/check-redroid-host.sh` fail closed 校验这些能力，宿主基础设施另行保证跨 VM/主机重启恢复。能力不满足时必须拒绝启动，不得删除设备挂载或降级成截图链路。
- 新增或修改跨主机远程管理能力时，必须同时覆盖：未授权访问拒绝、权限边界、输入操作、断线重连、容器重启恢复及敏感信息不落盘测试，并更新 README 和相关架构/验收文档。

## 实施原则

- 本机交互直接使用 scrcpy 4.0 或更高版本；浏览器交互使用 noVNC。两者必须控制同一 Android 实例，并复用同一输入语义；自动化与诊断继续复用 Device Bridge 的鉴权和白名单边界，不引入第二套生命周期 Controller。
- 项目若引入 scrcpy server/client 制品，必须固定到同一明确版本及审核后的 SHA-256，禁止使用 `latest`、`master` 或不同版本的 client/server 组合。
- noVNC 与宿主 scrcpy 是两个可分别选择的完整交互入口：用户只启动其中任意一个客户端时，都必须能独立完成画面、点击、长按、拖动/滑动和键盘操作；两者必须连接同一个 Android serial。一个入口断开不得关闭 Android，也不得阻止另一个入口继续连接。实时性能档的 noVNC 不得依赖宿主 scrcpy 客户端；若使用容器内显示 bridge，该 bridge 必须由同一入口监督并通过首帧门禁。
- “真机级体验”只能在 `realtime` 性能档声明，并必须由目标宿主实测证明：Android 冷启动到双入口 ready 的 P95 不超过 60 秒；点击到首个可见响应 P95 不超过 100 ms；连续拖动/滑动 P95 输入到画面延迟不超过 100 ms；稳定输出至少 30 FPS；30 分钟交互测试无黑屏、输入丢失或非预期重连。未达到任一指标均不得使用“丝滑”“真机级”或“生产就绪”表述。
- `realtime` 档必须 fail closed 校验 ARM64 同架构原生执行以及经过验证的 GPU/render 路径。不得把 x86 转译、ARM TCG 或纯截图链路作为性能验收环境；noVNC、scrcpy 或 WebRTC 协议优化不能替代运行时和渲染器性能。
- “完整 Android 16”在本项目中指固定 Android 16、SystemServer/Framework、应用安装运行、网络、音频、相机模拟、定位/传感器模拟、持久化与双入口控制均通过版本化能力测试。ReDroid 基础镜像是 AOSP，不得声称自带 Google Play Store、Google Play services 或 Play 认证；只有在具备合法分发授权且制品经过固定摘要与能力测试后才可加入。虚拟容器不能声称具备真实基带、SIM/eSIM、NFC/SE、TEE/StrongBox、Widevine L1、Play Integrity 物理设备 verdict 或真实摄像头/传感器；要求这些能力时必须使用认证物理设备池。
