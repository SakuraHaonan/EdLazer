# Legacy UI

The app ships one interface: the Legacy UI, ported from the Lazer project
(Compose Multiplatform). There is no interface-style switch. The desktop
now-playing page deliberately uses an Apple Music-inspired local theme (album
flow backdrop, system font, white controls, red accent); it keeps the shell,
state and shared lyric/queue/comment implementations.

## Where the legacy UI comes from

The Lazer project is a Compose Multiplatform app; its interface cannot run
inside a Flutter tree, so the shell was re-created in Dart against the same
tokens and structure:

| Legacy source | Port |
| --- | --- |
| `LazerTheme.kt` — `LazerTokens`, `LightColors`/`DarkColors`, `LazerTypography` | `lib/legacy/legacy_theme.dart` |
| `DesktopPlayerApp.kt` — window layout, rail, top bar, player bar | `lib/legacy/legacy_shell.dart` |
| `DesktopPlayerApp.kt` — home, library, settings pages | `lib/legacy/legacy_pages.dart` |
| `LazerApp.kt` — login overlay, now-playing page | `lib/legacy/legacy_login.dart`, `lib/legacy/legacy_now_playing.dart` |
| shared cards, track rows, covers, transport | `lib/legacy/legacy_widgets.dart` |

The palette is the legacy one — lake-blue `#5F91AC` by day, `#9CCDE4` at night,
warm paper neutrals and a clay tertiary — and it is a complete Material 3 role
set. Every surface role (`surfaceContainerLowest` through `surfaceBright`,
inverse and fixed roles) has an explicit tone, so no Flutter widget can fall
back to the purple baseline scheme. One radius scale (4 / 8 / 12 / 16 / 20 / 28)
and one component theme set replace the previous mix of paper cards, custom
buttons and per-widget colours.

## Safe areas

The chrome column (rail, top bar, content, player bar and bottom tabs) is
wrapped in a `SafeArea` that only insets the top, so the rail and the search
bar start below the status bar or notch on phones while the album backdrop
stays full-bleed behind everything. The bottom is left to the chrome: the
`NavigationBar` consumes the bottom safe area internally, and desktop windows
have none. The now-playing page insets itself the same way.

## What the legacy shell covers

- **Rail** with the Lazer wordmark, 主页 / 音乐库 / 我喜欢, the signed-in
  playlist list, refresh, and 设置 at the bottom (`208 dp`, folds into a
  bottom `NavigationBar` under 760 dp).
- **Top bar** with the search field (350 ms debounce), the theme toggle and the
  account menu (login, sign out, settings).
- **主页** — `今天为你整理` playlist rail plus the quick-pick track list.
- **音乐库** — liked / created / subscribed playlists and the recommended ones.
- **我喜欢** and any playlist page with a play-all header.
- **搜索** — tracks, playlists and albums for the query.
- **正在播放** — two compositions:
  - **Desktop** (window at least 1000 dp wide and landscape, unless the layout
    is forced to mobile) is an Apple Music-inspired immersive player and an
    intentional local exception to the Material 3 theme: the shell's animated
    `AlbumFlowBackground` palette flow (`AlbumBlurFlow`) fills the window under
    a dark Apple scrim; a large shadowed cover, centred title / translation /
    artists / album and the like, save and more actions sit on the left; the
    shared lyric sheet floats on the right without a card, with larger lyrics,
    no distance blur, a system-font Apple type ramp and a single Apple Music red
    accent for the liked state. The transport is a transparent strip with a
    thin white seek rail, a white circular play button and plain white controls;
    the queue and comments open as a docked translucent panel above the
    transport. Global shortcuts: Space (play/pause), ←/→ (5 s, Shift for 15 s),
    ↑/↓ (volume), M (mute), L (like), Q (queue), C (comments), F (fullscreen),
    Esc (close).
  - **Mobile** keeps the Lazer page: landscape is the 44 / 56 information +
    lyric split; portrait puts close and like in the header, the title beside
    the resting 52 dp artwork, the lyric sheet in the middle, and the actions
    plus the 64 dp transport at the bottom. A song without lyrics opens its
    artwork instead of leaving an empty pane. The artwork is one node and flies
    between the header slot and a 320 dp centre over 420 ms.
  - Both compositions use the **shared `LyricViewport`** — word-level sweep,
    lyric selection with copy / image export, wheel and drag with the follow
    delay all come from one implementation. The desktop player passes page-local
    typography and disables the distance blur in favour of Apple's opacity fade;
    the mobile page keeps the user's lyric size/weight/blur preferences. Only
    the focused row repaints word timing; inactive rows are static cached
    rasters.
  - Queue and comments use the shared `PlaybackQueueView` / `SongCommentsView`.
    Seeking previews while dragging, lands on release, ticks haptically at 2.5%
    steps and paints the buffered lead-in. A guest who taps like is offered the
    legacy sign-in card.
