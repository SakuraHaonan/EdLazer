# Automated builds

[Build nextgen](https://github.com/SakuraHaonan/EdLazer/actions/workflows/build.yml)
runs for pushes and pull requests targeting `nextgen`, manual
`workflow_dispatch` runs, and `v*` version tags. Flutter is pinned to
**3.47.0 stable**. A successful run for a `v*` tag creates a GitHub Release
on this fork with the platform binaries and SHA-256 files. A tag containing a
hyphen, such as `v2.0.0-beta.1`, is published as a pre-release. Set the
matching app version in `pubspec.yaml` before pushing the tag so the binaries
report the same version. The app itself never queries that release.

Analysis and tests run first. The platform jobs then upload the following
**Artifacts**. Each binary/archive has its own SHA-256 file.

| Artifact / filename stem | Format and contents |
| --- | --- |
| `EdLazer-Windows-x86_64` | ZIP with EXE, DLLs, resources and the MSVC runtime |
| `EdLazer-macOS-universal` | ZIP with an Intel / Apple Silicon App |
| `EdLazer-macOS-aarch64` | ZIP with a native Apple Silicon App |
| `EdLazer-macOS-x86_64` | ZIP with a native Intel App |
| `EdLazer-Linux-x86_64` | x86_64 AppImage with GTK and libmpv |
| `EdLazer-Linux-aarch64` | ARM64 AppImage with GTK and libmpv |
| `EdLazer-Android-universal` | Universal release APK using the development signing configuration |
| `EdLazer-Android-arm64-v8a` | arm64-v8a release APK using the development signing configuration |
| `EdLazer-iOS-aarch64` | Unsigned device IPA containing `Payload/Runner.app` |

All artifact names follow `EdLazer-<OS>-<Arch>`. `universal` denotes a multi-architecture
package. The macOS archives preserve executable permissions and framework symlinks.
Architecture checks run before packaging.

## Build stamp

Every platform build receives the commit it was cut from through
`--dart-define=EDLAZER_COMMIT=<sha>`, and **Settings → About** shows its short
form. Tag builds also receive `--dart-define=EDLAZER_VERSION=<tag>`, which
About displays as-is. The tag and `pubspec.yaml` must agree so the binary
reports the version it was cut from. A local `flutter run` that omits the
defines falls back to the checked-in values in `lib/diagnostics/build_info.dart`.

## Publishing a build

1. Set `version:` in `pubspec.yaml` to the tag without its `v` prefix and bump
   the build number (for example `2.0.0-beta.16+16`).
2. Commit, then push an annotated tag with the same version (`v2.0.0-beta.16`).
3. The build workflow runs every platform job. Only when all of them pass does
   the release job attach the artifacts; a tag containing `-` becomes a
   pre-release.

The installed app does not look for that release. People download it
themselves. See [updates.md](updates.md).


## Runners and SDKs

- Windows uses `windows-2022`.
- macOS and iOS builds use `macos-15-intel`. Apple Silicon and universal
  Mac apps are cross-compiled there, and `lipo` checks the slices. The Mac
  jobs run one at a time, and the iOS job starts after them. `macos-15` is
  not acquiring a runner for this repository.
- Linux uses native `ubuntu-22.04` / `ubuntu-22.04-arm` runners. Both AppImages have
  a glibc 2.35 baseline. The ARM runner bootstraps the SDK from the official Flutter
  3.47.0 tag and verifies its commit, since the official archive only provides an
  x64 Linux SDK. It does not cross-compile or use a third-party SDK.
- Android uses `ubuntu-24.04` with Java 21 and produces both an arm64-v8a
  APK and a universal APK.
- iOS uses `macos-15`. The IPA build disables code signing and packs
  `Payload/Runner.app`. It is not a signed or App Store package.

Linux packaging pins linuxdeploy and its GTK helper, checks the packaging tool's
SHA-256, and explicitly bundles libmpv because it is loaded through FFI. Each
AppImage must start under Xvfb and a session D-Bus before it is uploaded.

## Downloading

Open a completed branch run and download from **Artifacts** while signed in to
GitHub. These artifacts are retained for 30 days. Version-tag runs also attach
the artifacts to their GitHub Release; the release job has write access only to
download its workflow artifacts and publish that release.

Extract the whole Windows ZIP before launching the EXE. Downloaded AppImages need
`chmod +x`. macOS Apps are ad-hoc signed, not Developer ID signed/notarized.
The unsigned IPA needs your own signing before installation.
