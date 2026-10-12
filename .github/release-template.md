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
