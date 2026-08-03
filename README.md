# CloudAndx Android 16

CloudAndx 以一个 ARM64 Docker 容器运行 Android 16 ReDroid，并让宿主 scrcpy
与浏览器 noVNC 独立控制同一台 Android。运行时只有一个 `android` 容器和一个
最终镜像；Android init 保持 PID 1，scrcpy、Xvfb、Openbox、x11vnc、
websockify/noVNC、ADB 和受限 Device Bridge 由容器内监督器统一管理。

仓库只保留这条受支持的运行路径；历史实验分支及其多容器准入链路已经退役，
不再参与构建、测试或部署。

## 宿主要求

ReDroid 依赖 Linux binder、ashmem 和 DMA-BUF。本项目只通过 Docker CLI/Compose
运行，不安装或调用任何 provider CLI；Docker context 由宿主基础设施预先配置，项目
命令不会自行切换 context。Docker server 可以是本机 Linux、受控 Linux VM 或远程
Linux 主机，但必须先通过项目能力门禁。执行以下命令前，Docker Engine 必须已经由
宿主基础设施启动；项目不会启动或修复宿主 provider。

```sh
./scripts/setup-redroid-host.sh
```

脚本在当前 Docker context 内以固定 ReDroid digest 运行特权探针，验证 4 KiB 页、IPv6、
ashmem、binderfs 和 DMA-BUF；它不会安装内核模块或改变主机。能力不满足时探针会明确
失败，必须先修复 Docker server 的内核设备；不得通过删除 Compose `devices`、切换未
验证的 context 或降级到截图模式绕过门禁。

2026-07-30 在当前 Apple M1 的 OrbStack Docker context 复核时，探针正确失败并报告
`/cloudandx-host-dev/ashmem` 缺失；同一 Linux runtime 也没有 DMA-BUF system heap
和 binderfs 三节点。因此该 context 不能启动 ReDroid 16，Compose 不应被强行绕过；需要
改用实际提供这些内核设备的 ARM64 Linux Docker server。项目不会安装或调用 OrbStack。

## 构建与启动

```sh
docker compose build
docker compose up -d
docker compose ps
```

构建阶段若 Docker server 无法直连 GitHub，可临时设置
`CLOUDANDX_GITHUB_MIRROR=<HTTPS mirror>` 后再执行 `docker compose build`；下载制品仍
按 Dockerfile 内固定 SHA-256 校验，mirror 只影响构建下载，不进入运行时配置。

若宿主基础设施提供多个 Docker context，应在 Docker CLI 层预先选择通过门禁的 context；
项目命令本身不创建、切换或管理这些 context。

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
`scrcpy -> Xvfb/Openbox -> x11vnc -> TLS websockify/noVNC`，使用 SDK 鼠标与键盘输入；
浏览器端显式捕获左键按下、拖动和释放，触控板滚动转换为 Android 触摸语义，避免
Safari/WebKit 缩放 canvas 后丢失兼容鼠标事件。noVNC 固定 1.7.0，
websockify 固定 0.13.0，下载制品均校验 SHA-256。

此前具备完整内核设备的 ARM64 Linux Docker server 上，使用 Chromium/noVNC canvas 内
`requestAnimationFrame` 实测 30 次浏览器
点击到首个可见画面变化为 min 9.2 ms、median 43.8 ms、P95 85.2 ms、
max 99.5 ms，达到验收文档的 P95 100 ms 门限。x11vnc 固定 1 ms poll/defer，
保持非线程事件循环，避免输入与画面更新排队。该结果证明交互延迟门限，不等同于
真实触屏硬件、全部 Android HAL 或生产就绪。

## Device Bridge

Device Bridge 只提供 allowlist API，没有任意 shell。读取 token：

```sh
TOKEN=$(docker compose exec -T android sh -c 'cat /data/runtime/bridge/token')
curl http://127.0.0.1:8090/livez
curl http://127.0.0.1:8090/healthz
curl -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"x":540,"y":960}' http://127.0.0.1:8090/v1/input/tap
```

ReDroid 没有 Android Emulator Console，因此 GPS、短信、电话、网络和电池等 Console 专用
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
docker compose logs --follow --tail 200 android
docker compose exec -T android /opt/cloudandx/bin/healthcheck.sh
sh tests/redroid-runtime-smoke-test.sh
docker compose down            # 保留 Android 数据和 TLS/token
docker compose down --volumes  # 删除项目数据卷
```

实现证据和路线边界见：

- [双远程入口验收](docs/dual-remote-ui-acceptance.md)
- [稳定运行方案与长期边界](docs/stable-runtime-architecture.md)
- [2026-07-25 ReDroid 16 运行证据](docs/redroid16-runtime-evidence-2026-07-25.md)
