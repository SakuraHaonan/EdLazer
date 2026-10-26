# 大屏幕模式 (Large screen mode, Android TV)

The television presentation is called **大屏幕模式** in the interface. The same
APK runs on phones, tablets, car head units and Android TV; a Leanback or
touch-less Android device selects 大屏幕模式 by itself, and
`设置 → 界面 → 设备形态 → 大屏幕模式` forces it anywhere else.

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

`LEANBACK_LAUNCHER` puts the app on the Leanback home screen;
`@drawable/tv_banner` is the 320×180 banner the launcher shows. Both are
ignored on phones.

## Detection and the default mode

`lib/tv/tv_mode.dart` asks the platform over `dev.naominet.lazer/tv`.
`MainActivity.isTelevision()` answers true when any of these hold:

- `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION`;
- `FEATURE_LEANBACK` (the official Android TV flag);
- `FEATURE_TELEVISION` or `android.hardware.type.television`;
- there is no touch screen and no fake-touch input, so the only way through
  the app is a D-pad.

The channel has an 800 ms timeout and every failure means "not a TV", so
desktop, iOS and tests are unaffected.

A detected television **boots into 大屏幕模式**. `AppState.bootstrap` writes
`surface = AppSurface.tv` when no `lazer_surface` preference exists yet; an
explicit choice (including `自动选择`) is never overwritten. `TvScope` then
publishes the remote input model, `UiMetrics` publishes the density profile,
and the shell draws the large-screen composition.

## The interface

The large-screen mode is its own composition, not the desktop shell stretched:

- a floating **destination capsule** at the top: 现在就听 / 资料库 / 我喜欢 /
  设置 / 正在播放 plus a magnifier, with the selected destination inverted
  (dark-on-light, light-on-dark) and the account avatar at the left. A back
  pill appears in front of the avatar while a detail is open;
- **shelves** of large artwork: 为你打造 shortcuts, 精选推荐 cards whose
  captions sit on a dark plate, 最近播放, 新发行, 排行榜, 猜你喜欢, 网易云编辑精选.
  Four feature cards fit a 1080p panel; the fifth peeks in to advertise the
  horizontal scroll;
- a **library rail** (最近添加 / 播放列表 / 歌手 / 专辑 / 歌曲, then 本地音乐 and
  我喜欢的音乐) beside a centred artwork grid;
- a **transport shelf** under the content: cover and title (opens the player),
  previous / play / next, the seek rail, like, queue and expand;
- detail pages with a 256 dp hero and 64 dp track rows. Settings, local music
  and comments reuse their existing controls at a larger reading measure.

The immersive player (正在播放) is intentionally unchanged: it already owns the
screen and its own focus model.

Metrics live in `LargeScreenMetrics` and the type ramp in `LargeScreenType`
(`lib/tv/large_screen_widgets.dart`). The deck is a 40 dp display title, a
26 dp section heading and a 20 dp card title; the desktop ramp is 34/20/17.

## Remote navigation

`lib/tv/tv_mode.dart` provides the input pieces:

| Widget | Job |
| --- | --- |
| `TvScope` | Publishes whether the remote model is active. Off a TV every helper collapses to its child. |
| `LargeScreenTapTarget` | The large-screen control: `TvTapTarget` for the remote (focus stop, `ActivateIntent`, focus ring, slight lift) plus the pointer tap target the cards do not bring themselves. |
| `TvFocusRegion` | Per-page focus anchor: the first actionable descendant takes focus when a page appears, a section changes or the player closes. It does not steal focus once the user has moved. |
| `TvTraversalScope` | Installs `LargeScreenTraversalPolicy`. It must sit **inside** the route: MaterialApp's navigator puts its own traversal group around every page, so a group above the MaterialApp is never consulted. The shell therefore wraps its own tree. |

`LargeScreenTraversalPolicy` follows the geometry rather than the build order:

- left/right stay inside a shelf, up/down land on the card physically above or
  below, and reversing direction retraces the previous path;
- when a move has no target (a lazily built list only creates children near the
  viewport), the nearest scroll view on the matching axis is nudged by most of
  a viewport. The next press continues from the revealed items — "bump to
  scroll";
- focus is revealed with `revealTvFocus`, which scrolls only when the target is
  actually outside its viewports.

Other remote behaviour:

- **Select** activates the focused card, chip or glyph. **Back** closes, in
  order: the queue/volume overlay (`TvOverlayStack`), the player, detail
  pages, then returns a non-home destination to 现在就听; at the root it leaves
  the app.
- **Seek rail** — left/right step the playhead by 2% (`LegacyThinSeekBar`);
  up/down leave the rail. The rail commits the value as it steps.
- **Search** — the magnifier chip opens the search page. Its `SearchBar` is a
  normal focus stop; Select enters text and raises the system IME.
- **Queue** — Select on the transport's queue glyph opens the floating queue
  card; its rows and close button are focus stops.
- **Settings** — every dropdown, switch, slider and swatch remains a focus
  stop; the D-pad opens dropdowns and moves sliders.

## Verification

`test/large_screen_test.dart` covers:

- the rename (`大屏幕模式`), and the television default with and without a stored
  surface choice;
- the capsule, shelves, transport, library rail and search page rendering;
- Select on the page's first focused card, and Up/Down crossing between content
  and the capsule;
- geometry-driven D-pad traversal (left/right in a row, down to the card below)
  and the bump-to-scroll fallback past the built children;
- reflow at 1280×720 and at a phone-width 800×600 window.

`test/android_tv_test.dart` keeps the packaging checks, the focus target,
overscan insets, seek stepping and overlay close order.

## Tuning

- `LargeScreenMetrics.pageInset` — page gutter (42–84 dp by width).
- `LargeScreenMetrics.featureCardWidth` / `artworkCardWidth` — shelf sizing.
- `LargeScreenMetrics.railWidth` — library rail width.
- `tvSafeInsets` — 24×16 dp overscan breathing room.
- `TvFocusRegion.focusToken` — what re-anchors focus when a page changes.
- `LargeScreenTraversalPolicy._scrollToward` — the bump distance (62% of a
  viewport) and duration.
- `TvTapTarget.focusScale` / `borderRadius` — per-surface focus lift and ring
  shape.

## Limitations

- Text entry (search, login) uses the system IME, so a TV needs its on-screen
  keyboard. The app does not draw its own grid keyboard.
- Remote media keys are handled by the existing `audio_service` integration,
  not by this layer; play/pause/next/previous work while the screen is off.
- Detection relies on the Android TV signals above. Other television platforms
  keep the standard layout until the profile is chosen manually.
