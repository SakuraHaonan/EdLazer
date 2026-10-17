# Legacy UI

`设置 → 界面 → 界面风格` switches the whole shell between two interfaces:

| Style | Source | Default |
| --- | --- | --- |
| **Nextgen UI** | this Flutter build's parchment shell | ✅ |
| **Legacy UI** | ported from `E:\projects\Lazer` (Compose Multiplatform) | |

The choice is stored as `lazer_ui_style` and restored on the next launch. The
legacy settings page carries the same switch, so the way back is always one
tap away.

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

The palette is the legacy one — lake-blue `#5F91AC` by day, `#91BED3` at night,
paper `#F7F5EF` / night paper `#1D282D`, clay `#B88769` — and the type ramp is
its 34 → 11 sp Material ramp, not the Nextgen editorial scale.

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
- **正在播放** — the legacy two-pane page: 44% hero (cover with the 26 dp drop
  shadow, title, translation, artist) over the rounded transport card, 56% the
  **shared Nextgen `LyricViewport`** — word-level sweep, distance blur, lyric
  selection with copy / image export, wheel and drag with the follow delay all
  come from the one implementation the app already ships, so the lyric
  behaviour never forks.
- **Player bar** — the 84 dp `PlayerBar`: a 250 dp now-playing tile (cover 50,
  title, translation, artist) that opens the lyrics page, the centred transport
  (like, previous, 38 dp play, next, one play-mode cycle) over the thin seek
  row, and a 168 dp right group (volume popover, queue card, comments, lyrics).
  Its surface is `surface @ 0.96 × content opacity` with a 1 dp outline, so the
  album canvas reads through it. Under 1000 dp it folds to the compact form.
- **Queue** — the floating card above the bar hosts the shared
  `PlaybackQueueView`; **评论** opens the shared `SongCommentsView` as a content
  page, replacing the search bar the way the legacy comment page does.
- **Login** — QR card with the same gateway calls as the Nextgen card, plus the
  cookie paste field. 8821 (risk control) reads as "scanned, waiting".
- **Settings** — every preference the Nextgen shell exposes, in the legacy row
  style: interface style, accent palette (fixed / follow the cover), device
  form, layout mode, DPI scale (with reset and the automatic switch), the album
  backdrop and its opacity, theme, language, haptics, lyric controls, lyric
  size/weight/blur, follow delay, scroll inertia and acceleration, the account,
  a catalogue refresh and the port note. Rows stack label-over-control under
  560 dp.

Everything above the pixels is shared with Nextgen: `AppState`, the catalogue,
playback, artwork loading and the DPI / car display profiles all still apply,
and the custom window frame follows the selected style's colours.

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
  with its own phase offset, speed, orbit, scale pulse and rotation, repainted
  at 30 fps; the fifth paints the base and a slow overlay. A track change
  crossfades the palette over 650 ms with a cosine ease.
- **Veil** — the content-opacity setting composites the surface colour over the
  canvas at its square (70% → 0.49), so the tint reads through the chrome while
  text stays legible. The rail, the player bar and the bottom tabs turn
  translucent while the backdrop is on.
- **Settings** — `设置 → 界面 → 背景` chooses follow-the-track (flowing), a flat
  track colour, or off; `内容不透明度` (40–100%) controls the veil. Stored as
  `lazer_legacy_background` and `lazer_legacy_ui_alpha`.
- **Reduced motion** — `MediaQuery.disableAnimations` freezes the flow, which is
  also how the widget tests settle.

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
- Artist and album detail pages for the legacy chrome (the Nextgen pages serve
  those); the legacy home only opens playlists.
