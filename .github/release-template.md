> [!IMPORTANT]
> **1.x 系列最后一个正式版 / Final 1.x release**
>
> Lazer **__VERSION__** 是 1.x 系列的最后一个正式版本。`master` 分支随本次发布冻结，不再接受功能更新或问题修复；后续版本在 `nextgen` 分支继续。
>
> Lazer **__VERSION__** is the final official 1.x release. The `master` branch is frozen after this release and receives no further features or fixes; development continues on the `nextgen` branch.

### 📝 __VERSION__ 更新 / What's new in __VERSION__

- **英文成为默认语言 / English by default** —— 全新安装以英文界面打开，设置里仍可切换 English、简体中文、繁體中文、日本語，选择会保存到下次启动；iOS 的相机与相册权限说明同步为英文。Fresh installs open in English; the other three languages stay one switch away in Settings, the choice is remembered, and the iOS permission prompts are English too.
- **扫码登录 / Scan sign-in** —— 二维码改走官方桌面客户端的纯接口，每秒轮询一次，并在 Android 与桌面端本地绘制；遇到风控回执时按“等待手机确认”处理。The QR now comes from the same plain endpoint the official desktop client uses, polls once a second, is drawn locally on Android and desktop, and treats a risk-control reply as “waiting for confirmation”.
- **完整更新日志 / Full changelog** — [`CHANGELOG.md`](https://github.com/__REPO__/blob/__TAG__/CHANGELOG.md)

<div align="center">

[![Downloads](https://img.shields.io/github/downloads/__REPO__/__TAG__/total?style=flat-square&logo=github)](https://github.com/__REPO__/releases/tag/__TAG__)

</div>

### ⬇️ 快速下载 / Downloads

| 平台 / OS | x86_64 | ARM64 |
|-----------|--------|-------|
| **Windows** | [![windows-x64.msi](https://img.shields.io/badge/windows--x64.msi-0078D4?style=flat-square&logo=windows)](__BASE_URL__/Lazer-__VERSION__-windows-x64.msi) · [![windows-x64.portable.zip](https://img.shields.io/badge/windows--x64.portable.zip-67b7d1?style=flat-square&logo=windows)](__BASE_URL__/Lazer-__VERSION__-windows-x64-portable.zip) · [![windows-x64.jar](https://img.shields.io/badge/windows--x64.jar-E76F00?style=flat-square&logo=java)](__BASE_URL__/Lazer-__VERSION__-windows-x64.jar) | — |
| **Linux** | [![linux-x64.AppImage](https://img.shields.io/badge/linux--x64.AppImage-FCC624?style=flat-square&logo=linux)](__BASE_URL__/Lazer-__VERSION__-linux-x64.AppImage) · [![linux-x64.deb](https://img.shields.io/badge/linux--x64.deb-CE0056?style=flat-square&logo=debian)](__BASE_URL__/Lazer-__VERSION__-linux-x64.deb) · [![linux-x64.rpm](https://img.shields.io/badge/linux--x64.rpm-EE0000?style=flat-square&logo=redhat)](__BASE_URL__/Lazer-__VERSION__-linux-x64.rpm) · [![linux-x64.jar](https://img.shields.io/badge/linux--x64.jar-E76F00?style=flat-square&logo=java)](__BASE_URL__/Lazer-__VERSION__-linux-x64.jar) | — |
| **Android** | — | [![android-arm64.apk](https://img.shields.io/badge/android--arm64.apk-3DDC84?style=flat-square&logo=android)](__BASE_URL__/Lazer-__VERSION__-android-arm64.apk) |
| **iOS** | — | [![ios-arm64.unsigned.ipa](https://img.shields.io/badge/iOS--arm64.unsigned.ipa-000000?style=flat-square&logo=apple)](__BASE_URL__/Lazer-__VERSION__-ios-arm64.unsigned.ipa) |

### 📱 iOS 未签名 IPA 说明与自签名指引

本版本发布的 `Lazer-*-ios-arm64.unsigned.ipa` 为未签名应用包（因 CI 环境无 Apple Developer 证书）。若要在 iPhone / iPad 真机上运行，需要通过侧载工具自行签名。

<details>
<summary><b>使用 AltStore 进行自签名简易步骤（点击展开）</b></summary>

> *(测试参考：iPad Air 5 / iOS 17；其他设备与系统版本亦通用)*

1. 在电脑（Windows 或 macOS）上下载并安装 [AltStore](https://altstore.io/)，启动托盘程序 AltServer；
2. iOS / iPadOS 设备通过数据线连接电脑，在电脑托盘菜单选择 **Install AltStore** 安装到设备；
3. 设备前往：**设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID 证书**；
4. 在设备上打开 AltStore，点击 **My Apps** 页面的 **+** 号，选择下载的 `Lazer-*-ios-arm64.unsigned.ipa` 文件即可自动签名安装；
5. 个人免费 Apple ID 证书每 7 天需刷新一次（同局域网下 AltStore 会自动提醒和后台同步）。

*注：亦可使用 SideStore、TrollStore（巨魔）等支持自签或侧载的工具。*
</details>
