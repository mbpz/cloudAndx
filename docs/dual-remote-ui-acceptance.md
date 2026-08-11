# Android 17 AEMU 双远程入口验收（Docker 兼容路径历史验收）

> **说明（2026-08-11）**：此验收描述 Docker 兼容路径的单容器安全和交互目标；它不等同于
> 当前 M1 OrbStack 的原生级性能承诺。默认本机路径和边界以
> [稳定运行架构](stable-runtime-architecture.md) 为准。

## 历史验收目标拓扑

当时的默认运行时只有一个最终镜像、一个 Android 容器和一个持久化数据卷。noVNC
与宿主 scrcpy 必须控制同一个 AEMU serial：

```text
AEMU Android 17 / emulator-5556
  +-- loopback gRPC -> event-driven frame/input -> RFB -> noVNC 1.7.0 / HTTPS
  +-- host-loopback ADB -------------------------------> host scrcpy 4.1
  +-- container-local ADB -----------------------------> authenticated Device Bridge
```

noVNC 不依赖宿主 scrcpy，也不依赖截图轮询。宿主 scrcpy 退出或断线不能关闭
Android 或浏览器入口；浏览器断线也不能结束 Android 或阻止 scrcpy 重连。

## 前置宿主门禁

当前兼容档要求 ARM64 Docker Engine，并固定使用 ARM64 原生 AEMU 主程序、
ARM64 Android 17 Play system image 与软件 TCG/SwiftShader；项目脚本不得调用或
切换 provider CLI。运行时、制品身份和首帧任一门禁失败都必须 fail closed。

## 功能矩阵

| 能力 | noVNC 单独连接 | scrcpy 单独连接 | 两者同时连接 |
| --- | --- | --- | --- |
| 同一 Android serial | 必须 | 必须 | 必须一致 |
| 实时画面 | 必须 | 必须 | 内容与方向一致 |
| 单击、双击、长按 | 必须 | 必须 | 不互相抢占 |
| 连续拖动、上下滑动 | 必须 | 必须 | 不丢失 MOVE/UP |
| macOS 触控板手势 | 必须转换为 Android 触控 | scrcpy 原生支持 | 不互相锁死 |
| 键盘、文本、返回与 Home | 必须 | 必须 | 输入目标一致 |
| 客户端断线重连 | 必须 | 必须 | 另一入口不中断 |
| 容器和宿主 runtime 重启恢复 | 必须 | 必须 | 不创建第二 Android |
| 数据持久化 | 必须 | 必须 | 重启后结果一致 |

鼠标变成手形、RFB 有 pointer packet、ADB 返回成功或生成静态截图都不是功能
通过证据。每项输入必须观察到 Android UI 的对应状态变化。

## 安全与拓扑门禁

- Compose 默认只能有一个运行服务和一个最终运行镜像；构建 stage 不计入。
- noVNC 必须使用 HTTPS/WSS，证书和私钥保存在持久化卷且不写入镜像。
- ADB、noVNC、Device Bridge 只绑定宿主 `127.0.0.1`。
- raw VNC、Docker socket、binder/ashmem/DMA-BUF、容器 shell 不对用户发布。
- Device Bridge 必须验证 token 并保持操作白名单。
- 日志、URL、镜像层和测试快照不得包含 token、ADB 私钥或 TLS 私钥。

## 性能门禁

只有目标 ARM64 Linux/ReDroid 16 环境的实测数据可以支持 `realtime`
声明：

| 指标 | 门限 |
| --- | --- |
| 冷启动到 Android、noVNC、scrcpy 同时 ready | P95 ≤ 60 s |
| 点击到首个可见画面变化 | P95 ≤ 100 ms |
| 拖动/滑动输入到对应帧 | P95 ≤ 100 ms |
| 连续交互帧率 | ≥ 30 FPS |
| 稳定性 | 30 min 无黑屏、输入丢失或非预期重连 |

延迟项至少采集 30 次样本，保存宿主 CPU、内核、ReDroid digest、Android
build、serial、客户端版本、时间戳和原始数据。不得用 ADB 命令完成时间替代
浏览器输入到可见帧时间。

## 当前 AEMU 浏览器输入证据（2026-08-04）

