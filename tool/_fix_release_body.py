import json
import subprocess
import urllib.request

def token():
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    raise SystemExit("no credential")

def api(method, path, payload=None):
    headers = {
        "Authorization": f"Bearer {token()}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "lazer-release-fix",
    }
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(
        f"https://api.github.com/repos/chuxuehaocai/Lazer{path}",
        data=data,
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(req) as response:
        return json.loads(response.read().decode("utf-8"))

summary = """## Lazer 2.0.0 beta3

第三个 2.0 测试版，重点是大屏幕模式、一起听与播放数据同步。

### 亮点
- 大屏幕模式：为你打造改为与电台一致的填满卡片渲染，电视端四张卡片加大；页面切换使用非线性淡入动画。
- 播放器：切歌封面渐隐渐显；遥控器上下键离开进度条，恢复切换上一个/下一个元素。
- 心动模式：按官方 intelligence list 连续补歌，播放次数与收听时长云端上传并回读。
- 一起听：播放器与设置入口，创建/加入房间、成员列表、心跳与 PLAY/PAUSE/PROGRESS 播放指令。
- 稳定性：构建期 ChangeNotifier 通知延迟到帧末，修复资料库进入时的 FlutterError；回滚滚动缓存实验。

### 下载
Windows EXE、macOS（universal / x86_64）、Linux AppImage（x86_64 / aarch64）、Android universal APK、iOS unsigned IPA。

> 这是预发布版本，可能仍有不稳定；欢迎反馈问题。

---

**Full Changelog**: https://github.com/chuxuehaocai/Lazer/compare/v2.0.0-beta.2...v2.0.0-beta.3
"""

release = api("GET", "/releases/tags/v2.0.0-beta.3")
updated = api(
    "PATCH",
    f"/releases/{release['id']}",
    {"name": "Lazer 2.0.0 beta3", "body": summary, "prerelease": True},
)
print("name", updated["name"])
print("prerelease", updated["prerelease"])
print("assets", len(updated["assets"]))
print("body starts correctly", updated["body"].startswith("## Lazer 2.0.0 beta3\n\n第三个"))
print("body length", len(updated["body"]))
