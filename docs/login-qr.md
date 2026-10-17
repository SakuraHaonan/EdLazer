# Scan (QR) sign-in

How the sign-in card gets a phone confirmation back into the app, checked
against the official clients:

- **Desktop** — `C:\Program Files\NetEase\CloudMusic\package\orpheus.ntpk`
  (a ZIP holding the CEF UI; `pub/hybrid/28.chunk` is `page:loginQrcode`,
  `42/43.chunk` draw the code).
- **Android** — APK 9.6.08, `module/barcode/g`, `asynctask/k0`,
  `api/impl/NeteaseMusicApiImpl.k3`.

## The desktop flow, verbatim

| Step | Call | Notes |
| --- | --- | --- |
| Mint | `POST /api/login/qrcode/unikey` | body `type: 3` (Windows) / `4` (macOS), optional `lastUniKey` |
| Show | `https://music.163.com/login?codekey=<unikey>` | nothing else in the URL |
| Poll | `POST /api/login/qrcode/client/login` | every **1000 ms**, body `key`, `type`, `secureCaptcha` |
| Finish | `POST /api/w/nuser/account/get` | after 803, reads `account` / `profile` / `bindings` |

Status codes the client branches on: `800` expired, `801` waiting, `802`
scanned, `803` confirmed, `8821` risk control (it opens a Yidun captcha and
retries with `secureCaptcha`), anything else is an error.

The phone recognises `http(s)://music.163.com/login` + `codekey` and confirms
through `POST login/qrcode/server/login` with `key`, `type=1`, `userid`,
`checkToken` and `clientTraceId` (an optional `login_traceId` from the URL that
the desktop never sets — it is telemetry, not a binding value).

## What this client does

The whole flow lives on the **plain `/api/` surface**, like the desktop client:

- `createQrKey()` → `/api/login/qrcode/unikey`, `type: 3`.
- `createQrCodeUrl()` → `https://music.163.com/login?codekey=<unikey>`.
- `checkQrCode()` → `/api/login/qrcode/client/login` with `key`, `type: 3`,
  `secureCaptcha`; the card polls once a second starting immediately.
- On 803 the session cookie from the poll is installed, `/login/status`
  (`/api/w/nuser/account/get`) is retried a few times because the account
  endpoint trails the confirmation, and a spent key that answers 800 still gets
  one adoption attempt.
- The card reports `8821` as "scanned, waiting for the phone" and a failed poll
  as a visible "service unreachable, retrying" line instead of silent 801.

**Why the plain surface matters:** the QR endpoints used to run through the
eapi envelope (`interfacepc.music.163.com/eapi/…`) because that is what
api-enhanced does. Every client that actually completes the flow — the desktop
client, the browser, music-lib — uses the plain `music.163.com/api/…` form, and
only that surface hands the confirmed login back to the poller. The envelope
route answers 801 forever, which is exactly "the phone confirmed but the
desktop stayed a guest".

## Operational notes

- The poll keeps every cookie the confirmation rotates (`MUSIC_U`,
  `__csrf`/`__csrf_token`, `NMTID`, `_ntes_nuid`, …); dropping them loses the
  login even after 803.
- A minted key lives about three minutes; the card polls for 180 s and lets the
  server's own `800` decide.
- `/login/refresh` cannot extend a scan session — a new scan is the only way.
- Risk control (`8821`) needs a captcha solved on the account's side; the
  desktop opens Yidun for it, this client asks for a fresh scan instead.
