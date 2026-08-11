# CloudAndx 稳定运行架构

## 定稿结论

Apple Silicon 本机的长期支持和性能默认路径是 **macOS 原生 Android Emulator**。它以
Hypervisor.Framework 和宿主 `-gpu host` 运行 ARM64 AVD，并由同版 scrcpy 4.1 控制同一
设备。当前 M1 + OrbStack Docker VM 不具备让容器 Android 达到相同图形和交互性能的
硬件/内核能力。

```text
macOS（默认、本机实时交互）
  └─ native-android17.sh
      └─ Android Emulator ARM64
          ├─ Hypervisor.Framework + -gpu host
          ├─ 127.0.0.1 ADB 5557 / gRPC 8556（token）
          └─ Emulator 原生窗口或 scrcpy 4.1

Docker（显式兼容/证据，不承诺实时或原生等效）
  └─ docker compose --profile docker-compat
      └─ 单个 android 容器、唯一最终镜像
          ├─ ARM TCG + SwiftShader
          ├─ loopback ADB / HTTPS noVNC / Device Bridge
          └─ 同一受监督 Android 实例
```

Docker 兼容 topology 仍严格只有一个 `android` 运行容器和一个最终运行镜像；noVNC、
websockify、AEMU、ADB 代理、Device Bridge 和证据门禁都在该容器内由同一 fail-closed
入口监督。所有发布端口均绑定 `127.0.0.1`；不发布 raw VNC、Docker socket、Shell、ADB
server、scrcpy socket、KVM 或 Emulator gRPC 到局域网或公网。

## 为什么不采用当前 OrbStack ReDroid

截至 2026-08-11，本机 OrbStack 7.0.11 缺少 `/dev/kvm`、`/dev/dri`、DMA-BUF system
heap、ashmem 与 binderfs。ReDroid 12 因缺失 compat mmap sysctl 直接退出；14/15 虽可部分
启动但出现黑屏或没有编码器；16 在补齐 device-mapper、ext4 与 Binder 权限后仍以
`output buffer not gpu writeable` 终止 SurfaceFlinger。软件 `guest` GPU 不能弥补这些
host 能力，也不符合本机原生流畅度目标。

详细的版本矩阵和复测条件见
[OrbStack ReDroid 可行性复测](orbstack-redroid-feasibility-2026-08-11.md)。早期在具备
不同内核能力的 ARM64 Linux Docker server 上获得的 ReDroid 证据仅供历史回溯，不能作为
当前 M1 OrbStack 的部署或性能结论。

## 发布与验收门禁

- 默认启动不得隐式运行 Docker：`android` 仅由 `docker-compat` profile 选择。
- Docker 兼容路径必须保持单容器、loopback 端口、HTTPS/WSS noVNC、固定 noVNC 1.7.0、
  websockify 0.13.0、scrcpy 4.1 和受限 Device Bridge。
- 原生路径必须验证 Hypervisor.Framework、`-gpu host`、loopback ADB/gRPC 与 scrcpy 4.1。
- 任何未来声称 Docker/容器 Android 达到实时或“丝滑”的变更，都必须在目标宿主重新实测：
  启动、稳定图形、编码、输入、断线重连、重启恢复和 P95 延迟；历史证据与单次 splash
  画面不构成验收。

## 能力边界

原生 Emulator 和 Docker 兼容路径都不替代已认证物理设备：真实基带、SIM/eSIM、NFC/SE、
TEE/StrongBox、Widevine L1、物理传感器以及 Play Integrity physical verdict 均不在本项目
保证范围内。跨主机访问仍必须通过 SSH、VPN 或零信任通道受控转发；不得直接改 Compose
端口到 `0.0.0.0`。
