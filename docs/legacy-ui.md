# Apple-style adaptive interface

The app now ships one interface language across every page: an Apple Music-
inspired, HIG-shaped design with a desktop and a mobile composition. There is
no "legacy" versus "Apple" switch; the previous Material 3 chrome has been
replaced end to end while the playback, catalogue, lyric, queue and comment
engines stay untouched.

## Design system

`lib/theme/apple_design.dart` is the single source for the interface:

- **Semantic colours** — `AppleSemanticColors` provides `background`,
  `secondaryGroupedBackground`, `label`, `secondaryLabel`, `separator`,
  `fill`, `glass`, and the accent. Light and dark palettes are explicit, with no
  Material elevation tinting.
- **Accent** — Apple Music red `#FA2D48` is the default. When Settings →
  配色 is set to 跟随当前歌曲, the dominant cover colour is used as the accent;
  自定义 opens an HSV swatch picker that seeds the accent with the listener's
  own colour. Neutral surfaces remain stable either way.
- **Typography** — the HIG ramp (large title 34, title 20, body 17, footnote
  13, caption 11) with tight tracking and semibold display weights. Apple
  platforms use their native SF face; Windows/Linux/Android use bundled MiSans
  and the platform CJK fallback.
- **Surfaces** — real grouped backgrounds, hairline separators, 8–20 pt
  corner radii, no drop shadows on lists, and subtle album shadows on artwork.
- **Motion** — short ease-out transitions (120–200 ms) and 420 ms player
  presentation. The existing reduced-motion handling still freezes the album
  flow for accessibility and tests.

`lib/widgets/apple_ui.dart` holds the reusable primitives: large-title page
headers, section headers, grouped cards, list tiles, icon tiles, empty states,
capsule search fields, and `AppleGlass` (blur + semantic tint + hairline) for
navigation chrome and transient panels.

## Browse backdrop

Settings → 背景 picks how the browse shell paints its canvas: the flowing
album-colour mesh, a flat album tone, the listener's own picture, or none.
A custom picture is copied into the application support directory on import,
so the backdrop keeps working after the source file moves or is deleted.
With no backdrop, dark mode paints the deep warm `AppleColors.darkCanvas`
rather than pure black, so the window still reads as a surface.

The immersive player owns its own canvas: it always renders the album-colour
flow for the current song, and the browse backdrop setting never removes it.

## Dual-end support

### Desktop / large window

- 236 dp translucent source-list sidebar with a persistent search field,
  browse/likes/library destinations, synced playlists, settings and account.
- Transparent content toolbar with back navigation, search, appearance toggle
  and profile menu.
- Centred large-title content area capped at 1180 dp for readability.
- Full 84 dp transport with now-playing tile, centre transport controls, thin
  seek rail, volume popover and queue/comments actions.
- The immersive now-playing overlay follows the AMLL Player/Apple Music
  composition: an AMLL mesh-gradient flow canvas, a
  large shadowed cover, metadata and actions on the left, a borderless lyric
  column on the right, and a dark Apple transport shelf. Queue and comments
  open as docked glass panels. Keyboard shortcuts (Space, arrows, M, L, Q, C,
  F, Esc) remain.

### Phone / compact window

- 50 dp inline navigation bar, collapsible search, large page titles and the
  iOS tab bar (`主页 / 音乐库 / 我喜欢 / 设置`).
- 60 dp translucent mini-player above the tab bar; tapping it opens the
  immersive player.
- Content is inset at 16 dp with edge-to-edge artwork where appropriate.
  Settings uses a single-column grouped list.
- The now-playing overlay is portrait/landscape adaptive: a borderless lyric
  column floats directly on the blurred artwork, with a cover view toggle,
  glass bottom transport and bottom-sheet queue/comments. The landscape split
  keeps a compact information card beside the lyrics. Queue and comment
  controls stay reachable at every height.
- Login is an Apple-sheet card with QR sign-in and a Cookie escape hatch.

### 大屏幕模式 (television)

Android TV gets its own composition rather than the desktop shell at ten feet.
`设置 → 界面 → 设备形态` can force `大屏幕模式`; otherwise a Leanback or
touch-less Android device selects it automatically and boots into it. The
large-screen mode draws a floating destination capsule, shelves of captioned
artwork (为你打造 and 排行榜 reuse the desktop/mobile cards), a rail-and-grid
library and a rounded transport card that floats over the page, keeps the
standard interface scale, insets chrome for overscan, and turns every card,
row and transport glyph into a D-pad focus stop with a white-on-black focus
ring. Settings rows wash and ring around whichever Material control the remote
is on.
Directional traversal follows the card geometry and bumps a shelf or page when
the next card has not been built yet. Back closes the queue or volume panel
first, then the player, then detail pages. See
[android-tv.md](android-tv.md) for the manifest, detection, layout and
navigation details.

