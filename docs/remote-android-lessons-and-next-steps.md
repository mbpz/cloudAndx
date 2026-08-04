# 容器 Android 远程交互：现状经验与 Docker 兼容方案

## 决策摘要

当前 OrbStack Docker 不提供 ReDroid 所需的 binder/ashmem/DMA-BUF 宿主设备，
因此默认 Compose 使用可在该 Docker Engine 中实际启动的 Android 17 AEMU 兼容档。
选择边界不是单一编译错误，而是三个条件同时存在：

1. ReDroid 上游公开支持到 Android 16；Android 17 需要移植 device、HAL、
   init、SELinux 和图形适配，不是改一个版本号。
2. 自编译产物是 AOSP，不会自动获得 Google Play Store、GMS 或 Play 认证；
   Google Emulator 的 Play system image 也不能直接转换为 ReDroid rootfs。
3. 完整 AOSP 构建通常需要 x86_64 Linux、大量内存和数百 GB 工作空间；当前
   M1 Mac 的内存、磁盘余量和宿主内核接口都不适合作为 Android 17 构建机。

当前可运行路线固定为：

```text
Apple silicon or ARM64 Linux host
  -> provider-neutral Docker Linux runtime
  -> ARM64 native AEMU + TCG/SwiftShader
  -> Android 17 API 37 Play ARM64 16 KiB image（固定摘要）
  -> 同一 Android 实例
       +-- loopback ADB -> 宿主 scrcpy 4.1
       +-- AEMU event stream -> loopback RFB -> HTTPS noVNC 1.7.0
       +-- 受限 Device Bridge API
```

这条路线已迁入默认 Compose。浏览器桥使用 AEMU 官方按产帧推送的
`streamScreenshot`，不是周期截图；输入使用 `streamInputEvent` 的触控和键盘语义。
noVNC、websockify、grpcurl 和 Android 制品都固定版本/摘要，并由同一 fail-closed
入口监督。ARM TCG 兼容档不满足 realtime 性能门槛，因此不得声明“真机级”或
“生产就绪”。ReDroid 16 仍是满足宿主内核设备后的长期运行路线，不在当前宿主伪降级。

## Android 17 AEMU 的实测经验

### 能做到什么

- 一个容器内可以启动 Google Android 17 API 37.0 Play r06。
- AEMU 的 `streamScreenshot` 在设备产帧时推送 RGB framebuffer，可直接驱动 RFB，
  不依赖 guest MediaCodec 或截图轮询。
- `streamInputEvent` 可把 RFB 的 DOWN/MOVE/UP 与键盘事件送到同一主显示。
- 第一张正确尺寸的 AEMU 帧到达后再创建 ready marker，可避免“容器健康但黑屏”。
- x11vnc 的内建 WebSocket 探测会与外层 websockify 的 raw TCP 后端握手互相等待，
  因此默认链路已删除 x11vnc/Xvfb，而不是继续调参掩盖死锁。

### 为什么仍然不可用

当前 ARM64 Docker runtime 没有为该 AEMU 路径提供 `/dev/kvm` 和可用 GPU render node，最终
执行路径是 ARM TCG 加 SwiftShader。实测结果为：

| 指标 | 结果 |
| --- | --- |
| Android 冷启动 | 约 8–10 分钟 |
| noVNC 点击首个可见变化（优化前） | 约 30–45 秒 |
| 降到 `480x1080@187dpi` 后 | 约 16.2 秒 |
| 直接 ADB 输入或设置命令 | 约 10–12 秒 |

ADB 本身也慢，证明主要延迟在 TCG Android 执行和软件渲染，不是 noVNC
没有发送鼠标事件。继续修改光标、滚轮映射、VNC 压缩或码率，只能改善链路
细节，不能把十几秒的 Android 响应变成 100 ms。

### 已排除的旧方向

- **照搬 budtmo/docker-android**：它的流畅度依赖 Linux KVM；复制
  Openbox/x11vnc 布局不能替代硬件加速。
- **减少虚拟 CPU**：4 核对照比 8 核更慢，且 scrcpy 首帧更不稳定。
- **直接使用 QEMU VNC**：AEMU 的 Android framebuffer 由 goldfish/
  gfxstream 管线管理，标准 QEMU VGA 不能假定为 Android 实时画面。
