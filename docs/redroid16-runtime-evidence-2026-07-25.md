# ReDroid 16 运行证据（2026-07-25）

> 本文运行数据来自通过 ashmem、binderfs 和 DMA-BUF 门禁的 ARM64 Linux Docker
> server，不代表每个 macOS Docker provider 都支持 ReDroid。2026-07-30 在当前
> Apple M1 的 OrbStack Docker context 复核时，修正后的探针因缺少
> `/cloudandx-host-dev/ashmem`（并同时缺少 DMA-BUF system heap 与 binderfs）而 fail
> closed；该环境没有新的 Android 双入口运行证据。

## 环境身份

- 宿主：Apple M1 macOS；
- Docker：ARM64 Linux Docker runtime，4 KiB pages、Ubuntu 22.04、Linux 5.15；
- 容器镜像：`cloudandx/android16-redroid:16-r1`；
- ReDroid 基础 digest：
  `sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b`；
- Android：16 / API 36 / arm64-v8a / 4096-byte page；
- 浏览器链路：scrcpy 4.1、Xvfb、x11vnc、websockify 0.13.0、noVNC 1.7.0；
- 画面：Android 1080×1920；scrcpy texture 606×1080；X11 540×960；
- 入口：ADB 5555、HTTPS noVNC 6080、Device Bridge 8090，均绑定
  `127.0.0.1`；
- 稳态单次 `docker stats`：CPU 1.00%，内存 1.18 GiB / 7.746 GiB
  （15.24%）。该点样本只用于描述环境，不作为长期资源上限。

## 浏览器输入到可见画面

测试使用 Chromium/noVNC 真实连接。每轮先回到 Android Launcher，预热 5 轮后，
通过 Chromium DevTools 派发真实鼠标 DOWN/UP；页面在 noVNC canvas 内使用
`requestAnimationFrame` 观察第一个不同像素帧。ADB 只在计时前恢复相同 Launcher
状态，不参与输入、计时或完成判定。

x11vnc 使用非线程事件循环和
`-wait 1 -defer 1 -nonap -nowait_bog`；noVNC 固定 `compression=0`、
`quality=6`。最终镜像重建并冷启动后的 30 次毫秒样本：

```text
86.1, 52.2, 64.0, 44.1, 32.0, 33.3, 14.3, 69.7, 99.5, 43.5,
41.7, 64.2, 75.9, 59.2, 61.7, 39.6, 29.3, 43.4, 18.8, 84.1,
9.2, 30.7, 49.1, 45.1, 82.5, 25.4, 47.4, 35.6, 24.2, 28.2
```

汇总：min 9.2 ms、median 43.8 ms、P95 85.2 ms、max 99.5 ms。

旧测量器通过宿主轮询截图并编码 PNG，所得 P95 151.6 ms 包含测量工具开销，保留
为端到端诊断值，不再作为浏览器用户看到首帧的验收指标。canvas 内测量达到
P95 100 ms 目标；它只证明远程交互链路，不证明 Bluetooth、GMS 或真实硬件能力。

## 功能与安全证据

- 浏览器点击打开 Gallery；
- 浏览器连续拖动打开应用抽屉；
- 浏览器键盘输入 `settings` 后 Android 搜索框显示相同文本；
- 宿主 scrcpy 4.1 直接连接同一 serial，无授权弹窗；
- 宿主 scrcpy 4.1 在 noVNC 仍返回 HTTPS 200 时并发录制 5 秒 H.264，产物为
  1080×1920；退出宿主 scrcpy 后容器内 noVNC 链路未中断；
- noVNC 连续建立并关闭 10 个独立浏览器会话，每次均取得有效 canvas 帧，
  Android/容器健康检查随后仍通过；
- Device Bridge 未授权写请求返回 401，带卷内 token 返回 200；
- noVNC HTTPS 返回 200，明文 HTTP 被拒绝；
- Docker Linux runtime 重启后容器恢复 `healthy`，Android 与三个入口恢复；
- 故障注入杀死 Device Bridge 后，监督器关闭全部远程面且健康状态变为
  `unhealthy`；Android init 保持 PID 1，需外部编排或人工重启容器恢复。
- 连续 1,878 秒（31 分 18 秒）按 10 秒间隔执行 180 次检查：Android boot、
  SurfaceFlinger、scrcpy 首帧、HTTPS noVNC、Device Bridge 均无失败，容器
  `restart_delta=0`。
- 1 ms x11vnc 参数固化并重建后另做 305 秒短稳：30 次 HTTPS noVNC、Bridge
  liveness 和容器健康检查均通过，0 失败、0 重启；随后容器重启恢复并再次通过
  runtime smoke。

运行时回归入口：

```sh
sh tests/redroid-runtime-smoke-test.sh
```

## 仍需保留的边界

- 当前镜像是 AOSP，不含 Google Play/GMS；
- Android Emulator Console 专用的 GPS、短信、电话、网络和电池端点失败关闭；
- 真实基带、NFC/SE、TEE/StrongBox、Widevine L1、硬件 Play Integrity 和真实
  传感器不由容器方案提供；
- 固定 ReDroid digest 的 `android.hardware.bluetooth@1.1-service.sim` 在 ARM64
  启动时发生 AddressSanitizer SEGV；`com.android.bluetooth` 连续崩溃 6 次后
  Framework 保持 Bluetooth OFF。蓝牙当前为 `not_supported`，不是已验证的模拟能力；
- Chromium/noVNC canvas 内的 100 ms P95 交互门限已通过；仍需保留长稳、负载和
  不同浏览器/显示器刷新率的发布验证。

蓝牙判断来自同一运行容器的 `dumpsys bluetooth_manager` 和 crash buffer：前者显示
`state: OFF`、`Bluetooth crashed 6 times`，后者显示 HAL 的 AddressSanitizer SEGV，
随后 Bluetooth framework 因 HAL `DEAD_OBJECT`/不可用退出。容器整体健康不等于该
可选 HAL 正常。

为区分 Android 16 回归与宿主兼容性，又从官方 ReDroid 15 64-only digest
`sha256:b51bde9cef80f7bd7581148192f2b2f4d41f23c6344cfe88eceeb8ddd67490ee`
隔离提取 HAL（文件 SHA-256
`4d686c67288bb8154dc44d2b6ac761540aa4a5016e6d8aea6fc8971798e054b5`）。它同样使用
`/system/bin/linker_asan64`，在当前 Android 16/ARM64 Docker 环境收到 HCI 请求后于
相同 libc/vDSO/ASan 路径崩溃。跨版本替换无效且不满足可维护性要求，测试制品已删除；
后续只能验证无 ASan 的同版 HAL、remote RootCanal，或更换支持该 HAL 的宿主环境。
