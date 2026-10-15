# Lazer

[简体中文](README.md) | [English](README.en.md)

> `nextgen` 为开发中的 Flutter 版本，功能和界面仍在调整。

跨平台音乐客户端，内置网易云音乐 WEAPI/EAPI 协议实现，无需第三方 API 网关。
歌曲、封面、歌词和推荐歌单均从服务读取。

## 功能

- 真实曲库、搜索、推荐歌单、账户与收藏。
- 同步歌词、翻译歌词、逐字效果、歌词多选复制与图片导出。
- 桌面端音量调节、静音及音量记忆。
- Android、iOS、Windows、macOS、Linux 系统媒体控件。
- 简体中文、繁体中文、日语、英语界面。
- 可叠加的滚动惯性、歌词模糊、5ms 跟随检查与平滑换行动画。
- 操作控件与进度条刻度震动反馈，iOS 支持强度调节。
- 移动端“我”页直达“我喜欢”，歌曲、封面、歌词与歌单数据自动缓存。

缓存完整的歌曲优先从本地播放；首次播放边听边在后台缓存。
歌曲缓存上限 1 GiB，封面 256 MiB，歌单等数据 64 MiB，超出时淘汰较久未使用的内容。
歌单曲目缓存 10 分钟，账户歌单 5 分钟，首页 20 分钟；过期后重新请求，网络失败时保留旧数据。
歌单详情可手动刷新，账户数据按会话隔离。缓存位于系统应用缓存目录，系统清理后会重新获取。

## 开发

使用 **Flutter 3.47.0 stable**。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

## 自动构建

向 `nextgen` 推送代码后，[GitHub Actions](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml)
会先检查代码，再构建以下产物。文件名统一为 `Lazer-<系统>-<架构>`。

| 产物 | 说明 |
| --- | --- |
| `Lazer-Windows-x86_64.zip` | EXE、依赖库、资源与 Visual C++ 运行库 |
| `Lazer-macOS-universal.zip` | Intel / Apple Silicon 通用 App |
| `Lazer-macOS-x86_64.zip` | Intel App，使用原生 Intel runner 构建 |
| `Lazer-Linux-x86_64.AppImage` | Linux x86_64，包含 GTK 与 libmpv |
| `Lazer-Linux-aarch64.AppImage` | Linux ARM64，使用原生 ARM runner 构建 |
| `Lazer-Android-universal.apk` | 通用 APK，使用当前开发签名 |
| `Lazer-iOS-aarch64.ipa` | 未签名的 iOS 真机 IPA |

构建完成后，在对应运行页面的 **Artifacts** 中下载，需登录 GitHub，保留 30 天。
Windows 请完整解压后运行；AppImage 下载后执行 `chmod +x`。
macOS 包使用 ad-hoc 签名，IPA 需要自行签名后安装。
详细配置见[构建说明](docs/builds.md)与[系统媒体控件说明](docs/system-media.md)。

## 参考

接口实现参考 [API Enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)，
歌词动画参考 [Apple Music Like Lyrics](https://github.com/amll-dev/applemusic-like-lyrics)。
应用使用小米 **MiSans** 字体。

项目自主代码采用 [MIT 协议](LICENSE)。
