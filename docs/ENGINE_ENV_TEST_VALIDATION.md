# EngineEnvTest 多平台音频引擎验证

验证日期：2026-10-11（Asia/Shanghai）  
分支：`EngineEnvTest`  
起点提交：`dded04d34c33578962e25363365e046c1277ef54`  
复验代码提交：`570c269`（包含 `d8e9253` 的模拟器启动诊断修改）

## 验证入口

- [Build #206](https://github.com/chuxuehaocai/Lazer/actions/runs/38068428895)：同一提交在 `master` 的 push 运行，六个平台 job 成功，release job 按非 tag 规则跳过。
- [Build #210](https://github.com/chuxuehaocai/Lazer/actions/runs/38120168285)：在 `dded04d` 从 `EngineEnvTest` 手动触发。Android、Windows、Linux、iOS 模拟器与 iOS 设备构建成功；macOS CoreAudio 的 PCM matrix 探针失败；release 按非 tag 规则跳过。
- [Build #211](https://github.com/chuxuehaocai/Lazer/actions/runs/38121426530)：在假输出设备节奏修复提交 `b79685e` 上手动触发。Android、Windows 成功，macOS PCM matrix 探针通过，但同一个 macOS CTest job 的 CUE gapless 探针等待 `Ended` 超时。Linux、iOS 的剩余任务因后续运行接替而取消。
- [Build #212](https://github.com/chuxuehaocai/Lazer/actions/runs/38122068820)：在 `966f125` 上手动触发。Android、Windows、Linux 和 macOS 成功；iOS 共享代码测试成功，但模拟器 Xcode 构建找不到刚启动的设备 UDID；iOS 设备 job 在后续运行接替时尚未结束。
- [Build #213](https://github.com/chuxuehaocai/Lazer/actions/runs/38123010058)：在 `d4e2fba` 上手动触发。Android、Windows、Linux、macOS、iOS 设备目标构建成功；iOS 模拟器完成共享测试、应用构建、首页及 `search`、`library` 页面截图，在 `me` 页面启动时未于 20 秒内输出路由标记。
- [Build #214](https://github.com/chuxuehaocai/Lazer/actions/runs/38124375718)：`570c269` push 自动触发。Android、Windows、Linux、macOS、iOS 模拟器和 iOS 设备构建六个 job 全部成功；release job 因非 tag 运行跳过。

`EngineEnvTest` 与 `master` 在验证开始时指向相同提交。最初工作流的 push 过滤器没有列出 `EngineEnvTest`，因此先用 `workflow_dispatch` 运行；提交 `570c269` 已把该分支加入 push 触发列表，Build #214 由 push 自动运行。

## Build #214 的分支 CI 证据

| 平台 | Build #214 结果 | 软件验证范围 |
| --- | --- | --- |
| Android | 成功 | USB PCM packetizer / fake libusb 主机探针、Android 单测、UAC2 独立 APK 与 release APK 的 ABI 打包检查、API 35 x86_64 模拟器 DSD JNI instrumentation。 |
| Windows x64 | 成功 | 桌面测试、可运行 JAR、便携版和 MSI 构建及打包内容检查。 |
| Linux x64 | 成功 | ALSA 原生引擎与 CTest、桌面 ABI 测试、DEB/RPM 安装及原生库加载检查、AppImage/JAR 打包检查。 |
| macOS arm64 | 成功 | CoreAudio HAL 原生构建与离线探针、CTest、FFmpeg 动态库相对路径检查、桌面 ABI 测试。 |
| iOS 模拟器 | 成功 | Shared iOS 测试、Xcode 构建、iPhone 模拟器安装启动、首页和十个页面路线冒烟。 |
| iOS 设备构建 | 成功 | 无签名设备目标编译与 IPA 打包；没有在实体 iPhone 上运行。 |

Build #214 的 Android job 成功运行 API 35 x86_64 模拟器 DSD JNI instrumentation。Linux job 的运行注释明确指出 hosted kernel 没有 `snd-aloop`，因此数字 loopback 回采被跳过。Build #214 没有 tag，release job 按工作流规则跳过。

## 分支运行中发现的问题

Build #210 的 macOS CoreAudio job 已完成原生编译，但 `lazer-audio-engine-pcm-matrix` 是 16 个 CTest 中唯一失败的一项。CUE 用例在前 128 帧后捕获到静音填充（首个不匹配字节为 512），其余格式矩阵和 CUE 用例通过。探针的假输出设备原先每 1 ms 消耗 512 帧；在 48 kHz 下真实 period 约为 10.67 ms。这个过快的夹具时钟会制造解码线程跟不上的测试欠载。提交 `b79685e` 已将假输出改为按实际采样率计算 period，Build #211 的 PCM matrix 探针因此通过。

Build #211 的同一 macOS CTest job 在相邻 CUE gapless 用例等待干净 EOF 时达到用例内部 5 秒超时，未报告引擎错误。按设备节奏运行的完整夹具约需 1 秒播放，加上 runner 调度、队列预取和两种 CUE 场景，原 5 秒等待与 CTest 10 秒上限可能过紧。提交 `966f125` 把等待放宽到 15 秒、CTest 上限放宽到 40 秒，并在超时输出引擎状态、位置和已写 period 数，以区分慢调度与真正停滞。Build #212 的 macOS 原生探针和桌面 ABI 测试已全部通过。

Build #212 的 iOS job 完成 `:shared:iosSimulatorArm64Test`，并从可用设备列表选中 iPhone 17 Pro 模拟器。`simctl bootstatus` 完成后，`xcodebuild` 却无法解析同一个 UDID，报退出码 70，只列出通用 iOS Simulator 占位目标。提交 `d4e2fba` 让 Xcode 面向通用 iOS Simulator 目标编译；后续 `simctl install`、`launch` 和页面截图仍指定已启动的 UDID，保持实际模拟器验证。Build #213 已越过 Xcode 构建，并完成首页和前两个页面的运行检查。

Build #213 在 `me` 页面启动时 20 秒内未输出 `LAZER_IOS_ROUTE_APPLIED`，对应控制台文件为空。进程启动命令没有提前退出，截图虽生成但不能证明页面已导航。提交 `d8e9253` 将每个页面的启动宽限延长至 60 秒，并在再次缺少标记时记录设备列表、启动命令进程状态和模拟器运行日志。提交 `570c269` 把 `EngineEnvTest` 加入 push CI 触发分支。

Build #214 六个平台 job 全部成功，包括 iOS 模拟器完整页面路线冒烟，因此 `me` 页面用例在 60 秒宽限内完成。macOS CoreAudio 与桌面 ABI job 通过；Android 模拟器 DSD JNI、Linux ALSA 离线测试以及 iOS 设备构建也通过。

## 本机复现情况

本机 Windows 工作区没有预装 Gradle 9.6.0 缓存。设置 Java 21 和工作区内的 `GRADLE_USER_HOME` 后，wrapper 在下载 `gradle-9.6.0-bin.zip` 时受到本机网络权限限制，Gradle 测试没有启动。这个环境错误不代表代码测试失败；临时 Gradle 目录已清理。

## 尚未取得的硬件证据

这轮没有可用的 Android 手机、USB DAC、Linux/macOS 实机或 iPhone。以下项目仍不能标为通过：DAC 实际锁定的采样率与 DoP/Native DSD、物理位深和数字回采逐样本比对、Android UAC2 权限/拔插/硬件音量、真实 SAF provider 与大曲库资源占用、macOS Hog Mode 和 iOS 外接 DAC、真实网络 renderer。CI 的格式协商、模拟器和离线探针只能证明对应软件路径。

下一轮实体设备验证应按 [`HIFI_PLAYER_HANDOFF.md`](HIFI_PLAYER_HANDOFF.md#真实设备验证记录) 记录操作系统、设备/固件、源格式、输出路径、DSP/音量状态、引擎报告格式、设备锁定格式、丢帧以及数字回采文件和逐样本比较结果。
