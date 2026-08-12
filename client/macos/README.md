# CloudAndx macOS Client

原生 SwiftUI 客户端是现有 Android 17 AEMU/HVF/host GPU runtime 的产品入口。它只调用
`scripts/native-android17.sh` 的固定命令，不接受任意 shell，也不会启动 Docker
compatibility profile。

## 构建与测试

```sh
client/macos/scripts/swift-toolchain.sh build
client/macos/scripts/swift-toolchain.sh run CloudAndxClientCoreTests
```

开发运行：

```sh
client/macos/scripts/swift-toolchain.sh run CloudAndxClient
```

生成无需安装、未签名的 `.app` bundle：

```sh
client/macos/scripts/build-app.sh
open client/macos/.build/CloudAndx.app
```

客户端仅从应用位置向上发现含有可执行 `scripts/native-android17.sh` 和 `compose.yaml` 的
项目根，并校验项目、脚本目录、runtime 脚本和 Compose 文件均归当前用户所有且不可由
group/other 写入。MVP 不接受环境变量重定向到另一个脚本；请运行默认生成在项目内的 `.app`。

完整产品架构和后续阶段见 `docs/native-macos-client-architecture.md`。

当前机器安装的 macOS 27 SDK 与 Swift driver build revision 有细微漂移；包装脚本从 SDK
interface 读取版本并使用隔离 module cache，避免修改全局 Xcode/Command Line Tools。
SwiftPM 默认 `swiftbuild` backend 在这套预览工具链上会以
`Unknown error parsing property list` 退出，所以当前显式使用仍可工作的 legacy native
backend；它已被 SwiftPM 标记 deprecated，升级到 revision 完全匹配的 Xcode/CLT 后必须
重新验证默认 backend 并移除该兼容参数。
