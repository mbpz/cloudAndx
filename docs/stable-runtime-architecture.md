# CloudAndx Android 16 稳定运行方案

## 定稿结论

长期支持路径是 ARM64-only ReDroid 16 + 单个 `android` 容器。宿主 scrcpy 和浏览器
noVNC 是两个独立客户端，共享同一个 `127.0.0.1:5555` Android serial；任一客户端
断开都不能停止 Android 或另一入口。

```text
选定 Docker Linux runtime
  └─ ARM64 + 4 KiB + IPv6 + ashmem + binderfs + DMA-BUF（启动前 fail closed）
      └─ cloudandx/android16-redroid:16-r1（固定 ReDroid digest）
          ├─ 容器 scrcpy 4.1 -> Xvfb/Openbox -> x11vnc -> WSS -> noVNC 1.7.0
          ├─ loopback ADB 5555 --------------------------> 宿主 scrcpy 4.1
          └─ Device Bridge 8090（token + allowlist）
```

项目只使用 Docker Engine/CLI 与 Docker Compose；不安装、调用或管理 Colima、OrbStack
或其他 provider CLI，Docker context 由宿主基础设施预先选择。实际 Docker server
只要通过 `scripts/check-redroid-host.sh` 即可作为实现；缺少 ARM64 Linux、ashmem、
binderfs 或 DMA-BUF 时必须 fail closed，不能通过项目命令切换到另一个 context 绕过门禁。

2026-07-30 复核当前 Apple M1 的 OrbStack Docker context 时，修正后的特权探针报告
`/cloudandx-host-dev/ashmem` 缺失；该 context 同时没有 DMA-BUF system heap 与 binderfs
三节点，故不属于 ReDroid 16 支持路径。历史运行证据来自通过全部门禁的 ARM64 Linux
Docker server；不能把 OrbStack 的 Docker API 可用误认为 Android 内核能力满足。

## 为什么暂不切换 WebRTC/scrcpy Web

官方 noVNC 1.7.0 + websockify 0.13.0 是版本稳定、协议成熟、可审计且能在单镜像内
复现的浏览器入口。`ws-scrcpy`、自建 scrcpy-WebSocket 网关和 Cuttlefish WebRTC
都可以作为后续性能实验，但目前分别存在上游 master 兼容性、协议版本耦合或 KVM/
crosvm 宿主要求，不能在未经目标 ARM64 runtime 实测时替换稳定路径。

浏览器输入由容器内 scrcpy 的 SDK mouse/keyboard 语义负责；noVNC canvas 额外捕获
鼠标 DOWN/MOVE/UP、滚轮触控板事件和 pointer capture，确保 Safari/WebKit 缩放后仍
能把按下、拖动、释放送到同一 RFB framebuffer。Openbox 只负责 Xvfb 窗口焦点，不
创建第二容器或第二 Android。

## 发布门禁

- `docker compose config --services` 只能返回 `android`，镜像必须包含固定 ReDroid
  digest、scrcpy 4.1、noVNC 1.7.0 和 websockify 0.13.0。
- `scripts/setup-redroid-host.sh` 必须通过；它会检查 Docker server ARM64/Linux、
  4 KiB 页、IPv6、ashmem、binderfs 三节点和 DMA-BUF system heap。
- 端口只允许回环绑定：ADB 5555、noVNC HTTPS 6080、Device Bridge 8090；raw VNC
  5900 不发布。
- noVNC 明文 HTTP 必须拒绝，WSS 使用数据卷中的证书和私钥；token、ADB key、TLS
  私钥不能进入镜像、URL 或日志。
- 冷启动、双入口 ready、点击/长按/滑动/键盘、断线重连、容器重启恢复和 30 分钟
  稳定性必须在目标宿主实测。只有满足既定 P95 ≤100 ms、≥30 FPS、无黑屏/丢输入的
  `realtime` 证据，才能使用“真机级/丝滑”表述。

## 能力边界

ReDroid 基础镜像是 AOSP Android 16，不包含 Google Play/GMS 或 Play 认证。真实基带、
SIM/eSIM、NFC/SE、TEE/StrongBox、Widevine L1、物理摄像头/传感器和 Play Integrity
physical verdict 仍需要授权制品或认证物理设备池。当前固定镜像的 Bluetooth 模拟
HAL 仍标记为 `not_supported`，不以跨版本二进制覆盖规避。