- **只换 WebRTC**：WebRTC 可减少传输层和缓冲延迟，但无法消除 TCG 内部
  10 秒级应用响应；它不是当前硬件问题的根治方案。
- **继续补 AEMU ARM64 native runner**：即使 launcher 能运行，当前宿主仍
  缺少满足目标体验的 CPU/GPU 加速路径。

## 新方案：ReDroid 16 的实测经验

### 为什么选择 ReDroid

ReDroid 直接把 Android Framework、HAL 适配层和容器宿主内核结合，不再在
容器里运行一层完整的虚拟 CPU。Apple silicon 与 Android 都是 ARM64，因此
避免了 x86 转译和 ARM TCG，解决的是旧方案的主要性能根因。

镜像固定为：

```text
redroid/redroid@sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b
```

使用 `16.0.0_64only` 路线是必要的。普通镜像包含 ARM32 用户态，在 ARM64-only
此前的 ARM64 Linux Docker 内核中触发过 32 位 BoringSSL 自检 `Exec format error`，随后 Android
按 fail-closed 逻辑重启。

### 宿主兼容性试验

| 宿主 | 结果 | 证据 |
| --- | --- | --- |
| ARM64 Linux Docker / 6.8 | 不支持 | binderfs、DMA-BUF 可用，但没有 ashmem；gralloc/SurfaceFlinger 循环崩溃 |
| ARM64 Linux Docker / 5.15 | 通过 | `ASHMEM=m`、`BINDERFS=m`、`DMABUF_HEAPS=y`、IPv6、4 KiB pages 均满足 |
| 在 6.8 编译 redroid ashmem module | 不可行 | `vm_flags`、shrinker 等内核 API 已变化，模块无法直接编译 |

在 6.8 环境中，即使设置 `androidboot.use_memfd=true`、`sys.use_memfd=1` 并
放宽 DMA heap 权限，当前 ReDroid 16 gralloc 仍尝试打开 `/dev/ashmem`，日志
出现：

```text
Unable to open ashmem device
gralloc failed
RenderEngine: output buffer not gpu writeable
```

因此 5.15 不是“为了通过检查而降级”，而是当前镜像图形栈的实际运行条件。

### binderfs 的关键细节

不能用 Docker `--device` 重新创建设备号来代替 binderfs 原始 inode；该方式
实测会出现 `ENXIO`。容器必须 bind mount 宿主 binderfs 中的真实节点：

```text
/dev/binderfs/binder    -> /dev/binder
/dev/binderfs/hwbinder  -> /dev/hwbinder
/dev/binderfs/vndbinder -> /dev/vndbinder
```

ashmem 和 DMA-BUF system heap 则作为字符设备映射。宿主设备由 provider 自己
初始化；`scripts/setup-redroid-host.sh` 只在启动 Android 前执行能力预检，provider
必须另外证明模块加载、binderfs mount 和权限在重启后仍有效。

### 已取得的运行结果

在已验证的 M1 ARM64 Linux provider、8 CPU、8 GB 配置上已观察到：

- ReDroid 返回 `ro.build.version.release=16`；
- `sys.boot_completed=1`；
- SurfaceFlinger 和 system_server 均持续存活；
- 首次验证约 22 秒完成启动，持久化数据后的两次重启分别约 11 秒和 12 秒；
- ADB 仅绑定 `127.0.0.1:5555`，状态为 `device`，没有授权弹窗；
- 宿主 scrcpy 4.1 成功推送同版 server，识别 Android 16，Metal renderer
  输出 `Texture: 1080x1920`；
- 实时 screencap 为 1080×1920，证明图形管线不是黑屏或静态占位图；
- 容器内 scrcpy 4.1 产生 `Texture: 606x1080`，同一画面经 Xvfb/Openbox、x11vnc、
  TLS websockify/noVNC 发布；
- 浏览器点击打开 Gallery、连续拖动打开应用抽屉、键盘输入 `settings` 后
  Android 搜索框显示对应文本；
- 默认 Compose 只有一个 `android` 服务，ADB/noVNC/Device Bridge 分别只绑定
  `127.0.0.1:5555/6080/8090`；
- provider 整机重启后容器恢复为 `healthy`，Android 与三个入口重新可用；
- Device Bridge 未授权写操作返回 401，使用卷内 token 后返回 200。

