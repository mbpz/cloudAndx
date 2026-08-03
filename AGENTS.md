# CloudAndx 项目约束

## Docker Android 远程管理

- 默认运行拓扑必须始终只有一个 `android` 运行容器和一个最终运行镜像。noVNC、WebSocket/VNC bridge、Android Emulator、ADB 代理、Device Bridge 和证据门禁必须在该容器内由同一 fail-closed 入口监督；不得为远程界面恢复 sidecar 或辅助运行容器。
- 浏览器交互界面固定使用官方稳定版 **noVNC 1.7.0** 和 **websockify 0.13.0**，版本与 SHA-256 必须锁定，禁止使用 `latest`、分支或未校验下载。浏览器必须能看到 Android 实时画面，并支持鼠标点击、拖动/滑动、键盘和断线重连；仅提供静态截图不算完成。
- noVNC 默认入口必须使用 HTTPS/WSS 加密，并在持久化数据卷中保存独立的 TLS 证书与私钥；除隔离的自动化测试外禁止回退到 HTTP/WS 明文传输。
- noVNC 的显示源必须连接同一 Android 实例。当前 headless AEMU/`-no-window` 路径没有可供传统 VNC 捕获的 X11 framebuffer；实现时必须提供经过验证的显示/输入 bridge，或使用 GUI AEMU + Xvfb + VNC 链路，禁止用空桌面、周期截图或另一台 Android 实例冒充实时交互。
- 本地远程界面最低基线为官方 **scrcpy 4.0**（Apache-2.0，tag `v4.0`，提交 `2322868`）；本机已验证版本为 4.1。直接连接 Compose 仅绑定在 `127.0.0.1` 的 ADB 端口，scrcpy client/server 必须同版；不得向局域网或公网暴露 ADB server、scrcpy socket 或任意 shell。scrcpy 必须在设备 ready 后快速建立视频与控制 socket，支持鼠标操作；ARM TCG 下不得依赖上游客户端固定 10 秒连接窗口而稳定失败。
- 单设备本地运行不引入租约 Controller。设备生命周期由标准 Docker Compose 管理；健康、截图、触控、按键、文本输入、应用及设备操作复用 `services/device-bridge` 的受限 API。未来引入多用户、排队或租约时再单独设计控制面。
- 禁止向 noVNC、浏览器或远程用户暴露 Docker Socket/API、容器 Shell、宿主机 Shell、未鉴权的 ADB、Emulator gRPC、`/dev/kvm` 或宿主网络管理能力。
- 跨主机远程入口必须经过身份认证和授权，使用 SSH、VPN 或零信任通道；访问令牌不得写入镜像、源码、URL、持久化存储或日志。
- Compose 默认端口继续绑定 `127.0.0.1`。noVNC 的 HTTPS/WSS 入口也必须绑定回环地址。需要跨主机访问时，只能通过受控的 HTTPS 反向代理、VPN 或零信任网关发布 noVNC，不得直接把内部控制端口绑定到 `0.0.0.0`。
- scrcpy 集成不得改变 Android 镜像来源、摘要校验、运行时架构、KVM/TCG 选择、持久化卷或现有 fail-closed 门禁；远程管理层不能绕过 Compose 和证据门禁启动未验证的 Android 运行时。
- 新增或修改跨主机远程管理能力时，必须同时覆盖：未授权访问拒绝、权限边界、输入操作、断线重连、容器重启恢复及敏感信息不落盘测试，并更新 README 和相关架构/验收文档。

## 实施原则

- 本机交互直接使用 scrcpy 4.0 或更高版本；浏览器交互使用 noVNC。两者必须控制同一 Android 实例，并复用同一输入语义；自动化与诊断继续复用 Device Bridge 的鉴权和白名单边界，不引入第二套生命周期 Controller。
- 项目若引入 scrcpy server/client 制品，必须固定到同一明确版本及审核后的 SHA-256，禁止使用 `latest`、`master` 或不同版本的 client/server 组合。
