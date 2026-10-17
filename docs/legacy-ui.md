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
  playlist list, refresh, and 设置 at the bottom (`262 dp`, folds into a
  bottom `NavigationBar` under 760 dp).
- **Top bar** with the search field (350 ms debounce), the theme toggle and the
  account menu (login, sign out, settings).
- **主页** — `今天为你整理` playlist rail plus the quick-pick track list.
- **音乐库** — liked / created / subscribed playlists and the recommended ones.
- **我喜欢** and any playlist page with a play-all header.
- **搜索** — tracks, playlists and albums for the query.
- **正在播放** — cover, title, scrolling lyrics with translations (tap a line
  seeks), transport.
- **Player bar** — cover/title, like, shuffle/previous/play/next/repeat,
  draggable progress, volume, queue sheet. Below 1000 dp it folds to the
  compact form so the transport never overflows.
- **Login** — QR card with the same gateway calls as the Nextgen card, plus the
  cookie paste field. 8821 (risk control) reads as "scanned, waiting".
- **Settings** — interface style, theme, language, account and the port note.

Everything above the pixels is shared with Nextgen: `AppState`, the catalogue,
playback, artwork loading and the DPI / car display profiles all still apply,
and the custom window frame follows the selected style's colours.

## Not ported

- The album-coloured flowing background and the tinting engine
  (`AlbumFlowBackground`, `LazerBackgrounds`) — the legacy shell uses the flat
  palette.
- The Miuix style engine (`LazerThemeEngine.MIUIX`); only the Material look.
- Comments, listen-together, the local library / HiFi pages, artist and album
  detail pages, and the queue as a floating card (the queue is a sheet here).