Breakpoints: mobile below 720 dp, immersive desktop player from 840 dp,
compact desktop transport below 1000 dp. Settings and artwork grids reflow
independently of those thresholds.

## Pages

| Page | Apple composition |
| --- | --- |
| 现在就听 | Large title, edge-to-edge featured playlist hero, horizontal recommendation shelf, grouped quick-pick track rows |
| 资料库 | Large title, owned playlists, recommendation grid with 2–6 adaptive columns |
| 我喜欢 | Playlist hero and grouped track list, guest sign-in state; the shared playlist page's floating locate-current button |
| 歌单详情 | Album-style hero, metadata and play/shuffle controls, grouped track list, floating locate-current-track button |
| 搜索 | Capsule search field, artist/search result sections, track rows and playlist grid |
| 设置 | iOS inset grouped cards: interface, appearance, playback, interaction, lyrics, scrolling, performance, account, about |
| 登录 | Apple sheet card, QR code, status messaging, Cookie mode |
| 正在播放 | AMLL/Apple Music-style blurred-artwork canvas, large cover, borderless animated lyrics, adaptive transport; shared lyric engine |

## Preserved functionality

Everything above the pixels remains shared with the existing app:

- `AppState`, NetEase gateway, catalogue cache, artwork loading, playback,
  queueing, likes, comments and lyrics.
- The shared `LyricViewport` with word-level sweep, selection, copy and image
  export, plus all persisted lyric preferences.
- Queue (`PlaybackQueueView`) and comments (`SongCommentsView`) are reused in
  modal glass panels/sheets rather than forked.
- DPI scaling, car-display mode, the large-screen profile, safe areas,
  window frame, system media integration and localisation continue to work.

## Settings and persistence

Settings still exposes every preference from the previous shell: accent,
device profile, layout mode, DPI scale (manual + automatic), album backdrop,
content opacity and dynamic-background render precision, theme, language,
independent playback, haptics, lyric timing, size, weight, blur, follow
delay, scroll inertia/acceleration, frame overlay, account and catalogue
refresh. Persistence keys are unchanged; the new one is
`lazer_dynamic_background_quality`.

## Performance

The redesign keeps the existing performance constraints:

- `CustomPaint` album flow, no per-frame widget transforms in the background.
  Its `动态背景渲染精度` slider (0.1 … 1.0, default 0.8) scales the mesh — a
  4×3 quad grid at 10%, the authored 28×18 at 100% — and the update cadence
  — 100 ms at 10%, 33 ms at 100% — and the slider's subtitle prints both, so
  the value it stores is verifiable rather than a blind percentage;
- Lyric rows repaint on the playback tick lane only; inactive rows stay cached.
- Track lists use `SliverList.builder` where they can grow.
- Artwork requests the smallest CDN rendition covering its painted size.
- Blur is limited to navigation chrome and overlays; content surfaces are
  opaque/semantically filled so text contrast does not depend on artwork.
- Shell rebuilds remain structural only; transport/seek widgets own the
  100 ms tick lane.

### Switching pages

The cross-fade is the moment the frame budget is tightest: two full pages are
alive and the incoming one is building for the first time. The shell therefore
mirrors the switcher's own 280 ms motion and uses it to stand down ambient work:

- the album mesh is parked under a `TickerMode` for the length of the switch.
  It drifts on a ten second time base, so a 280 ms pause is invisible, and it
  stops repainting the whole window at 30 fps while the transition runs;
- playback, download and lyric reports that arrive mid-switch are held back and
  folded into the single rebuild that ends the switch. Rebuilding the incoming
  page ten times a second while it fades is what makes the animation stutter;
  nothing is lost, because that rebuild reads the newest state;
- a state report that arrives outside a switch still rebuilds the shell exactly
  as before, so pages keep following playback while nothing is animating;
- `AppleGlass` only inserts a clip layer for rounded panels; the square chrome
  panels paint the decoration alone.

## Verification

`flutter analyze` and the full widget/unit suite cover the desktop layout at
800–1920 px, compact layout down to 320 px, the Apple player theme, lyric
interaction, queue/comments sheets, sign-in and persistence.
