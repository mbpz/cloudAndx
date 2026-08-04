# macOS 原生 Android 17 运行时决策

## 决策

Apple Silicon 本机低延迟交互采用 macOS 原生 Android Emulator，不在 OrbStack
Docker VM 内继续争取 ARM 硬件虚拟化。旧 Docker TCG 镜像仍可从源码重建，用于兼容
和证据回溯；同一时刻只运行一个 Android 实例。

## 选型依据

| 方案 | CPU / GPU 路径 | 本机可落地性 | 结论 |
| --- | --- | --- | --- |
| OrbStack 内 AEMU | ARM TCG + SwiftShader | 已运行，但语言页超过 60 秒、产帧约 2 FPS | 淘汰为低延迟方案 |
| OrbStack 内嵌套 KVM | 需要 VM 内暴露完整硬件虚拟化 | Google 官方不支持在 Docker/另一 VM 内运行 VM 加速 Emulator；本机也无 `/dev/kvm` | 不采用 |
| macOS 原生 AEMU | Hypervisor.Framework + gfxstream host GPU | Apple Silicon 官方支持，本机验证通过 | 采用 |

Google 的[硬件加速说明](https://developer.android.com/studio/run/emulator-acceleration)
明确指出：Apple Silicon 支持 VM 加速；VM 加速 Emulator 必须直接运行在宿主机，不能
运行在 Docker 或另一层 VM 内。官方的[命令行说明](https://developer.android.com/studio/run/emulator-commandline)
支持使用固定 AVD、端口、`-accel`、`-gpu` 和 gRPC 参数启动独立 Emulator。

## 运行边界

- 运行版本固定为 Emulator 37.1.11、Platform Tools 37.0.1、Android 17 Google Play
  PS16K ARM64 r06；`setup` 在安装前校验 stable repository 版本，仓库或已安装版本不符时
  失败关闭。
- AVD 和运行状态只写入 `.runtime/native-android17/`。
- `launchd` label `dev.cloudandx.android17`负责进程生命周期，调用终端退出不会杀死设备。
- 启动前停止 Compose 的旧 `android`容器，但不删除 `cloudandx-android_emulator-data`
  命名卷。
- ADB 使用 Emulator 本地端口 5557；gRPC 使用 8556 并启用 token。两者不绑定或转发到
  局域网/公网。
- 本机交互使用 Emulator 原生窗口或同版 scrcpy 4.1；二者控制同一个 AVD。
- 现有 noVNC 浏览器入口仍属于 Docker 兼容路径，不在本阶段跨越宿主/容器边界暴露
  原生 Emulator gRPC。需要浏览器远程入口时，应另行实现带 token 的宿主代理并重新完成
  未授权访问、输入、重连和敏感信息测试。

## 验证结果

- Emulator：37.1.11；图形后端 `gfxstream`。
- GLES/Vulkan：`host`。
- Android：API 37.0 Google Play PS16K ARM64 r06。
- 冷启动：18.2 秒，脚本在 120 秒门禁内完成 `sys.boot_completed=1`。
- Settings 语言页 5 次冷启动：564、595、716、982、1113 ms。
- 滑动录屏：102 帧 / 3.123 秒，约 32.6 FPS。
- 旧 ARM TCG 对照：语言页超过 60 秒仍未完成。

## 回滚

执行 `scripts/native-android17.sh stop`，再按 README 的 Docker 兼容方案重新构建并启动。
旧命名卷未删除，因此容器内 Android 数据仍可恢复；已删除的旧 TCG 镜像需要重新构建。
