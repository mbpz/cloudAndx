# CloudAndx Android 16

CloudAndx 在 Apple silicon 上以一个 ARM64 Docker 容器运行 Android 16 ReDroid，
并让宿主 scrcpy 与浏览器 noVNC 独立控制同一台 Android。运行时只有一个
`android` 容器和一个最终镜像；Android init 保持 PID 1，scrcpy、Xvfb、x11vnc、
websockify/noVNC、ADB 和受限 Device Bridge 由容器内监督器统一管理。

## 宿主要求

ReDroid 依赖 Linux binder、ashmem 和 DMA-BUF。macOS 上必须使用项目专用的
Ubuntu 22.04/5.15 ARM64 Colima profile；OrbStack 以及默认 6.8 内核不满足这条路线的
设备契约。

```sh
CLOUDANDX_PROXY_URL=http://127.0.0.1:7897 ./scripts/setup-redroid-colima.sh
```

脚本验证 4 KiB 页、IPv6、binderfs、ashmem、DMA-BUF，并完成一次 VM 重启恢复测试。
所有项目命令显式指定 `colima-cloudandx`，避免 Docker 当前 context 被 OrbStack 改写。
若旧 OrbStack Android 容器仍占用 5555/6080/8090，必须先停止它；runtime smoke 会用
持久化 Bridge token 校验宿主端口确实属于当前 Colima 容器，并在串线时失败关闭。

## 构建与启动

```sh
docker --context colima-cloudandx compose build
docker --context colima-cloudandx compose up -d
docker --context colima-cloudandx compose ps
```

默认只发布到宿主回环地址：

- Android 浏览器入口：<https://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale>
- ADB：`127.0.0.1:5555`
- Device Bridge：<http://127.0.0.1:8090>

首次打开 noVNC 需要接受持久化自签名证书。6080 只接受 HTTPS/WSS；raw VNC 5900
不发布。跨主机访问必须通过 SSH、VPN、受控 HTTPS 反向代理或零信任网关，不能把
Compose 地址改为 `0.0.0.0`，也不能转发 ADB、VNC 或容器 Shell。

## scrcpy

本机 scrcpy 4.1 可直接连接，不需要复制 ADB 私钥，也不会出现 USB 调试授权弹窗：

```sh
adb connect 127.0.0.1:5555
scrcpy --serial 127.0.0.1:5555 --mouse=sdk --keyboard=sdk \
  --max-size=1080 --max-fps=60 --video-bit-rate=8M --video-buffer=0
```

容器中的 scrcpy client/server 同样固定为 4.1。浏览器链路是
`scrcpy -> Xvfb -> x11vnc -> TLS websockify/noVNC`，使用 SDK 鼠标与键盘输入；左键
点击、按住拖动和触控板滚动均转换为 Android 触摸语义。noVNC 固定 1.7.0，
websockify 固定 0.13.0，下载制品均校验 SHA-256。

当前 M1 使用 Chromium/noVNC canvas 内 `requestAnimationFrame` 实测 30 次浏览器
点击到首个可见画面变化为 min 9.2 ms、median 43.8 ms、P95 85.2 ms、
max 99.5 ms，达到验收文档的 P95 100 ms 门限。x11vnc 固定 1 ms poll/defer，
保持非线程事件循环，避免输入与画面更新排队。该结果证明交互延迟门限，不等同于
真实触屏硬件、全部 Android HAL 或生产就绪。

## Device Bridge

Device Bridge 只提供 allowlist API，没有任意 shell。读取 token：

```sh
TOKEN=$(docker --context colima-cloudandx compose exec -T android sh -c 'cat /data/runtime/bridge/token')
curl http://127.0.0.1:8090/livez
curl http://127.0.0.1:8090/healthz
curl -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"x":540,"y":960}' http://127.0.0.1:8090/v1/input/tap
```

ReDroid 没有 AEMU Console，因此 GPS、短信、电话、网络和电池等 AEMU Console 专用
端点会失败关闭；截图、APK、应用列表、日志、点击、滑动、按键、文本、旋转和重启仍走
ADB allowlist。token 与 noVNC TLS 私钥只保存在 `emulator-data` 卷中。

## 固定版本与能力边界

- ReDroid Android 16：
  `redroid/redroid@sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b`
- scrcpy：4.1
- noVNC：1.7.0
- websockify：0.13.0

当前 ReDroid 镜像是 AOSP Android 16，不包含 Google Play Store/GMS，也不能提供真机
基带、eSIM/IMS、NFC 安全元件、UWB、TEE/StrongBox、硬件 Play Integrity 或
Widevine L1。若“完整功能”明确要求 Google Play 认证栈，需要另行引入有合法分发来源、
与 Android 16 匹配并可校验的 GMS 制品，不能把 AOSP ReDroid 误称为 Google Play 镜像。
当前固定 digest 中的模拟 Bluetooth 1.1 HAL 会触发 AddressSanitizer 崩溃，Framework
在 6 次重试后保持 Bluetooth OFF。隔离替换官方 ReDroid 15 digest 的同类 HAL 后仍在
相同 libc/vDSO/ASan 路径崩溃，排除了简单的 Android 16 ABI 回归；蓝牙因此标记为
`not_supported`，不计入运行时健康通过条件。需要无 ASan 的兼容 HAL、独立远程
RootCanal 链路或支持该服务的新宿主环境，不能用跨版本二进制覆盖伪装修复。

## 运维

```sh
docker --context colima-cloudandx compose logs --follow --tail 200 android
docker --context colima-cloudandx compose exec -T android /opt/cloudandx/bin/healthcheck.sh
sh tests/redroid-runtime-smoke-test.sh
docker --context colima-cloudandx compose down            # 保留 Android 数据和 TLS/token
docker --context colima-cloudandx compose down --volumes  # 删除项目数据卷
```

实现证据和路线边界见：

- [双远程入口验收](docs/dual-remote-ui-acceptance.md)
- [远程 Android 经验与路线决策](docs/remote-android-lessons-and-next-steps.md)
- [2026-07-25 ReDroid 16 运行证据](docs/redroid16-runtime-evidence-2026-07-25.md)
