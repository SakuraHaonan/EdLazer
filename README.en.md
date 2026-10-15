# Lazer

[简体中文](README.md) | [English](README.en.md)

> `nextgen` is the Flutter development version. Features and interfaces are still evolving.

A cross-platform music client with an embedded NetEase WEAPI/EAPI implementation.
No third-party API gateway is required. Tracks, artwork, lyrics and recommended
playlists come from the service.

## Features

- Live catalogue, search, recommended playlists, accounts and favorites.
- Synchronized lyrics, translations, word timing and multi-line lyric copying.
- System media controls on Android, iOS, Windows, macOS and Linux.
- Simplified Chinese, Traditional Chinese, Japanese and English interfaces.
- Adjustable scroll inertia, lyric blur, automatic following and haptic feedback.

## Development

Use **Flutter 3.47.0 stable**.

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

## Automated builds

Pushes to `nextgen` trigger [GitHub Actions](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml).
Checks run before platform builds. Output filenames follow `Lazer-<OS>-<Arch>`.

| Output | Contents |
| --- | --- |
| `Lazer-Windows-x86_64.zip` | EXE, DLLs, resources and Visual C++ runtime |
| `Lazer-macOS-universal.zip` | Universal Intel / Apple Silicon App |
| `Lazer-macOS-x86_64.zip` | Intel App built on a native Intel runner |
| `Lazer-Linux-x86_64.AppImage` | Linux x86_64, including GTK and libmpv |
| `Lazer-Linux-aarch64.AppImage` | Linux ARM64 built on a native ARM runner |
| `Lazer-Android-universal.apk` | Universal APK using the current development signing configuration |
| `Lazer-iOS-aarch64.ipa` | Unsigned device IPA |

Download from a completed run's **Artifacts** section while signed in to GitHub.
Artifacts are retained for 30 days. Extract the complete Windows ZIP before
launching its EXE. Run `chmod +x` on a downloaded AppImage. macOS Apps are ad-hoc
signed; the IPA requires your own signing before installation.
See [build details](docs/builds.md) and [system media integration](docs/system-media.md).

## References

The protocol implementation references [API Enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced).
Lyric animation references [Apple Music Like Lyrics](https://github.com/amll-dev/applemusic-like-lyrics).
The application uses **MiSans** by Xiaomi.

Original project code is licensed under the [MIT License](LICENSE).
