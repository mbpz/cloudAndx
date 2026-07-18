# Google Android 17：纯 Docker 运行方案

这套实现只需要 Docker/Compose。它不会安装本机 Android SDK，不会调用或修改
OrbStack，不会改 macOS 的网络、DNS、路由、防火墙、虚拟化设置或其他系统环境。
运行时只创建当前项目的 Docker 镜像、容器、网络和命名卷；所有宿主端口仅绑定
`127.0.0.1`。

系统镜像固定为 Google 官方发布的 Android 17 / API 37.0 Google Play PS16K
x86_64 r06，包含 Google Play Store 和 Google Play services。Emulator 固定为
36.6.11，Platform Tools 固定为 37.0.0；下载文件均校验 Google 仓库公布的 SHA-1。

运行前提是 **Linux x86_64 Docker Engine**。推荐使用宿主已经具备的 `/dev/kvm`；
脚本只把该设备映射进容器，不安装驱动、不改变权限，也不配置宿主虚拟化。Google
当前没有发布 Linux ARM64 Emulator，因此 Apple Silicon 上的 ARM64 OrbStack 不能在
这些限制下运行这套 Google Play AVD。

## 在受支持的 x86_64 Linux 主机上启动

先查看 [Android SDK 许可条款](https://developer.android.com/studio/terms)，再用一次性
环境变量确认本次本地构建（不会写入本机全局环境）：

```sh
./androidctl doctor
./androidctl preflight
ACCEPT_ANDROID_SDK_LICENSES=yes ./androidctl up-kvm
```

也可以复制 [.env.example](.env.example) 为工作区内的 `.env`，将
`ACCEPT_ANDROID_SDK_LICENSES` 改为 `yes`。完整系统镜像下载约 2.31 GB。如果原生
x86_64 Linux 主机没有 KVM，可用 `./androidctl up` 显式运行 `-accel off` 软件模式；
它很慢，只适合验证，不是推荐部署方式。

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
./androidctl logs emulator
./androidctl down       # 保留 Android 数据
./androidctl destroy    # 删除本项目容器和命名卷
./androidctl test       # 全部离线测试均在 Docker 内运行
```

## 当前 ARM64 OrbStack 主机的实际结论

当前 Docker Engine 是 ARM64，且容器内没有 `/dev/kvm`。实际全量镜像启动已验证到
Google Emulator 36.6.11 进入 Rosetta 后退出，错误为
`rosetta error: Unimplemented syscall number 282`；Android guest 没有完成启动，因而
也没有 ADB、Play Store 或 GMS 健康证据。

容器内再套 `qemu-x86_64-static` 可以让进程多走一段，但会形成“QEMU user 翻译
x86 Emulator、Emulator TCG 再翻译 Android guest”的双层动态翻译，无法满足完整
功能、稳定性和性能目标，因此没有纳入方案。

`./androidctl up`、`up-kvm` 和 Compose 运行时门禁现在都会在 ARM64 上非零退出，
不会启动 Emulator，也不会尝试修改 OrbStack。`./androidctl doctor` 会报告
`runtime=blocked-requires-native-x86_64-linux`。

在受支持的主机上，`up-kvm` 只用临时 Docker 容器读取 `/dev/kvm` 的组 ID，并把
设备映射给两个非 root 容器；设备缺失或不可用时直接失败，不修改宿主权限或
虚拟化配置。

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
- `compose.yaml` / `compose.kvm.yaml`：原生 x86_64 Linux 软件模式和 KVM 模式；
  另有原生架构门禁，跨架构时失败关闭。

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
