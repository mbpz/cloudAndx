# OrbStack ReDroid 可行性复测（2026-08-11）

## 结论

在这台 M1 MacBook Pro 的 OrbStack 7.0.11 Docker VM 上，ReDroid 不能达到本机
macOS Android Emulator 的流畅度，也没有形成可验收的稳定图形与编码链路。因此它不是
本项目的本机默认方案。默认路径是宿主 macOS ARM Android Emulator；Docker AEMU 只保留为
显式 `docker-compat` 兼容/证据 profile。

这不是网络问题。本次复测未修改 FlyLink、Clash Verge、VPN、DNS、路由、防火墙或
其他容器。

## 当前宿主事实与已尝试前置条件

- OrbStack `7.0.11-orbstack-00360-gc9bc4d96ac70`，Docker server 为 ARM64 Linux；无
  `/dev/kvm`、`/dev/dri`、`/dev/dma_heap/system`、`/dev/ashmem` 和 binderfs。
- 存在静态 `/dev/binder`、`/dev/hwbinder`、`/dev/vndbinder`（权限 `0600`）以及
  device-mapper；宿主有匹配的 ext4 内核模块。该组合不能替代 binderfs、DMA-BUF 或宿主
  GPU 渲染能力。
- ReDroid 16 曾显式映射 device-mapper、加载 `crc16 → mbcache → jbd2 → ext4`，并处理
  Binder 权限；这些前置条件只让启动推进，不提供可用的 guest 图形缓冲。
- 官方 ReDroid 对 `guest` GPU 的定位是软件渲染，历史说明约为 `10+ FPS`，本身也不构成
  本机原生图形加速的等价物。

## 镜像复测矩阵

| 版本与固定 digest | 结果 | 决策含义 |
| --- | --- | --- |
| ReDroid 12 `sha256:a6c464bbedcf1dcb67dbf91f329fbb19bee5b50631f0ca6bda6ed7c41b0e64e2` | 退出 129：`/proc/sys/vm/mmap_rnd_compat_bits` 不存在 | 用户提出的 Android 12 命令在此 OrbStack 无效 |
| ReDroid 14 `sha256:0a611199ba2e0b5d60af39b3327a517f6407231f4352114ed3bd3cbfe2be69aa` | 可见 Settings splash 后稳定截图变黑；默认 MediaCodec 为空，启用 Codec2 后 `c2.android.avc.encoder` 创建输入 surface 失败（`err=-32`） | 没有稳定视频/远程显示链路 |
| ReDroid 15 `sha256:b51bde9cef80f7bd7581148192f2b2f4d41f23c6344cfe88eceeb8ddd67490ee` | 能启动，但稳定捕获为黑，scrcpy 报没有 encoder | 不能形成可用交互画面 |
| ReDroid 16 `sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b` | device-mapper/ext4/Binder 后推进到 SurfaceFlinger；guest 因 `output buffer not gpu writeable` 退出 | 根因是缺少可写 GPU 输出缓冲，而非启动参数 |

当前项目的旧 ReDroid 16 Dockerfile 曾固定完整 digest，现已随未接入 Compose 的实现
一并删除，避免把不可运行路径误呈现为部署选项。

## Android 12 提案为何无效

Android 12 的 `init` 在 ARM64 启动阶段需要读取并设置 `mmap_rnd_bits` 与
`mmap_rnd_compat_bits`。当前 OrbStack 内核没有后者；因此即使使用 `--privileged`、
`/data` 持久卷、6 CPU、8 GB、1080×1920、60 FPS、`guest` GPU 或 `use_memfd`，进程也会
在 Android 图形启动前以 129 结束。容器参数无法补出缺失的 host kernel sysctl。

## 决策边界

- 要求“与本机模拟器一样流畅”的本机交互：运行
  `scripts/native-android17.sh start`，使用 Hypervisor.Framework 和 `-gpu host`。
- 需要保留 Docker 单容器协议、安全边界或回归证据：显式使用
  `docker compose --profile docker-compat …`，并接受 TCG/SwiftShader 的低性能性质。
- 若未来要重新评估容器 Android，必须在具备 `/dev/kvm`、GPU/DMA-BUF、Binder/内核能力与
  实测稳定编解码的目标 Linux 上重新验收；不能依赖本次 ReDroid 镜像、手工模块加载或
  历史其他主机证据。
