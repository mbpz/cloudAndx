# CloudAndx 项目约束

## Docker Android 远程管理

- 本地远程界面最低基线为官方 **scrcpy 4.0**（Apache-2.0，tag `v4.0`，提交 `2322868`）；本机已验证版本为 4.1。直接连接 Compose 仅绑定在 `127.0.0.1` 的 ADB 端口，scrcpy client/server 必须同版；不得向局域网或公网暴露 ADB server、scrcpy socket 或任意 shell。
- 单设备本地运行不引入租约 Controller。设备生命周期由标准 Docker Compose 管理；健康、截图、触控、按键、文本输入、应用及设备操作复用 `services/device-bridge` 的受限 API。未来引入多用户、排队或租约时再单独设计控制面。
- 禁止向 WebKVM、浏览器或远程用户暴露 Docker Socket/API、容器 Shell、宿主机 Shell、未鉴权的 ADB、Emulator gRPC、`/dev/kvm` 或宿主网络管理能力。
- 跨主机远程入口必须经过身份认证和授权，使用 SSH、VPN 或零信任通道；访问令牌不得写入镜像、源码、URL、持久化存储或日志。
- Compose 默认端口继续绑定 `127.0.0.1`。需要跨主机访问时，只能通过受控的 HTTPS 反向代理、VPN 或零信任网关发布 WebKVM，不得直接把内部控制端口绑定到 `0.0.0.0`。
- scrcpy 集成不得改变 Android 镜像来源、摘要校验、运行时架构、KVM/TCG 选择、持久化卷或现有 fail-closed 门禁；远程管理层不能绕过 Compose 和证据门禁启动未验证的 Android 运行时。
- 新增或修改跨主机远程管理能力时，必须同时覆盖：未授权访问拒绝、权限边界、输入操作、断线重连、容器重启恢复及敏感信息不落盘测试，并更新 README 和相关架构/验收文档。

## 实施原则

- 本机交互直接使用 scrcpy 4.0 或更高版本；自动化与诊断继续复用 Device Bridge 的鉴权和白名单边界，不引入浏览器 Dashboard 或第二套设备控制逻辑。
- 项目若引入 scrcpy server/client 制品，必须固定到同一明确版本及审核后的 SHA-256，禁止使用 `latest`、`master` 或不同版本的 client/server 组合。