这些证据证明 Android 16 与双远程入口主路径成立。30 次浏览器点击到首个可见
画面变化的固化配置实测为 min 9.2 ms、median 43.8 ms、P95 85.2 ms、
max 99.5 ms；较旧 AEMU 的 16.2 秒改善超过两个数量级，并达到原定 P95 100 ms
门限。关键是直接在 Chromium noVNC canvas 内观察首个可见帧，避免把外部截图
轮询和 PNG 编码时间混入用户体验指标。Google 服务和全部硬件模拟能力仍不在
当前 AOSP 镜像内。

## 现状问题与对应解决方案

| 现状问题 | 根因 | 新方案处理 |
| --- | --- | --- |
| Android 17 冷启动 8–10 分钟 | ARM TCG | ReDroid ARM64 同架构原生执行 |
| 点击与滑动十几秒才响应 | TCG/SwiftShader 内部执行慢 | 移除 AEMU 虚拟 CPU；浏览器可见变化降至 median 43.8 ms、P95 85.2 ms |
| scrcpy unauthorized/没有弹窗 | AEMU ADB key 与慢 UI 状态 | ReDroid loopback ADB 已直接进入 `device` |
| noVNC 有画面但点击无反应 | 多级输入转译叠加慢 Android | 使用同一 ReDroid 的容器内 scrcpy 4.1 bridge，固定 SDK 鼠标语义并做可见状态验收 |
| noVNC 黑屏 | bridge 首帧未进入 Xvfb | 首帧 marker 纳入健康检查；任一必需进程退出即关闭全部远程面并使容器 unhealthy |
| 某些 ARM64 Docker runtime 不支持 ReDroid | binderfs/ashmem/DMA-BUF 接口不匹配 | 预检失败则拒绝启动；不放宽 Compose 门禁 |
| 6.8 SurfaceFlinger 崩溃 | ReDroid gralloc 仍依赖 ashmem | 固定 Ubuntu 22.04/5.15，不维护脆弱的 6.8 私有模块补丁 |
| Android 17 ReDroid 编译困难 | 上游未支持且构建资源不足 | 产品基线调整到上游成熟 Android 16 |
| Bluetooth 启动后保持 OFF | ReDroid 15/16 的 ASan RootCanal HAL 均在已验证 ARM64 Linux Docker 的 libc/vDSO 路径崩溃 | 明确标记 `not_supported`；拒绝跨版本覆盖，后续只接受无 ASan 同版 HAL、remote RootCanal 或兼容宿主 |

## 已完成与剩余工作

已完成固定 ReDroid digest、单 ARM64 最终镜像、单运行容器、scrcpy 4.1、
Xvfb/Openbox/x11vnc、noVNC 1.7.0、websockify 0.13.0、TLS、Device Bridge 鉴权、
回环端口和 provider 重启恢复。默认 Compose 已切换到 ReDroid 16，不再构建或
运行 AEMU/native-engine。

剩余工作只有可量化的交付门禁：

1. 浏览器输入延迟已达到 P95 85.2 ms；后续把 Chromium canvas 测量器固化为可重复的发布门禁；
2. 已完成 31 分 18 秒、180 次检查、0 失败、0 重启的稳定性基线；后续发布前
   仍需补充长稳和负载场景；
3. 若产品需要 Google Play/GMS，必须取得合法且可校验的 Android 16 GMS
   制品来源，不能把当前 AOSP 镜像改名冒充；
4. 新路线稳定后单独删除旧 `docker/emulator`、native AEMU 和 Android 17
   历史实现；在删除前保留它们作为旧方案证据，不再接入默认 Compose。
5. Bluetooth 若进入交付范围，必须先通过 HAL 存活、Framework ON、扫描、配对和
   重启恢复门禁；现有 M1 ARM64 Docker 环境不把 Bluetooth 纳入已支持能力。

## 能力边界

ReDroid 官方基础镜像是 AOSP Android 16，不等于 Google Play 认证设备。
Google Play Store、GMS、Widevine L1、Play Integrity 物理设备 verdict、真实
基带、SIM/eSIM、NFC/SE、TEE/StrongBox 和真实传感器不能从当前 PoC 推断。
如产品硬性要求 Play 认证或真实硬件安全能力，应使用经过授权的系统制品或
认证物理 Android 设备池，而不是重新包装未经授权的 Google 镜像。
