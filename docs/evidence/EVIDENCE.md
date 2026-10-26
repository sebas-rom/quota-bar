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

Each PNG is 2× (Retina). The data is synthetic and labelled "Demo data" in the
popover footer.

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

## Manual smoke (not captured here)

- Open the popover with both providers live, then close it and wait 5 minutes:
  history keeps sampling in the background.
- Disconnect the network and refresh: percentages stay, status line shows the
  last successful observation age.
- Open History, switch 24h ↔ 7d, close and reopen: window state and range reset
  to 24h by design.
- Clear History: charts empty, live quota still shown.