- **Player bar** — the 84 dp `PlayerBar`: a 250 dp now-playing tile (cover 50,
  title, translation, artist) that opens the lyrics page, the centred transport
  (like, previous, 38 dp play, next, one play-mode cycle) over the thin seek
  row, and a 168 dp right group (volume popover, queue card, comments, lyrics).
  Its surface is `surface @ 0.96 × content opacity` with a 1 dp outline, so the
  album canvas reads through it. Under 1000 dp it folds to the compact form.
- **Queue** — the floating card above the bar hosts the shared
  `PlaybackQueueView`; **评论** opens the shared `SongCommentsView` as a content
  page, replacing the search bar the way the legacy comment page does.
- **Login** — QR card with the gateway calls, plus the cookie paste field.
  8821 (risk control) reads as "scanned, waiting".
- **Settings** — every preference in the legacy row style: accent palette
  (fixed / follow the cover), device form, layout mode, DPI scale (with reset
  and the automatic switch), the album backdrop and its opacity, theme,
  language, haptics, lyric controls, lyric size/weight/blur, follow delay,
  scroll inertia and acceleration, the account, a catalogue refresh and the
  port note. Rows stack label-over-control under 560 dp.

Everything above the pixels is shared: `AppState`, the catalogue, playback,
artwork loading and the DPI / car display profiles all still apply, and the
custom window frame follows the legacy colours.

## Album backdrop

The album-coloured canvas is ported too — `lib/legacy/legacy_background.dart`
against `AlbumFlowBackground.kt` and the seed extractor in `LazerBackgrounds.kt`.

- **Seed** — the current cover is fetched at 96 px, sampled on a 48 px grid,
  and bucketed by hue; the dominant bucket wins, weighted by saturation and
  how close its lightness is to mid-grey, then its saturation is boosted 1.25×.
  An achromatic cover keeps the legacy floor chroma. Results are cached per
  URL (24 covers), and the previous seed stays on screen until the next one
  decodes.
- **Ramp** — `flowColorsFromSeed` turns the seed into five colours of the same
  hue from 0.90 to 0.31 lightness, with chroma scaled around the seed's own
  saturation.
- **Flow** — four of the five colours drift as full-page radial gradients, each
  with its own phase offset, speed, orbit, scale pulse and rotation, painted in
  one `CustomPaint` pass at the display refresh rate; the fifth paints the base
  and a slow overlay. A track change crossfades the palette over 650 ms with a
  cosine ease. The old widget tree (five gradients × three transforms) was
  replaced so the backdrop no longer allocates composited layers or caps itself
  at 30 fps.
- **Veil** — the content-opacity setting composites the surface colour over the
  canvas at its square (70% → 0.49), so the tint reads through the chrome while
  text stays legible. The rail, the player bar and the bottom tabs turn
  translucent while the backdrop is on.
- **Settings** — `设置 → 界面 → 背景` chooses follow-the-track (flowing), a flat
  track colour, or off; `内容不透明度` (40–100%) controls the veil. Stored as
  `lazer_legacy_background` and `lazer_legacy_ui_alpha`.
