# Scan (QR) sign-in

How the sign-in card gets a phone confirmation back into the app, and what the
official client actually does — verified against the NetEase Cloud Music APK
9.6.08 (`com/netease/cloudmusic/module/barcode/g`, `asynctask/k0`,
`api/impl/NeteaseMusicApiImpl.k3`) and the local api-enhanced 4.41.0 copy.

## The three hops

1. **Mint a key** — `POST /api/login/qrcode/unikey` (`type=3`). The reply is a
   scan key and the `NMTID` cookie that owns the scan session.
2. **Show the QR** — `https://music.163.com/login?codekey=<key>&login_traceId=<trace>`.
3. **Poll** — `POST /api/login/qrcode/client/login` with `key`, `type=3` and the
   same `clientTraceId`.

## What the phone does with the code

The app recognises scan URLs that start with `http(s)://music.163.com/login`
and reads three query parameters off them:

| URL parameter   | Used as                        |
| --------------- | ------------------------------ |
| `codekey`       | the scan key                   |
| `login_traceId` | `clientTraceId` on the confirm |
| `chainId`       | login monitor context only     |

It then confirms with `POST login/qrcode/server/login`:

```
key=<codekey>
type=1
userid=<account id>
checkToken=<anti-cheat token>
clientTraceId=<login_traceId from the URL>
```

So `login_traceId` is the only URL value that travels into the confirmation.
A QR minted without it leaves the server with nothing to bind the scan to, the
poll never leaves 801/802, and the desktop never sees 803 — which is exactly
the "scan works, login never arrives" failure.

## What this client sends

- `createQrKey()` → `/login/qr/key`, no `platform`: the plain `pc` scan URL.
- `createQrCodeUrl()` → `https://music.163.com/login?codekey=…&login_traceId=…`
  where the trace is a fresh v4 id per session (`_qrLoginUrl` in
  `lib/gateway/transport.dart`). A `chainId` is appended only for the `web`
  platform **and** a real `sDeviceId` in the session — never fabricated.
- `checkQrCode(key, clientTraceId: trace)` → the poll; if a gateway rejects the
  trace field the plain poll runs instead (compatibility, no feature loss).
- On 803 the session cookie is adopted, `/login/status` is retried a few times
  (the account endpoint trails the confirmation), and a spent key that answers
  800 still gets one adoption attempt.
- Poll failures are surfaced in the card (`二维码服务暂时无法连接`) instead of
  being silently reported as "waiting".

## Operational notes

- The poll stores every cookie the confirmation rotates (`MUSIC_U`,
  `__csrf`/`__csrf_token`, `NMTID`, `_ntes_nuid`, …); dropping them loses the
  login even after 803.
- A locally minted key is valid for about three minutes; the card polls for
  180 s and lets the server's own 800 answer decide.
- `/login/refresh` cannot extend a scan session — re-scanning is the only way.
