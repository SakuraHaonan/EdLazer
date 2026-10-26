# Car head unit profile

A car head unit is not a small desktop. Its panel is large but sits an arm's
length away behind glass, it is touched in motion, and it renders at (or near)
one physical pixel per logical pixel — so the same interface that reads well on
a 1080p monitor looks tiny there. The car profile answers that.

## What it changes

| Knob                      | Standard            | Car profile                    |
| ------------------------- | ------------------- | ------------------------------ |
| Interface scale floor     | 80%                 | **135%** (`kCarScaleMin`)      |
| Automatic scale ceiling   | 175%                | 175%                           |
| Material visual density   | platform default    | `(1, 1)` — roomier             |
| Material tap target       | platform default    | `padded` — 48 px minimum       |

The scale itself is the same mechanism the DPI setting uses: the whole subtree
is laid out in a workspace divided by the scale and painted through a matching
transform (`lib/widgets/ui_scaling.dart`), so rows, icons, hit targets and the
custom window title bar grow together and text stays crisp.

Below 100% the workspace is *larger* than the window, so the transform sits
inside an `OverflowBox`. The box keeps the window as the widget's own size —
that is the rect which owns the window's hit area — while the child is laid out
at the workspace size and the transform paints it back over the whole window.
Without it the child was clamped to the window's size, laid out at window
density, painted at the smaller scale, and covered only the top-left corner of
the window with dead space (and dead hit targets) around it.

The floor applies to both scale modes: whether the automatic estimate or the
slider is in charge, a head unit never drops back to desktop density.

## How it is selected

`设置 → 界面 → 设备形态` offers `自动选择 / 标准 / 车机 / 大屏幕模式`, persisted as
`lazer_surface`. An explicit choice always wins; `自动选择` asks the platform:

```dart
looksLikeCarDisplay(
  platform: TargetPlatform.android,
  physicalSize: Size(1280, 720),   // ≥ 960×540
  devicePixelRatio: 1,             // ≤ 1.5 — phones report 2–3.5×
)
```

That is the shape every embedded Android display has: a low-density landscape
panel. Android TV boxes match too and want the same large, far-viewed
interface; a real Leanback television is detected first and takes the
large-screen profile instead (standard density plus D-pad navigation — see
[android-tv.md](android-tv.md)). Phones (high density) and portrait tablets
never match, and desktop platforms are excluded on purpose — a window's size
says nothing about the display behind it, so there the choice stays manual.

Detection is best-effort by design: the app cannot ask Android whether it runs
on a vehicle head unit without platform code, so the setting stays one tap away.

## Tuning

- `kCarScaleMin` — the floor. Raising it makes every head unit larger; 1.35 is
  the point where a 15 px body lands at ~20 px on a 1920×720 panel.
- `kCarMinPhysicalSize`, `kCarMaxDevicePixelRatio` — the detection envelope.
- `CarMetrics` — the Material density/tap-target swap.

The layout breakpoint is untouched: on a wide car screen the shell already
picks its desktop rail, on a narrow one the bottom tabs. `界面布局` can force
either.
