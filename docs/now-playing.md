# Now Playing / Lyric Engine Rewrite

The player stack was rebuilt from scratch. The old page, desktop/mobile
implementations and the old lyric renderer are no longer used.

## Removed

- `lib/legacy/legacy_desktop_player.dart`
- `lib/legacy/now_playing_m3.dart`
- the old implementation inside `lib/legacy/legacy_now_playing.dart`
- the old lyric implementations previously in:
  - `lib/widgets/lyric_viewport.dart`
  - `lib/widgets/timed_lyric_text.dart`
  - `lib/widgets/lyric_edge_fade.dart`
  - `lib/widgets/lyric_text_hit_region.dart`
  - `lib/widgets/lyric_selection_toolbar.dart`
  - `lib/widgets/lyric_image_dialog.dart`
  - `lib/data/lyrics.dart`
  - `lib/data/lyric_selection.dart`
  - `lib/animation/lyric_spring.dart`
  - `lib/animation/lyric_word_motion.dart`

Those public paths remain as one-line compatibility exports, so callers and
tests can keep importing existing symbols while all implementation lives in
the new `lib/lyrics` package.

## New player modules

| Module | Responsibility |
| --- | --- |
| `lib/player/now_playing_page.dart` | One adaptive page for desktop and phone; top bar, artwork, lyrics, transport, queue/comments sheets |
| `lib/player/now_playing_route.dart` | New entry/exit route: fade + upward settle + scale + rounded-corner expansion |
| `lib/player/player_backdrop.dart` | Album palette flow, real blurred-cover bloom, Apple Music vignette |

The desktop composition is an artwork-led split view with a borderless lyric
canvas. The phone composition uses a compact header and a borderless lyric
canvas over the darkened artwork. Queue and comments remain shared app views
but now run inside the new glass panels/sheets.

## Lyric motion and layout

The lyric canvas follows the AMLL/Apple Music reading rhythm:

- Focus band sits at 35% of the available height, matching the reference
  `LyricViewport` rather than centering every line in the middle of the screen.
- Rows measure their real wrapped text height and share the Apple lyric gutter.
  The translation is held as a smaller secondary row directly underneath.
  Line positions therefore follow the reference implementation instead of a
  fixed `itemExtent`.
- The active line reaches full scale while neighbouring rows settle to 94–99%
  based on distance. The previous/focused transition is driven by the new
  closed-form springs instead of a fixed `animateTo` duration.
- Scroll following uses the adaptive `lyricPositionPolicy` and a spring-driven
  scroll offset, so a natural line change and a seek use different stiffness
  and damping.
- Word rendering uses AMLL's `emphasized` / `ordinary` envelopes per grapheme:
  scale, horizontal/vertical float, glow and a progressive glyph mask. Fully
  settled words collapse into one cached path paint; only the active / recently
  settling word performs per-glyph transforms.
- Manual drag/wheel browsing fades blur to zero, keeps momentum, and resumes
  following after the configured timeout. Blur is calculated from distance to
  the focus band, not from line index alone.
- Inactive rows are cached rasters behind `RepaintBoundary`; the viewport no
  longer rebuilds on every 100 ms transport tick.
- The animated lyric rows are intentionally excluded from the platform
  semantics tree. One stable, keyed live-region node exposes the current lyric
  and translation, so scrolling, scale/blur transitions and line lifecycle are
  invisible to UIA and cannot leave pending lyric nodes in the AXTree.

## New lyric engine

| Module | Responsibility |
| --- | --- |
| `lib/lyrics/lyric_document.dart` | LRC/YRC parser and translation matching |
| `lib/lyrics/selection.dart` | Immutable multi-line selection model |
| `lib/lyrics/spring.dart` | Closed-form spring and adaptive position policy |
| `lib/lyrics/word_motion.dart` | Word emphasis/float motion envelopes |
| `lib/lyrics/timed_line.dart` | Grapheme-aware progressive glyph painting |
| `lib/lyrics/edge_fade.dart` | Four-edge soft mask for blurred lyric raster |
| `lib/lyrics/hit_region.dart` | Hit testing limited to actual glyph boxes |
| `lib/lyrics/selection_bar.dart` | Apple-style floating selection actions |
| `lib/lyrics/image_export.dart` | Preview, PNG capture and save flow |
| `lib/lyrics/viewport.dart` | Lazy line mounting, follow/manual scrolling, blur, selection and export orchestration |

The viewport mounts only visible rows, polls the engine clock for word
painting, suspends follow during manual scrolling and resumes after the
configured delay. Selection tools copy original + translation in order and
export exactly the selected lines.


## Performance and accessibility

### Entering / leaving

The shell no longer pushes the player as a new Navigator route. It mounts the
player as a same-route overlay over the existing app root:

- only a compositor-friendly slide is animated (no full-screen clip radius or
  page-scale recalculation);
- the shell and player ambient tickers are paused while the transition runs;
- the real cover blur and album-colour flow are held back until the entrance
  has settled, then enabled once;
- on exit they are disabled before the reverse slide begins;
- the cover bloom is fetched at a small rendition and blurred at 18 px instead
  of blurring a 1024 px texture;
- large subtrees are wrapped in `RepaintBoundary` so the slide transforms a
  cached layer.

A standalone `NowPlayingRoute` still exists for direct callers and uses a
fade + slide transition without a full-screen animated clip.

### Windows AXTree stability

The previous route swap left the Windows accessibility bridge with two
semantic roots during enter/exit. The app now keeps a stable same-route
semantics container, excludes the shell while the player is open, and defers
exposing the player semantics until the entrance slide has finished. On exit
the player semantics are removed before the shell returns. The lyric column
now contributes exactly one stable live-region semantics node; animated rows
are `ExcludeSemantics`. Transport controls live outside the 100 ms tick builder,
and the seek bar exposes one stable labelled slider node while changing only its
value. Together these changes remove the per-line/per-tick semantic node churn
that produced the `AXTree ... not the new root` / `Nodes left pending` family
during lyric playback.
