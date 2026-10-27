# UI evidence — QuotaBar v0.4

Generated offscreen from the real SwiftUI views with the demo data set, so the
review does not depend on live provider state or a logged-in desktop.

Command:

```sh
./scripts/capture-ui.sh
```

| File | View | Size (pt) |
|---|---|---|
| `popover-light.png` | `PopoverView` (menu-bar popover content) | 320 × 559 |
| `popover-dark.png` | same, dark appearance | 320 × 559 |
| `history-light.png` | `HistoryView` (History window content) | 620 × 767 |
| `history-dark.png` | same, dark appearance | 620 × 767 |
| `menubar-icon.png` | menu-bar template icon (6×) | 108 × 108 |
| `app-icon.png` | app icon master | 1024 × 1024 |

Each view PNG is 2× (Retina). The data is synthetic and labelled "Demo data" in
the popover footer. The demo intentionally sets OpenCode Go monthly to 93% so the
90%-used heads-up row is visible; the app icon master comes from
`scripts/make-app-icon.swift`.

## Why offscreen

The build machine was locked while capturing (`screencapture` returns "could not
create image from display", and no application windows can be ordered front), so
window-server captures were impossible. `--render-evidence` renders the same
views through `ImageRenderer`, which produces real SwiftUI layout and Charts
output without a display.

## Known rendering gaps

- System popover chrome (material, arrow, shadow) is not part of the rendered
  content; the app uses `MenuBarExtra(.window)`, which supplies it.
- The overflow `Menu` and the 24h/7d `Picker` are live AppKit controls that the
  offscreen renderer cannot draw; the snapshot path renders a static glyph /
  range chip in their place. The live controls are unchanged in the app.
- `ScrollView` is replaced by a plain stack for the history snapshot so the full
  content is captured instead of one viewport.
- Colors use a neutral fixed backdrop (near-white / near-black) instead of
  `windowBackgroundColor`, which does not resolve offscreen.

## Locale

The UI copy is English-only and all dates/percentages use system formatters, so
there is no second-locale layout risk. The popover is fixed-width (320 pt) and is
the narrowest supported presentation; the History window has a 520 pt minimum.

## Identity and alerts (v0.5)

- The menu bar uses a static monochrome "Q" template image plus the numeric
  label; no quota state is encoded in the icon.
- The app bundle carries `Resources/QuotaBar.icns` via `CFBundleIconFile`.
- Alerts are opt-in, request permission on enable, and are evaluated only for
  fresh network snapshots. `UNUserNotificationCenterDelegate` now presents
  banners while the app is active; `--notification-diagnose` prints the
  authorization/settings report and posts a diagnostic notification.
- The menu-bar mark is two meter bars, rendered once at 4× and downsized to 18pt
  (a letter monogram read as a search glyph at menu-bar size; the first attempt
  also double-scaled into a clipped blob).
- Ad-hoc builds deliver alerts through a floating panel instead of Notification
  Center; the popover now paints an explicit system background so light mode
  cannot inherit a dark wallpaper-tinted material.

## Data-integrity checks covered by tests

- Clear History records a deletion cutoff in the same transaction; older local
  observations are rejected on insert, including after a store reopen.
- History queries include device-level local-log rows only as device-level; the
  History window labels them and never claims they belong to the account.
- Fallback snapshots keep their original observation timestamp (deduplicated by
  primary key), so an offline refresh cannot fabricate a flat history.

## Manual smoke (not captured here)

- Open the popover with both providers live, then close it and wait 5 minutes:
  history keeps sampling in the background.
- Disconnect the network and refresh: percentages stay, status line shows the
  last successful observation age.
- Open History, switch 24h ↔ 7d, close and reopen: window state and range reset
  to 24h by design.
- Clear History: charts empty, live quota still shown; relaunch and go offline —
  the cleared history must stay empty (deletion cutoff + local-log rejection).
- Quit and relaunch with the popover never opened: history still advances after
  five minutes (sampler is app-owned).
- Enable *Quota alerts*, click *Send Test Notification*, confirm delivery; deny
  permission once and confirm the in-app heads-up still works.
- Menu bar: Q icon legible at 1×/2×, light and dark menu bars.
- Finder/Dock show the app icon (History window activation shows it in the Dock).
