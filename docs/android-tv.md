# Android TV

The same APK runs on phones, tablets, car head units and Android TV. On a
television the app keeps the standard interface scale and makes every control
reachable with a D-pad remote; everywhere else nothing changes.

## Packaging

`android/app/src/main/AndroidManifest.xml` tells Android the app belongs on a
TV home screen while staying installable on touch devices:

```xml
<uses-feature android:name="android.software.leanback" android:required="false" />
<uses-feature android:name="android.hardware.touchscreen" android:required="false" />
<uses-feature android:name="android.hardware.gamepad" android:required="false" />

<application android:banner="@drawable/tv_banner" ...>
  <activity ...>
    <intent-filter>
      <action android:name="android.intent.action.MAIN" />
      <category android:name="android.intent.category.LAUNCHER" />
      <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
    </intent-filter>
  </activity>
</application>
```

`LEANBACK_LAUNCHER` is what puts the app on the Leanback home screen;
`@drawable/tv_banner` is the 320×180 banner the launcher shows. Both the
launcher category and the banner are ignored on phones. Leanback and the touch
screen are declared optional so one artifact covers every shape.

## Detection

`lib/tv/tv_mode.dart` asks the platform over `dev.naominet.lazer/tv`.
`MainActivity.isTelevision()` answers true when any of these hold:

- `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION`;
- `FEATURE_LEANBACK` (the official Android TV flag);
- `FEATURE_TELEVISION` or `android.hardware.type.television`;
- there is no touch screen and no fake-touch input, so the only way through
  the app is a D-pad.

The last rule covers cheap set-top boxes that ship without the Leanback
feature flag. The channel has an 800 ms timeout and every failure means "not a
TV", so desktop, iOS and tests are unaffected.

Detection is separate from the density choice. `TvScope` publishes the input
model (`active`), while `UiMetrics` publishes the density profile. A TV told to
use standard density keeps its remote navigation; a touch device can force the
television surface for testing.

## Television interface

`设置 → 界面 → 设备形态` offers `自动选择 / 标准 / 车机 / 电视`. The
television profile:

- keeps the **standard interface scale**. Unlike a car head unit, a television
  panel is already large and viewed at a distance; forcing a density floor
  would make the interface unnecessarily huge. The DPI slider and the
  automatic estimate still apply when the user wants a larger interface;
- uses a **wider browse column** (`adaptiveContentMaxWidth`, 1560 dp instead of
  the desktop reading measure). The home shortcuts share that width instead of
  huddling at the left, and the library grid fits more artwork per row without
  changing any font size;
- resolves before the car heuristic: both are large, low-density landscape
  panels, but only a television is driven by a remote
  (`resolveDeviceProfile`);
- insets the shell and the immersive player by `tvSafeInsets` — 24×16 dp —
  because Android TV reports no safe insets yet many panels still overscan.

## Remote navigation

Flutter gives every `InkWell` and `IconButton` a focus node, but most of this
interface is custom artwork, rows and cards drawn with `GestureDetector` — a
remote can never reach those. `lib/tv/tv_mode.dart` adds three pieces:

| Widget | Job |
| --- | --- |
| `TvScope` | Publishes whether the remote model is active. Off a TV every helper below collapses to its child. |
| `TvTapTarget` | Adds a focus stop, `ActivateIntent` (Select/Enter) handling, a slight focus lift and the white-on-black focus ring. Used by rail rows, playlist/track cards, queue rows, transport glyphs and pane tabs. |
| `TvFocusRegion` | A non-focusable `Focus` node per page. When a page appears or returns to the front (`focusToken`), it focuses the first actionable descendant, so the first D-pad press lands somewhere useful. It retries when a page swaps a loading notice for real controls, and it does not steal focus once the user has moved somewhere. It is not a `FocusScope`, so focus can still leave the content for the sidebar and transport bar. |
| `TvTraversalScope` | Replaces the default traversal callback with `revealTvFocus`: the new target is focused and its ancestor viewports are asked to `showOnScreen` for 160 ms. Flutter's stock callback aligns every target to the viewport edge, which makes rows jump even when they are already visible; the TV version scrolls only when the target is actually outside. |

The ring is white with a black halo (`TvFocusOutline`): white alone disappears
over light artwork and black alone disappears over the dark player.

Remote behaviour by surface:

- **Seek rail** — left/right steps the playhead by 2% (`LegacyThinSeekBar`,
  `_nudge`); the preview stays pinned for 900 ms while the engine finishes the
  seek. Material `Slider`s (the immersive player's rail and the desktop volume
  slider) already answer to arrow keys when focused.
- **Volume** — Select opens the vertical volume column; up/down step it; the
  pending value is committed when the panel closes.
- **Queue** — Select on the queue glyph opens the floating queue card; rows and
  the close button are focus stops.
- **Back** — one `PopScope` in the shell consumes it in this order: overlay
  panels (queue, volume), the player, detail pages, then the 发现 root. Only at
  the root does it leave the app. `TvOverlayStack` exists because overlay
  entries are siblings of the route and never receive a system pop.
- **Settings** — each dropdown, switch, slider and swatch is a normal focus
  stop; the D-pad opens dropdowns and moves the slider.

## Verification

`test/android_tv_test.dart` covers focus + Select activation, the inert
off-TV path, safe insets, D-pad seek stepping, late-content focus anchoring,
minimal scroll reveal, overlay close order, and a static check that the
Leanback category, optional touch/leanback features and the banner ship in the
manifest. The rest of the suite runs unchanged because every TV helper is a
no-op outside `TvScope`.

## Tuning

- The television profile has no density floor of its own; adjust
  `kCarScaleMin` only for the car profile, or use the DPI slider for a TV.
- `tvSafeInsets` — overscan breathing room.
- `TvFocusRegion.focusToken` — what re-anchors focus when a page changes.
- `revealTvFocus` — the scroll-into-view duration and curve for every D-pad
  move.
- `TvTapTarget.focusScale` / `borderRadius` — per-surface focus lift and ring
  shape.

## Limitations

- Text entry (search, login) uses the system IME, so a TV needs its on-screen
  keyboard. The app does not draw its own grid keyboard.
- Remote media keys are handled by the existing `audio_service` integration,
  not by the TV layer; play/pause/next/previous work while the screen is off,
  exactly as on a phone.
- The television profile is selected by the Android TV signal only. Other
  television platforms keep the standard layout until they report one.