- **Reduced motion** — `MediaQuery.disableAnimations` freezes the flow, which is
  also how the widget tests settle.

## Performance

The interface targets a **120 fps frame budget (8.33 ms)** even though a given
display may cap presentation lower (for example a 100 Hz panel can never show
120 distinct frames per second). The frame-rate meter in Settings reports the
real numbers: Flutter's `FrameTiming` build and raster durations, plus the
measured presented FPS. It is opt-in and starts when enabled.

The animation path avoids per-frame widget work wherever possible:

- **Lyrics** — only the focused row's `CustomPaint` repaints for word timing.
  The painter draws the unsung base once, every fully sung word once through a
  glyph clip, and only the word the playhead is crossing needs per-glyph mask
  layers. The old code paid a save layer per glyph across every visible row.
  Inactive rows sit behind a `RepaintBoundary`; their emphasis colour animates
  only while the row's spring travels. Plain LRC lines change from an 8 ms
  follow timer plus a seek lane, so a paused or plain-lyric page schedules no
  frames at all.
- **Backdrop** — a single `CustomPaint` draws the five gradients; the phase is
  driven by a ticker at the display refresh rate and only the painter is marked
  dirty. The old implementation built five `DecoratedBox`es inside fifteen
  `Transform`s and deliberately stepped at 30 fps.
- **Transport** — the player bar rebuilds structurally only; the seek row owns
  the 100 ms tick lane. Continuous volume drags preview through
  `AppState.previewVolume` (engine only) and persist once on release, instead
  of notifying the shell and writing prefs on every pointer move.
- **Artwork** — `LegacyCover`/`PlateArt` request the smallest CDN rendition that
  covers the painted size at the device pixel ratio (64…1024) instead of
  decoding a 1024² image for a 44 dp thumbnail. `ArtworkCache` now preserves the
  requested `param=NyN` in its key; it previously rewrote every URL back to
  1024, quietly downloading and decoding the largest JPEG for every thumbnail.
- **Apple player** — the immersive desktop page wraps only itself and its
  panels in a local system-font theme; the rest of the app remains on the shared
  Material 3 theme. Its backdrop is the shell's own `AlbumBlurFlow` wrapper
  around `AlbumFlowBackground`: one CustomPaint, display-rate phase, palette
  crossfade, plus two static scrim gradients for legibility. No full-screen
  image filter and no extra per-frame background work.
- **Lists** — home, playlist and search track lists use `SliverList.builder`,
  so a 1000-track playlist mounts only the rows on screen.
- **Accessibility tree** — structural `notifyListeners` and the 100 ms tick
  lane are separate, as before, keeping the Windows UIA tree stable.

## Accent palette

`设置 → 界面 → 配色` mirrors the legacy `LazerPalette` switch:

- **默认** — the fixed blue-grey scheme above.
- **跟随当前歌曲** — the backdrop's artwork seed feeds
  `ColorScheme.fromSeed` (the legacy `LazerPalette.NowPlaying`), so the whole
  Material scheme — accents, containers, surfaces — turns with the cover.
  Stored as `lazer_legacy_palette`; the seed itself is refreshed from the
  current cover each time the backdrop decodes it.

## Shared, not forked

Anything the app already ships is reused rather than re-implemented: the lyric
viewport (with its selection, copy and image export), the playback queue view,
the comments view, the login gateway calls, artwork loading, DPI / car display
profiles and the window frame. The legacy layer owns the chrome — layout,
palette, type ramp and row styling — and nothing else.

## Not ported

- The Miuix style engine (`LazerThemeEngine.MIUIX`); only the Material look.
- A custom wallpaper background (`DesktopBackgroundMode.IMAGE`).
- Listen together and the local-file library / HiFi pages: this app streams
  from the catalogue and has no equivalent feature to hang them on.
- Artist and album detail pages for the legacy chrome; the legacy home only
  opens playlists.