- Chrome 通过 HTTPS/WSS 连接 noVNC 后执行 31 点连续上滑；Android
  `/dev/input/event1` 观察到完整 DOWN、29 个坐标单调变化的 MOVE 和压力归零/Tracking ID
  释放，稳定段 MOVE 间隔约 16–18 ms。
- 浏览器页面重载后，RFB 日志记录旧连接断开和新连接建立，Android 容器及输入流未重启。
- AEMU 37.1.7 的实际 RGB888 输出为 top-down；桥接器保持行顺序，使画面与触摸均以
  左上角为原点。proto 中历史性的 bottom-up 描述不能替代当前固定运行时的实测。
- 当前 ARM TCG 冷启动约 401 秒，尚未证明本页上方 `realtime` 性能门限，不得据此声称
  整个运行时达到真机级帧率或生产就绪。

## 历史 ReDroid 证据（非当前默认 AEMU）

| 项目 | 状态 | 当前证据 |
| --- | --- | --- |
| 宿主设备门禁与重启恢复 | 通过 | 当时的 ReDroid host preflight + provider 重启实跑（脚本已归档删除） |
| Android 16 启动 | 通过 | `sys.boot_completed=1`，约 11–22 秒 |
| Framework/图形 | 通过 | system_server、SurfaceFlinger、1080×1920 screencap |
| 宿主 scrcpy 4.1 | 通过 | 状态 `device`、Metal、`Texture: 1080x1920` |
| 两入口并发独立性 | 通过 | 宿主 scrcpy 录制 1080×1920 H.264 时 noVNC HTTPS 仍为 200 |
| noVNC 断线重连 | 通过 | 连续 10 个独立浏览器会话均取得有效 canvas 帧，健康检查保持通过 |
| noVNC ReDroid 实时画面 | 通过 | HTTPS noVNC 自动化截图显示同一 ReDroid 桌面 |
| noVNC 点击/滑动 | 通过 | 浏览器点击打开 Gallery；连续拖动打开应用抽屉 |
| noVNC 键盘 | 通过 | 浏览器键盘输入 `settings`，Android 搜索框显示对应文本 |
| 单最终镜像/单容器 | 通过 | 历史环境的默认 Compose 仅 `android`，健康状态为 `healthy` |
| Device Bridge 与安全门禁 | 基线通过 | 进程纳入监督/健康检查，token 持久化；AEMU Console 能力关闭 |
| 浏览器点击可见帧延迟 | 通过 | Chromium canvas 内 30 次：min 9.2 ms、median 43.8 ms、P95 85.2 ms、max 99.5 ms |
| 30 min 稳定性 | 通过 | 1,878 秒、180 次检查、0 失败、0 重启；覆盖 Android、SurfaceFlinger、首帧、HTTPS noVNC 和 Bridge |

历史环境的结论为 `RUNTIME_PROVEN / SCRCPY_PROVEN / BROWSER_INPUT_PROVEN / LATENCY_PROVEN`。
浏览器输入功能、P95 100 ms 延迟门限和 30 分钟稳定性已经成立。该结论只覆盖
已验收的远程交互链路；Bluetooth HAL 缺陷、GMS/认证栈和真实硬件能力仍阻止把
整个 Android 实例标记为“完整真机”或“生产就绪”。

原始样本、测试方法和故障注入结果见
[ReDroid 16 运行证据](redroid16-runtime-evidence-2026-07-25.md)。

## Android 16 能力边界

基础验收覆盖 AOSP Android 16 Framework、应用安装运行、网络、持久化和双远程入口。
音频、相机、位置及各类模拟传感器必须逐项验证，不能从 Android 启动成功推断。
当前固定 ReDroid digest 的模拟 Bluetooth HAL 会崩溃；官方 ReDroid 15 的 ASan HAL
隔离替换实验也在相同路径失败，蓝牙状态为 `not_supported`，不能用跨版本覆盖规避。
Google Play Store、GMS、Play 认证、
真实基带、SIM/eSIM、NFC/SE、TEE/StrongBox、Widevine L1、物理设备
Play Integrity verdict 和真实传感器不属于基础镜像已证明能力。
