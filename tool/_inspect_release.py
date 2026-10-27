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

release = api("GET", "/releases/tags/v2.0.0-beta.3")
body = release.get("body") or ""
print("id", release["id"], "body length", len(body))
print("first 160:", repr(body[:160]))
idx = body.find("\n---\n")
print("separator", idx)
if idx >= 0:
    print("after separator:", repr(body[idx + 5 : idx + 260]))
