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
docker compose config --quiet
ACCEPT_ANDROID_SDK_LICENSES=yes docker compose --profile build build native-engine
ACCEPT_ANDROID_SDK_LICENSES=yes docker compose up -d --build
```

也可以复制 [.env.example](.env.example) 为工作区内的 `.env`，将
`ACCEPT_ANDROID_SDK_LICENSES` 改为 `yes`。首次构建会在 Docker 内编译固定源码的
ARM64 AEMU，并下载完整的官方 ARM64 系统镜像。x86_64 host 构建与 `up-kvm` 运行验证
当前 deferred，待切换到 x86_64 电脑后执行；本机不会尝试编译或运行 x86 AEMU。

默认 Compose 只启动一个 `android` 容器，使用唯一运行镜像
`cloudandx/android17-play-emulator:37.0-r06`。其 PID 1 依次执行兼容性检查、ADB
密钥/Console 令牌初始化和证据门禁，再统一监督模拟器、ADB/gRPC/Console 代理、设备桥接
以及容器内 `scrcpy -> Xvfb -> x11vnc -> websockify/noVNC` 浏览器交互链路。
`native-engine` 仅是显式 `build` profile 使用的跨架构构建制品，不会作为运行容器启动。

启动后：

- 受限设备控制 API：<http://127.0.0.1:8090>
- 浏览器 Android：<https://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale>
- ADB：`127.0.0.1:5555`
- Emulator gRPC：`127.0.0.1:8554`

本机已安装的 scrcpy 4.1 提供 server；项目为 ARM TCG 的慢启动构建一个延长握手等待、仍保持 4.1 协议的本机 client。首次执行构建脚本，之后直接运行连接脚本：

```sh
scripts/build-scrcpy-arm-tcg-client.sh
scripts/scrcpy-android17.sh
```

连接脚本会自动把容器已信任的 ADB 私钥复制到被 Git 忽略的 `.runtime/container-adb/`，因此无需等待 Android 授权弹窗；并默认使用 UHID 鼠标和键盘，让 Android 将输入识别为物理设备。ADB、视频和输入仍只经过 `127.0.0.1`。后续连接直接运行第二条命令即可。

首次访问需要接受项目持久化自签名证书；接受后页面使用 HTTPS/WSS 加密。浏览器中的鼠标点击、拖动和键盘输入由容器内 scrcpy 4.1 注入同一台 Android；noVNC
1.7.0 和 websockify 0.13.0 只发布到宿主回环地址，raw VNC 5900 不发布。
远程 X11 桌面与 scrcpy 的 `320x720` 兼容档编码纹理尺寸一致，scrcpy 使用覆盖整个桌面的无边框窗口；noVNC 强制启用 `resize=scale` 并关闭 `view_only`，Android 画面会随浏览器可视区域自适应缩放，且不会被浏览器缓存的“仅查看”设置禁用输入。统一视频纹理、SDL 窗口和 VNC framebuffer 尺寸可避免鼠标坐标被重复放大。浏览器链路显式使用 scrcpy SDK 鼠标与键盘注入：左键点击和按住拖动按 Android 单指触控语义处理，Mac 触控板双指滚动会转换成连续的按下、移动、抬起手指滑动，不再作为桌面鼠标滚轮发送；视频限制为 30 FPS、零缓冲并使用 4 Mbps 码率，优先保证资源受限的 TCG 环境能够完成首帧。

宿主 scrcpy client/server 必须保持同版。ADB 不对局域网或公网发布；跨主机使用时先通过
SSH/VPN/零信任通道安全转发 6080，不直接把 Compose 端口改为 `0.0.0.0`，也不转发
ADB、raw VNC 或 Emulator gRPC。

常用命令：

```sh
docker compose ps -a
docker compose exec -T android adb -s emulator-5556 shell getprop ro.build.version.release
docker compose exec -T android adb -s emulator-5556 install /data/app.apk
docker compose exec -T android /usr/local/bin/runtime-preflight.sh
docker compose logs --follow --tail 200 android
docker compose down                 # 保留 Android 数据
docker compose down --volumes       # 删除本项目容器和命名卷
```

## ARM64 / OrbStack 执行边界

ARM64 路径不是把整个 Google Emulator 再套一层 qemu-user，也不让 x86_64 launcher
解析 ARM64 AVD。amd64 容器 entrypoint 直接执行带独立 AArch64 loader/共享库闭包的
native runner，由它启动原生 `qemu-system-aarch64-headless`。运行时 preflight 校验
bundle 的 SHA-256 清单，健康检查核对实际
`/proc/*/exe`，再要求 ADB、`sys.boot_completed`、存活的 SystemServer、核心 Binder 服务、
API 37、Play Store 与 GMS 全部通过。
由于 Linux AArch64 AEMU 的 `gic-version=host` 和 `-cpu host` 默认都依赖 KVM，
软件执行路径会在所有 Android/图形参数之后强制追加
`-qemu -machine gic-version=2 -cpu android-a57-16k`，并拒绝用户注入另一个 `-qemu`。
ARM TCG 首次启动还会关闭纯视觉的 boot animation。下载的 Google ZIP 在解压前以
固定 SHA-1 校验，`system.img`、`vendor.img`、kernel 和初始 userdata 种子保持原始
内容；为了让极慢的纯 TCG 启动不被 Android framework watchdog 或 ART 独立的 10 秒
Finalizer watchdog 循环终止，
启动 ramdisk 通过 Android 17 官方 second-stage 属性通道
`/system/etc/ramdisk/build.prop` 只加入 `ro.hw_timeout_multiplier=50` 和与其等比例的
`dalvik.vm.finalizer-timeout-ms=500000`，以及 AOSP Bluetooth HCI 的
`bluetooth.hci.timeout_milliseconds=100000` 和
`bluetooth.hci.restart_timeout_milliseconds=250000`。构建会校验官方
ramdisk 及解压 cpio 的固定 SHA-256，保持原 cpio 为逐字节前缀，并锁定派生 ramdisk
SHA-256。Google `user` 镜像的 SELinux 会阻止 ADB shell 读取通用
`bluetooth_prop`；因此镜像构建和 runtime preflight 校验两项 HCI 属性，guest 健康检查
改为验证公开的 BluetoothManager Binder 服务，避免把正常的访问隔离误判成属性缺失。
因而 Google 签名的 user-build system/GMS 没有改动，但该启动 ramdisk 不再是
Google ZIP 中逐字节原件；要求所有制品完全不变的路径留待 x86_64/KVM 机器验证。
模板标识包含 A57/GICv2/ramdisk-timeout50/finalizer500000/HCI 超时启动契约，因此旧 volume 会失败关闭并要求
重新创建。
原生 AEMU 的 0011 补丁注册隔离的 A57 派生 QOM 类型，只为已有 16 KB TCG 页表实现
声明 TGran16 能力；0012 仅将该类型加入 `mach-virt` 的独立 CPU 白名单；
headless 启动则锁定后置摄像头为 `emulated`，避开无窗口模式下的 virtual-scene
同步初始化，同时保留前后两个软件摄像头。
纯 TCG 首次冷启动会进行大量 userdata 初始化和包优化；项目默认使用 8 个 guest vCPU，
应为 Docker Engine 提供至少 8 个 CPU。在容器仍持续消耗 CPU/块 I/O且没有重启或
OOM 时，不应中断该过程。
Compose 默认锁定当前已验收的 ARM64 `hybrid-aemu-arm64` 路径；x86_64 运行仍未进入
验收范围，不能通过修改架构变量绕过运行时门禁。

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
- `services/device-bridge/`：无任意 shell 的 allowlist API，覆盖截图、APK、应用列表、
  logcat、触控、按键、GPS、短信、来电、网络、电量、旋转和重启。
- `compose.yaml`：默认 ARM64 guest/AEMU 软件执行路径，以及仅限项目范围的 IPv6
  bridge；尚未验证的 x86_64/KVM 路径不进入默认部署文件。

## “Google 原生体验”的准确含义

Android Emulator 可以达到“Google 官方虚拟设备的软件体验”，但不能达到“Pixel
真机全部功能”。这套镜像使用 Google 发布的 Google Play AVD `system/vendor` 软件栈，
因此 Android UI、Framework、Play Store、Play services、账号登录和大多数应用 API
都来自 Google 原版。当前 ARM TCG 路径包含上文明确记录的最小启动 ramdisk 属性覆盖；
Emulator/AVD 仍是一台虚拟设备，不是 Pixel 真机。

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
