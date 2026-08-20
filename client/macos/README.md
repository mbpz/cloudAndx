# CloudAndx macOS Client

原生 SwiftUI 客户端是现有 Android 17 AEMU/HVF/host GPU runtime 的产品入口。它只调用
`scripts/native-android17.sh` 的固定命令，不接受任意 shell，也不会启动 Docker
compatibility profile。

Phase 2A 增加固定名可信恢复点，以及 APK 安装、文件投递到 Android `Download` 和 PNG
截图。快照恢复会覆盖保存点之后的 guest 状态，因此客户端必须显示确认；恢复身份与
Emulator、Platform Tools、system image、AVD 配置和 GPU 模式不匹配时失败关闭。当前
Android 17 镜像没有公开 `cmd clipboard` 实现，项目不会用文本输入冒充剪贴板同步。

当前 M1 实测固定恢复点已能被 AEMU 真实加载：核心 load 为 3.618 秒，但从停止态到完整
framework/loopback 健康门禁为 11.93 秒，仍未达到架构目标 P95 ≤ 4 秒。本阶段完成的是
可信恢复和桌面融合闭环，不把尚未达标的 warm-resume 性能描述为“秒开完成”。

## 构建与测试

```sh
client/macos/scripts/swift-toolchain.sh build
client/macos/scripts/swift-toolchain.sh run CloudAndxClientCoreTests
```

开发运行：

```sh
client/macos/scripts/swift-toolchain.sh run CloudAndxClient
```

生成无需安装、开发期 ad-hoc 签名的 `.app` bundle：

```sh
client/macos/scripts/build-app.sh --mode development-sdk
open client/macos/.build/CloudAndx.app
```

`development-sdk` 的 App-Sandboxed Capability Agent 目前只提供 descriptor/FD 边界，
不会读取项目根或启动生命周期；权限服务在 bundle-owned runtime 或单独审计 helper 完成前失败关闭。
它仍依赖本机版本锁定的 Android SDK。最终 `bundled-release` 不向上发现项目根，而是只解析
App bundle 内 source-built AEMU+AOSP runtime；用户无需 Android Studio、Android SDK 或单独模拟器。

完整产品架构和后续阶段见 `docs/native-macos-client-architecture.md`。

当前机器安装的 macOS 27 SDK 与 Swift driver build revision 有细微漂移；包装脚本从 SDK
interface 读取版本并使用隔离 module cache，避免修改全局 Xcode/Command Line Tools。
SwiftPM 默认 `swiftbuild` backend 在这套预览工具链上会以
`Unknown error parsing property list` 退出，所以当前显式使用仍可工作的 legacy native
backend；它已被 SwiftPM 标记 deprecated，升级到 revision 完全匹配的 Xcode/CLT 后必须
重新验证默认 backend 并移除该兼容参数。
