# Lazer

[简体中文](README.md) | [English](README.en.md)

> `nextgen` is the Flutter development version. Features and interfaces are still evolving.

A cross-platform music client with an embedded NetEase WEAPI/EAPI implementation.
No third-party API gateway is required. Tracks, artwork, lyrics and recommended
playlists come from the service.

## Features

- Live catalogue, search, recommended playlists, accounts and favorites.
- Artist profiles with popular tracks and paged albums, plus album descriptions and full track lists; open them from artist or album names.
- Synchronized lyrics, translations, word timing, multi-line copying and lyric image export.
- Adjustable lyric font size and weight, with a live preview and saved preferences.
- Desktop listening workspace with a full-width playback dock, shared lyrics/comments/queue panes and saved volume levels.
- Popular and latest comments with pagination, likes and unlikes; guests can read and sign in to react.
- System media controls on Android, iOS, Windows, macOS and Linux.
- Simplified Chinese, Traditional Chinese, Japanese and English interfaces.
- Adjustable scroll acceleration and momentum, lyric blur, 5ms follow checks and smooth line transitions.
- Haptics on controls and seek detents, with adjustable intensity on iOS.
- Layout override (automatic / desktop / mobile), DPI scaling (80–175%) and a car head-unit profile that starts at 135% with roomier controls.
- Switchable interface style: Nextgen UI by default, or the Legacy UI ported from the Lazer project (dark Material 3, left rail and transport bar).
- A mobile Favorites shortcut, with automatic caching of audio, artwork, lyrics and playlists.

Completed audio downloads play locally; the first play streams while caching in the background.
The cache keeps up to 1 GiB of audio, 256 MiB of artwork and 64 MiB of catalogue data,
evicting the least recently used files. Playlist tracks stay fresh for 10 minutes,
account collections for 5 minutes and the home feed for 20 minutes. Expired data is
refreshed, with the previous snapshot retained if the network fails. Playlist details
also offer manual refresh. Account data is separated by session. Files live in the
system application cache directory and are fetched again if the system removes them.

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
Checks run before platform builds. Pushing a `v*` version tag creates a GitHub
Release after every build succeeds; tags with a suffix such as `-beta.1` are
marked as pre-releases. Output filenames follow `Lazer-<OS>-<Arch>`.

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
