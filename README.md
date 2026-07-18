# Google Android 17：纯 Docker 运行方案

这套实现只需要 Docker/Compose。它不会安装本机 Android SDK，不会调用或修改
OrbStack，不会改 macOS 的网络、DNS、路由、防火墙、虚拟化设置或其他系统环境。
运行时只创建当前项目的 Docker 镜像、容器、网络和命名卷；所有宿主端口仅绑定
`127.0.0.1`。

系统镜像固定为 Google 官方 Android 17 base final/stable release 的 API 37.0 Google
Play PS16K arm64-v8a r06，包含 Google Play Store 和 Google Play services。Google 已于
[2026-06-16 正式发布 Android 17](https://developer.android.com/blog/posts/android-17-is-here)。
Android 17 QPR1 仍为 Beta，因此不在当前 pin 中。产品发布状态与 SDK repository
`channel-0`（文本值 `stable`）是两项独立证据，不能由其中一项推断另一项。Google
Linux Emulator SDK 资源包固定为 36.6.11，实际执行的 native AEMU 源码 revision 固定为
37.1.7，Platform Tools 固定为 37.0.0；下载文件均校验 Google 仓库公布的 SHA-1。

当前默认且已进入本机验收范围的是 **ARM64 Docker Engine**。在 ARM64（包括 Apple
Silicon 上的 OrbStack Docker Engine）上，amd64 容器用户态只提供固定的 SDK、ADB
和代理工具；entrypoint 绕过会拒绝 ARM64 AVD 的 x86_64 launcher，直接执行从 Android
Emulator 官方源码固定版本构建的 native AArch64 runner。guest 同样是 Google 官方
arm64-v8a r06，system/vendor 镜像不修改。ARM64 路径固定使用软件执行，不映射 KVM。
x86_64 host 构建和运行验证当前 deferred；控制面在该架构上失败关闭，不把尚未构建、
尚未验证的 fallback 声明为可运行。

## 启动

先查看 [Android SDK 许可条款](https://developer.android.com/studio/terms)，再用一次性
环境变量确认本次本地构建（不会写入本机全局环境）：

```sh
./androidctl doctor
./androidctl preflight
ACCEPT_ANDROID_SDK_LICENSES=yes ./androidctl up
```

也可以复制 [.env.example](.env.example) 为工作区内的 `.env`，将
`ACCEPT_ANDROID_SDK_LICENSES` 改为 `yes`。首次构建会在 Docker 内编译固定源码的
ARM64 AEMU，并下载完整的官方 ARM64 系统镜像。x86_64 host 构建与 `up-kvm` 运行验证
当前 deferred，待切换到 x86_64 电脑后执行；本机不会尝试编译或运行 x86 AEMU。

启动后：

- 控制台：<http://127.0.0.1:8080>
- 租约与能力 API：<http://127.0.0.1:18081>
- 受限设备控制 API：<http://127.0.0.1:8090>
- ADB：`127.0.0.1:5555`
- Emulator gRPC：`127.0.0.1:8554`

控制台支持屏幕截图、点击、Android 导航键和安全文本输入。变更设备状态需要本地
bearer token；运行 `./androidctl token` 后只把它粘贴到控制台当前标签页，令牌仅
保存在该标签页的 `sessionStorage` 中，关闭标签页即清除，也不会写入镜像。

常用命令：

```sh
./androidctl status
./androidctl shell getprop ro.build.version.release
./androidctl adb install /data/app.apk
./androidctl verify-runtime
./androidctl logs emulator
./androidctl down       # 保留 Android 数据
./androidctl destroy    # 删除本项目容器和命名卷
./androidctl test       # 全部离线测试均在 Docker 内运行
```

## ARM64 / OrbStack 执行边界

ARM64 路径不是把整个 Google Emulator 再套一层 qemu-user，也不让 x86_64 launcher
解析 ARM64 AVD。amd64 容器 entrypoint 直接执行带独立 AArch64 loader/共享库闭包的
native runner，由它启动原生 `qemu-system-aarch64-headless`。运行时 preflight 校验
bundle 的 SHA-256 清单，健康检查核对实际
`/proc/*/exe`，再要求 ADB、`sys.boot_completed`、API 37、Play Store 与 GMS 全部通过。
由于 Linux AArch64 AEMU 的 `gic-version=host` 和 `-cpu host` 默认都依赖 KVM，
软件执行路径会在所有 Android/图形参数之后强制追加
`-qemu -machine gic-version=3 -cpu cortex-a57`，并拒绝用户注入另一个 `-qemu`。
`androidctl` 只在 ARM64 Docker Engine 上选择 `hybrid-aemu-arm64`；x86_64、缺失和
未知架构组合一律失败关闭。

Compose 只创建当前项目的 IPv6 Docker bridge，供 AEMU 虚拟 modem 使用；不会修改
OrbStack 配置，也不会改 macOS 的 DNS、路由、防火墙或其他网络设置。ARM64 上
`up-kvm` 和 `preflight-kvm` 仍会在探测或映射 `/dev/kvm` 之前失败关闭。

`up-kvm` 与 `preflight-kvm` 目前是保留命令，均在读取或映射 `/dev/kvm` 前失败关闭；
只有未来在 x86_64 硬件上完成独立构建和验证后，才能重新声明该路径。

## 实现内容

- `docker/emulator/`：官方 Emulator、Google Play AVD、持久化数据、ADB/gRPC 代理、
  软件/KVM 加速选择和严格启动健康检查。
- `services/evidence-gate/`：实时验证 Google 仓库中的 package path、tag、revision、
  URL、checksum、架构与 KVM，原子保存证据。
- `services/controller/`：单设备租约、幂等 API、原子持久化、容量限制、能力矩阵与
  Prometheus metrics；只有真实设备新鲜探针通过才报告 `RUNNING`。
- `services/device-bridge/`：无任意 shell 的 allowlist API，覆盖截图、APK、应用列表、
  logcat、触控、按键、GPS、短信、来电、网络、电量、旋转和重启。
- `docker/dashboard/`：设备画面、交互控制、会话、平台事实和能力边界。
- `compose.yaml` / `compose.kvm.yaml`：默认 ARM64 guest/AEMU 软件执行路径、失败关闭且
  延后验证的 x86_64 路径，以及仅限项目范围的 IPv6 bridge。

## “Google 原生体验”的准确含义

Android Emulator 可以达到“Google 官方虚拟设备的软件体验”，但不能达到“Pixel
真机全部功能”。这套镜像是 Google 发布的 Google Play AVD 软件栈，因此 Android
UI、Framework、Play Store、Play services、账号登录和大多数应用 API 都是 Google
原版；Emulator/AVD 仍是一台虚拟设备，不是 Pixel 真机。

以下能力只能模拟或明确阻断：真实运营商基带/eSIM/IMS、NFC 安全元件、UWB、真实
相机 ISP、物理生物识别链路、TEE/StrongBox、硬件级 Play Integrity、Widevine L1、
部分银行/DRM 应用以及 Pixel 专属硬件与 AI 功能。Google 账号、Play 商店地区和服务
可用性仍受网络、账号及 Google 服务政策约束。

## 设计与机器可读契约

- [总体架构与功能边界](docs/android-17-container-architecture.md)（扩展部署参考，不是当前 OrbStack 运行说明）
- [生产运行时契约](docs/android-17-production-runtime-contract.md)（扩展部署参考）
- [验收与证据契约](docs/android-17-acceptance-contract.md)
- [Host Agent OpenAPI](contracts/host-agent-api.openapi.yaml)
- [镜像身份 Schema](contracts/android-image-manifest.schema.json)
- [能力证据 Schema](contracts/android-capability-evidence.schema.json)
