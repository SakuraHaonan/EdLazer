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

Full refraction needs Impeller and Flutter GPU:

- Android: `EnableImpeller` and `EnableFlutterGPU` in the manifest.
- macOS: `FLTEnableImpeller` and `FLTEnableFlutterGPU`.
- iOS source: `FLTEnableFlutterGPU` (the app does not ship an iOS package).

Linux and Windows builds do not have that manifest switch. On those
desktops, and in `flutter test` without `--enable-impeller
--enable-flutter-gpu`, the package paints `FakeGlass`: the same silhouette
without the bend. High contrast uses the regular preset at full tint so
the labels stay readable.
