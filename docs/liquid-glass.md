# Liquid glass

The floating music bar and the phone tab bar use
[`liquid_glass_renderer`](https://pub.dev/packages/liquid_glass_renderer)
**1.0.0-dev.2** (Apache-2.0).

- Repository: <https://github.com/whynotmake-it/flutter_liquid_glass>
- Package path: `packages/liquid_glass_renderer`
- Publisher: whynotmake.it
- License text shipped with the app: `licenses/liquid_glass_renderer/LICENSE`
- The package also carries Inigo Quilez's SDF notice and a Flutter shader
  notice, copied beside that license.

EdLazer does not reimplement the bevel. Each capsule is a
`LiquidGlass` on one shared layer, using the package's fitted iOS 27
**regular** preset (`LiquidGlassSettings.ios27Regular` and
`LiquidGlassAppearance.ios27Regular` at slider position 0). That is the
material the renderer matches to toolbars and tab bars: the backdrop stays
visible, with a light frost, and the bevel refracts it. The selected tab
is a second, smaller layer using the example tab bar's loupe settings
(`refractionHeight: 15`, `refractionAmount: 10`, `dispersion: -0.3`,
`backdropShrink: 0.14`, `frost: 0`), from
`example/lib/bottom_bar/loupe_tab_bar.dart` in the same package. The loupe
slides on EdLazer's critically damped curve. The example's bouncy spring
is not used.

Full refraction needs Impeller and the preview Flutter GPU API. The
package's own requirements (1.0.0-dev.2) test that path on iOS, Android and
macOS. The engine enables Flutter GPU from `FLTEnableFlutterGPU` (iOS and
macOS Info.plist) or `io.flutter.embedding.android.EnableFlutterGPU`
(AndroidManifest). Those three switches are set. This repository does not
ship an iOS package.

Flutter 3.47 turns Impeller on by default for Linux and Windows, but the
embedder APIs that ship with that SDK (`fl_dart_project_set_enable_impeller`,
`DartProject::set_impeller_switch`) have no Flutter GPU switch. A release
AppImage or Windows zip therefore cannot turn the 1.0 renderer on.
`flutter test` and `flutter run` can pass `--enable-flutter-gpu`; that flag
is not baked into those two binaries. Where Flutter GPU is off, this package
paints `FakeGlass`. That path keeps frost, tint and the rim, and it does
not refract. It is not the same effect.

Checked alternatives, none of which add genuine backdrop refraction to the
Windows and Linux binaries:

- `liquid_glass_renderer` 0.2.x was replaced by this 1.0 rewrite. The
  current maintained line is the Flutter GPU one.
- `liquid_glass_widgets` (MIT) documents Windows and Linux as the
  lightweight `GlassQuality.standard` shader. Its own docs say that shader
  does not refract arbitrary content behind the glass the way
  `GlassQuality.premium` does, and the adaptive default caps those two
  desktops to standard.

High contrast uses the regular preset at full tint so the labels stay
readable.
