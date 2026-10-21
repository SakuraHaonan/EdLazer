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
| `lib/player/now_playing_route.dart` | Standalone entry/exit route: fade + upward compositor slide |
| `lib/player/player_backdrop.dart` | AMLL mesh-gradient cover flow, multi-hue palette and Apple Music vignette |

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
- The active line reaches 100% scale while every inactive line settles to the
  reference 97%. Scale is a real `mass=2, stiffness=100, damping=25` spring per
  line, with the AMLL `lyricStaggerDelays` schedule applied around the focus.
  The focus row itself starts on the activation frame, so its upward float
  begins with the brightness/blur change instead of trailing it by a stagger
  step.
- Scroll following ports AMLL's `getPosYSpringPolicy`: normal playback uses
  interval-dependent stiffness/damping, seeks use the slow pair, rapid
  delivery stays responsive, and the end of the song uses the medium pair.
  Retargeting preserves spring velocity instead of restarting a duration
  animation.
- The render range follows AMLL exactly: rows are prebuilt inside a motion
  buffer equal to 40% of the viewport plus a small overscan, while visibility
  is driven by spring positions and the `LineBrightness` active window.
- `LyricEdgeFade` is restored as a final viewport mask: it dissolves the
  raster at the top and bottom, plus the left/right in compact mode. It is a
  visual mask only and does not replace AMLL's bright/dim line transition.
- Blur is derived from each row's live spring position: the row centre's
  distance from the 35% focus band, divided by the average row height, scaled
  by `1.55` and capped at the reference 5 px filter. Because it reads the same
  spring that drives the upward float, a row sharpens exactly as it arrives
  instead of clearing ahead of the motion. Manual browsing fades the whole
  mask through its own gate.
- Word rendering ports both AMLL Web Animations. Every word, including short
  syllables that AMLL treats as ordinary, runs the long emphasis float with
  its scale and x spread; there is no bare vertical-translation fallback. The
  white blurred glow stays reserved for AMLL's emphasized subset (long
  syllables / short words), so ordinary words float without lighting up and
  settle at the float target instead of rising past it and dropping back.
  Scale, x/y float, the `empEasing` two-bezier envelope, the 32-frame glow
  table and the last-word intensity multiplier all match the reference. Glow
  is drawn per grapheme from the character's `motion.glow` and
  `motion.glowRadiusEm`, not as one fixed line-wide shadow. The karaoke sweep
  is a soft half-glyph-height gradient, completed words keep their upward
  float instead of snapping back, and word repaints are pumped once per vsync
  by a `Ticker`; inactive rows are not re-rasterised on word frames.
- `LineBrightness` is ported as a real two-layer line: an unmasked dim clone
  at 0.2 opacity plus the bright animated layer. Activation cross-fades over
  300 ms and deactivation over 450 ms, both ease-out, matching
  `.lyricMainLineBright` / `.lyricMainLineDim` and `.gradientMask`. The
  translation follows `.lyricSubLine` at 0.3 opacity.
- Manual drag/wheel browsing fades blur to zero, keeps momentum, and resumes
  following after the configured timeout. Movement is clamped to the
  first/last lyric focus bounds, so it cannot expose empty lyric space above
  the first line or below the last one. Blur is calculated from distance to
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
| `lib/legacy/legacy_background.dart` | AMLL mesh-gradient cover flow + multi-hue cover palette extraction |
| `lib/lyrics/hit_region.dart` | Hit testing limited to actual glyph boxes |
| `lib/lyrics/selection_bar.dart` | Apple-style floating selection actions |
| `lib/lyrics/edge_fade.dart` | Four-edge soft viewport mask for the lyric raster |
| `lib/lyrics/image_export.dart` | Preview, PNG capture and save flow |
| `lib/lyrics/viewport.dart` | Lazy line mounting, follow/manual scrolling, blur, selection and export orchestration |

The viewport mounts only visible rows, polls the engine clock for word
painting, suspends follow during manual scrolling and resumes after the
configured delay. Selection tools copy original + translation in order and
export exactly the selected lines. Long-press selects with a plain bright
white highlight; selected rows (main text and translation) paint at full
alpha while every unselected row keeps the brightness it had before selection
began.

Tapping the artwork no longer opens a large cover overlay. Long-pressing any
cover (desktop or compact header) opens a confirmation dialog before saving
the current artwork to the device.


## Performance and accessibility

### Entering / leaving

The shell no longer pushes the player as a new Navigator route. It mounts the
player as a same-route overlay over the existing app root:

- the whole player uses Material's open-upwards motion: a compositor-only
  slide from `Offset(0, 1)` to `Offset.zero`, 300 ms, `fastOutSlowIn`, with
  the same motion reversed on close;
- no full-screen clip radius, scale or fade is animated;
- the shell and player ambient tickers are paused while the transition runs;
- the album-colour mesh flow is held back until the entrance has settled, then
  enabled once;
- on exit it is disabled before the reverse slide begins;
- the background never renders the song cover image itself; only the extracted
  multi-hue palette drives the mesh flow;
- large subtrees are wrapped in `RepaintBoundary` so the slide transforms a
  cached layer.

A standalone `NowPlayingRoute` still exists for direct callers and uses the
same Material open-upwards slide without a full-screen animated clip.

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
