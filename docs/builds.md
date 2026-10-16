# Automated builds

[Build nextgen](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml)
runs for pushes and pull requests targeting `nextgen`, manual
`workflow_dispatch` runs, and `v*` version tags. Flutter is pinned to
**3.47.0 stable**. A successful run for a `v*` tag creates a GitHub Release
with all platform binaries and SHA-256 files. A tag containing a hyphen, such
as `v2.0.0-beta.1`, is published as a pre-release. Set the matching app version
in `pubspec.yaml` before pushing the tag so the binaries report the same version.

Analysis and tests run first. Seven independent platform/architecture builds then
upload the following **Artifacts**. Each binary/archive has its own SHA-256 file.

| Artifact / filename stem | Format and contents |
| --- | --- |
| `Lazer-Windows-x86_64` | ZIP with EXE, DLLs, resources and the MSVC runtime |
| `Lazer-macOS-universal` | ZIP with an Intel / Apple Silicon App |
| `Lazer-macOS-x86_64` | ZIP with a native Intel App |
| `Lazer-Linux-x86_64` | x86_64 AppImage with GTK and libmpv |
| `Lazer-Linux-aarch64` | ARM64 AppImage with GTK and libmpv |
| `Lazer-Android-universal` | Universal release APK using the development signing configuration |
| `Lazer-iOS-aarch64` | Unsigned device IPA containing `Payload/Runner.app` |

All artifact names follow `Lazer-<OS>-<Arch>`. `universal` denotes a multi-architecture
package. The macOS archives preserve executable permissions and framework symlinks.
Architecture checks run before packaging. IPA builds explicitly disable code signing.

## Runners and SDKs

- Windows uses `windows-2022`.
- macOS universal uses `macos-15`; Intel uses `macos-15-intel`.
- Linux uses native `ubuntu-22.04` / `ubuntu-22.04-arm` runners. Both AppImages have
  a glibc 2.35 baseline. The ARM runner bootstraps the SDK from the official Flutter
  3.47.0 tag and verifies its commit, since the official archive only provides an
  x64 Linux SDK. It does not cross-compile or use a third-party SDK.
- Android uses `ubuntu-24.04` with Java 21; iOS uses `macos-15`.

Linux packaging pins linuxdeploy and its GTK helper, checks the packaging tool's
SHA-256, and explicitly bundles libmpv because it is loaded through FFI. Each
AppImage must start under Xvfb and a session D-Bus before it is uploaded.

## Downloading

Open a completed branch run and download from **Artifacts** while signed in to
GitHub. These artifacts are retained for 30 days. Version-tag runs also attach
the artifacts to their GitHub Release; the release job has write access only to
download its workflow artifacts and publish that release.

Extract the whole Windows ZIP before launching the EXE. Downloaded AppImages need
`chmod +x`. macOS Apps are ad-hoc signed, not Developer ID signed/notarized. The
unsigned IPA needs your own signing before installation.
