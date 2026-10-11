# Lazer HiFi 播放器交接手册

更新时间：2026-10-11（Asia/Shanghai）

## 当前多平台验证状态（2026-10-11）

音频引擎现于 `EngineEnvTest` 分支继续验证。Build #214 在提交 `570c269` 上由分支 push 自动触发，Android、Windows、Linux、macOS、iOS 模拟器和 iOS 设备目标六个 job 全部成功。CI 证明软件构建、离线探针、模拟器路线冒烟和无签名 iOS 打包，不代表实体 DAC 或 iPhone 的硬件兼容认证。本轮完整过程、失败修复和未覆盖硬件项见 [`ENGINE_ENV_TEST_VALIDATION.md`](ENGINE_ENV_TEST_VALIDATION.md)。

本文作为 PR #16 的交接入口，汇总可复现的验证方式，并把已实现、未实现、尚未实机验证的内容分开记录。完整实施历史、格式政策和逐项限制仍以 [`docs/HIFI_PLAYER_DEVELOPMENT.md`](HIFI_PLAYER_DEVELOPMENT.md) 为准。

## 1. 接手位置

- 仓库：`Bad0RANG3/Lazer` fork，PR #16 指向 `chuxuehaocai/Lazer:master`。
- 分支：`codex/hifi-player-cross-platform`。
- 本次功能代码基线：`1f54bb5`（Android SAF 曲库逐行扫描）；本交接手册作为后续文档提交加入同一 PR。最终 head 以 [PR 页面](https://github.com/chuxuehaocai/Lazer/pull/16) 为准。
- PR 目前为 open，尚未合并。最后一次检查时，API 35 Android x86_64 emulator workflow 状态为 `action_required`，需要有权限的仓库维护者批准运行。文档提交后应在 PR 的 Checks 页面确认新 head 对应的状态。
- 本机工作区还留有与 PR 无关的未跟踪录音/测试产物、截图、日志、`tools/` 和 `native/lazer-audio/tools/__pycache__/`。不要用 `git add .`、`git clean` 或 reset 处理；提交时只暂存明确相关的文件。

### 状态定义

- **已实现**：代码在仓库中，相关离线单元、集成、原生构建或 CI 有对应覆盖。它不等同于设备兼容认证。
- **已实现但未验证**：代码路径存在，缺少目标操作系统、实际设备、物理格式回读或数字回采证据。
- **未实现**：仓库目前没有这项功能或后端，不应在发布说明中写成已支持。

## 2. 已实现

| 领域 | 当前实现 | 已有验证 |
| --- | --- | --- |
| Windows 桌面 PCM | WASAPI 输出、设备选择、Exclusive 请求、格式候选和实际初始化会话状态；bit-perfect 只在严格前提满足时报告。 | 当前 Windows 全量桌面测试 397 项通过，失败/错误 0，跳过 5；Native Release CTest 16/16 通过。 |
| Linux 桌面输出 | ALSA `hw:` PCM、设备目录/选择、DoP、raw DSD 的 ALSA Native DSD（DSD64–1024）。 | Linux 原生构建、离线 CTest、包安装与 JNA 冒烟曾由 Actions 验证；具体证据见开发方案和 Build workflow。 |
| macOS 桌面输出 | CoreAudio HAL PCM、可选 Hog Mode 请求/所有权状态、严格格式 DoP。 | Apple runner 的 SDK 构建、CoreAudio 策略/队列探针和 JNA 目录检查曾由 Actions 验证。 |
| DSD 与 DoP | 桌面有 DSD→PCM；Windows/macOS/Linux 有各自受约束的 DoP 路径；Linux ALSA 有 Native DSD。Android 本地 DSF/DFF/DST DFF→PCM 已接入；Android USB DoP 限本地立体声未压缩 DSF/raw DFF 的 DSD64/128/256。 | 桌面有 fake-output/source/packer CTest；Android 有 JVM/Robolectric 覆盖。Android JNI emulator gate 尚待本次 PR head 的 Actions 运行。 |
| Android USB UAC2 | 可选 JNI/libusb 直出 PCM16/24/32，按设备描述符和时钟能力协商；有 DoP 路径及 UAC Feature Unit 硬件音量 `SET_CUR`/`GET_CUR` 回读。 | 协议解析、状态机、fake-libusb 生命周期及载波测试有离线覆盖。 |
| Android 本地曲库 | SAF 多目录递归索引 WAV/WAVE、FLAC、DSF、DFF；authority + document ID 去重、size/mtime 标签缓存、搜索/排序、AtomicFile 快照、播放队列和授权生命周期。SAF 子目录现在逐行消费 Cursor，并在每行检查取消。 | Android 单测 240/240；10,000 个唯一假文档加一条重复项测试覆盖去重、重扫标签复用和中途取消保留旧快照；Debug APK 构建成功。 |
| DSP 与标签 | 桌面/Android 提供 EQ 与 bypass、ReplayGain 等 PCM 处理；整数 DSP 量化使用 TPDF dither。桌面本地 WAV/FLAC/DSF/DFF 有标签、ReplayGain、封面和队列/CUE 支持；Android 本地曲库有标签、封面和队列。 | Android/Shared JVM 测试通过；桌面本地库、DSP、CUE、ReplayGain 有合成文件和 fake-output 回归。 |
| 网络设备 | 桌面 UPnP AV 本地 WAV/FLAC 投送、RenderingControl；OpenHome Playlist 队列/有限恢复；MPD 控制客户端。 | UPnP 有本机 HTTP renderer 集成测试；MPD 有 loopback 假服务测试。 |
| iOS | 本地文件导入、AVPlayer 队列、暂停式冷启动恢复和 AVAudioSession 采样率请求/状态显示。 | Xcode 模拟器构建/启动曾由 Actions 验证。 |

### 本次本机验证记录

以下命令在 Windows 工作区执行；结果对应本次交接时的代码基线：

```powershell
& .\gradlew.bat :desktopApp:test -PwindowsArch=x64 --no-daemon --no-configuration-cache
& .\gradlew.bat :shared:jvmTest :androidApp:testDebugUnitTest :androidApp:assembleDebug --no-daemon --no-configuration-cache
cmake --build native/lazer-audio/build --config Release --parallel 2
ctest --test-dir native/lazer-audio/build -C Release --output-on-failure
```

- 桌面：397 项通过，失败 0、错误 0、跳过 5。
- Shared JVM：158 项通过。
- Android：240 项通过；Debug APK 构建成功。
- Native Release CTest：16/16 通过。
- Android SAF 专项类：11/11 通过。

这些结果验证仓库里的代码和软件边界。fake output、ALSA `null`、假 DocumentsProvider、Robolectric、模拟器或 CI 格式协商结果，都不能单独证明 DAC 实际收到的位深/采样率，也不能证明链路没有 SRC 或 DSP。

## 3. 未实现

- **Windows ASIO 后端**：Windows 目前使用 WASAPI；仓库没有 ASIO output backend。路线图建议先核对 SDK 获取、授权和分发条件，再做独立后端与驱动格式协商。
- **MQA 软件解码**：未实现；需要单独解决授权。仓库也没有足够证据宣称 MQA bit-perfect 透传已验证。
- **Windows/macOS/Android/iOS Native DSD 输出**：未实现。Android DoP 是 PCM24 载波，不是 Native DSD；Android DSD→PCM 也不代表设备以 DSD 输入。
- **Roon Ready、HQPlayer NAA endpoint、AirPlay 2、Chromecast、Squeezelite/LMS 集成**：未实现。MPD 是控制客户端，MPD 服务端承担实际播放。
- **Android CUE 和 OpenHome gapless**：未实现。桌面 WAV/FLAC CUE 与其他已测桌面 gapless 路径不代表移动端或 OpenHome gapless。
- **跨平台、跨设备的 44.1–768 kHz 物理采样率保证**：未实现为通用承诺；各后端按设备能力协商，设备支持范围不同。

## 4. 已实现但未验证

- **DAC 端 bit-perfect**：尚无可覆盖目标平台和设备的数字回采/逐样本对比证据。WASAPI/HAL/ALSA 会话状态、AudioTrack 格式、USB 时钟设置成功和 renderer `ProtocolInfo` 都不是 DAC 输入逐位一致的证明。
- **真实 USB DAC 的采样率切换、DoP 锁定和 Native DSD 识别**：需逐台记录 DAC/固件/驱动及物理锁定状态。Android Feature Unit 写入并精确回读也不等于模拟音量已变化。
- **Android UAC2 系统行为**：USB 权限弹窗、系统权限广播、真实异步等时端点、拔插/占用恢复、真实 `SET_CUR`/回读及 DAC 输出还没有完整实体设备验证。
- **Android DSD JNI 端到端**：当前 PR 的 API 35 x86_64 emulator workflow 需要维护者批准。`:androidApp:assembleDebugAndroidTest` 只编译/打包测试，不代表 emulator 上的 JNI 断言已运行。DSD512/1024→PCM 的 instrumentation 结果以该 workflow 为准；Android USB DoP 目前仍限 DSD64/128/256。
- **Android SAF 真实 provider 和实际容量**：10,000 条是合成 Robolectric 假树回归，不是实体 Android 上扫描 10,000 个文件的耗时/内存测量。Cursor 打开期间的元数据读取也需用系统 DocumentsProvider 或云盘 provider 验证。
- **Linux ALSA 驱动/实体设备**：当前 Windows CTest 中 ALSA packing/policy 用例是离线逻辑测试；Linux `null` 会丢样本。workflow 会在 `snd-aloop` 可用时尝试数字回采，hosted runner 缺模块时会跳过；未有证据时仍按未验证记录。
- **macOS CoreAudio HAL 与 iOS 输出**：CI 的 Apple SDK/Xcode 构建通过不等于 Hog Mode、物理格式、DAC 路由或 iOS 外接 DAC 的设备行为已验证。
- **网络设备**：UPnP/OpenHome 目前由协议夹具和本机 HTTP 集成覆盖；MPD 由 loopback 假服务覆盖。真实 renderer、MPD 服务、多厂商差异、组播网络和 DAC 输入均未验证。

## 5. 复现与平台验证

### Windows

在仓库根目录运行上面的 Gradle 和 CTest 命令。Windows 本机构建可验证桌面 JVM、WASAPI 策略和 fake-output；需连接真实设备才能测试 Exclusive 占用、设备重插、物理率及回采。原生探针可以离线运行，不把探针结果描述为 DAC 认证。

### Android

```powershell
& .\gradlew.bat :shared:jvmTest :androidApp:testDebugUnitTest :androidApp:assembleDebug --no-daemon --no-configuration-cache
& .\gradlew.bat :androidApp:assembleDebugAndroidTest --no-daemon --no-configuration-cache
```

第二条仅确认 instrumentation 编译/打包。完整 DSD JNI 检查在 `.github/workflows/build.yml` 的 Android job：API 35、x86_64 emulator，并运行：

```bash
./gradlew :androidApp:connectedDebugAndroidTest -PlazerEnableAndroidUacNative=true -PlazerAbis=x86_64 --stacktrace
```

Fork PR 的工作流可能需要仓库维护者在 Actions 页面选择批准并运行。结果通过后仍需 Android 实机验证文件 provider、USB DAC 路由、设备时钟、DoP、硬件音量和拔插。

### Linux ALSA

使用 Linux runner；仓库 `.github/workflows/build.yml` 的 `linux-desktop` job 是依赖和构建参数的权威模板。该 job 安装 CMake、ALSA headers、pkg-config、NASM，构建 pinned FFmpeg，再配置：

```bash
cmake -S native/lazer-audio -B desktopApp/build/native/lazer-audio/linux-x64 \
  -DCMAKE_BUILD_TYPE=Release -DLAZER_FFMPEG_ROOT=$FFMPEG_ROOT \
  -DLAZER_AUDIO_BUILD_PROBE=ON -DLAZER_AUDIO_TEST_ALLOW_ALSA_NULL=ON
cmake --build desktopApp/build/native/lazer-audio/linux-x64 --config Release --parallel 2
ctest --test-dir desktopApp/build/native/lazer-audio/linux-x64 -C Release --output-on-failure
```

`snd-aloop` 回采仅在 runner 有模块时执行；没有设备时测试会跳过。随后用真实 ALSA `hw:` DAC 验证格式、XRUN、挂起恢复、DoP/Native DSD lock 和数字回采。

### macOS 与 iOS

在 PR 的 Build workflow 中检查 `macos-coreaudio` 与 iOS 模拟器 jobs。Windows/Linux 主机不能验证 Apple HAL；Apple SDK 编译、策略 probe、模拟器启动都不能代替实际 macOS CoreAudio 或 iOS 外接 DAC 测试。

### 真实设备验证记录

每次测试记录：操作系统版本、应用提交、设备型号/固件、USB/数字连接、驱动版本、源文件编码/位深/采样率、选择的 backend、DSP/EQ/ReplayGain/音量状态、引擎报告格式、设备物理锁定格式、丢帧/XRUN 和数字回采结果。只有回采样本与源解码 PCM 逐样本比较，才能对该条路径形成 bit-perfect 证据；保留原始录音与比较程序结果。

建议矩阵至少覆盖 PCM16/24/32 与 44.1/48/96/192 kHz、设备宣称支持的最高频率、采样率自动切换和设备重插。DoP 按设备明确支持的 DSD 倍率验证 marker/lock；Native DSD 只测已实现的 Linux ALSA 后端。硬件音量应记录设备范围、步进、`SET_CUR` 后 `GET_CUR` 回读和实际模拟衰减，不能以写成功代替听音/测量。

## 6. 后续优先级

1. 批准并完成当前 PR head 的 Android API 35 emulator workflow；把成功、失败或跳过的 job 结果写回交接与 PR 描述。
2. 在 Android 实机上验证 SAF 系统/云盘 DocumentsProvider、10,000 文件扫描资源占用、UAC2 PCM/DoP、设备时钟、Feature Unit 音量和拔插恢复。
3. 在 Linux runner/设备补齐 `snd-aloop` 回采和真实 ALSA DAC 矩阵；在 macOS/iOS 实机记录 CoreAudio、Hog Mode、外接 DAC 行为。
4. 评估 Windows ASIO 的 SDK/许可/分发前提，再决定 backend 实施方案。MQA、Roon/NAA、AirPlay 2、Chromecast 等分别立项，先确认协议和商业前提。
5. 按设备证据维护支持矩阵；任何没有实际硬件/数字回采结果的能力标注为未验证，不把格式协商或 codec 解码结果写成 DAC 兼容承诺。

## 7. PR 收尾规则

- 仅把交接手册及已审阅的目标文件加入 PR；避免把工作区现有截图、日志、缓存和临时夹具提交进去。
- 每次推送后检查 [PR #16](https://github.com/chuxuehaocai/Lazer/pull/16) 的最新 head 与 Checks 状态。`action_required` 表示 workflow 尚未获准运行，不等于测试通过，也不等于代码失败。
- 最终 PR 仍需 review/merge；本次用户授权的是提交最后更新并完善交接，不代表自动合并。

## 8. 主要入口

- 总体路线与技术边界：[`docs/HIFI_PLAYER_DEVELOPMENT.md`](HIFI_PLAYER_DEVELOPMENT.md)
- GitHub Actions 工作流： [`.github/workflows/build.yml`](../.github/workflows/build.yml)
- Android SAF 扫描与存储：`androidApp/src/main/kotlin/dev/naominet/lazer/AndroidLocalAudioLibraryRepository.kt`
- PR： [#16 feat(audio): add cross-platform HiFi playback foundation](https://github.com/chuxuehaocai/Lazer/pull/16)
