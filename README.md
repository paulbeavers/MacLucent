# mac-lucent

A full-screen, Hyprland-style tiling workspace for macOS, built for software developers.
It runs as a normal macOS app (not a VM). Inside it you get workspaces, tiled
terminal windows running **bash** in a real PTY, and tiled **web browser** windows.

## Build & run

Requires Xcode / Swift 5.9+ and macOS 13+.

```bash
./scripts/build-app.sh          # release build → build/mac-lucent.app
open build/mac-lucent.app
```

The app opens in macOS full screen — its own Space, so it shows up as a page in Mission
Control (⌃↑) and you can swipe to and from it — and starts with one terminal. Use `--windowed`
for a regular window, or `--borderless` to cover the current Space without a full-screen Space. During development, `swift run mac-lucent --windowed` works too.

## Keybindings (⌘ is the "Super" key)

| Keys | Action |
|---|---|
| ⌘ ↩ | New terminal (opens in the focused terminal's directory) |
| ⌘ B | New browser |
| ⌘ D | App launcher |
| ⌘ , | Settings |
| ⌘ I | Stats |
| ⌘ W | Close window |
| ⌘ ← ↑ ↓ → | Move focus |
| ⌘ ⇧ ← ↑ ↓ → | Swap window with neighbour (floating: move it) |
| ⌘ ⌃ ← ↑ ↓ → | Resize split, or drag the gap between windows (floating: resize) |
| ⌘ J | Toggle split direction |
| ⌘ F | Fullscreen the focused window |
| ⌘ ⇧ F | Toggle the current workspace between tiled and floating |
| ⌘ 1–9 | Switch workspace |
| ⌘ ⇧ 1–9 | Move window to workspace |
| ⌘ ⌥ ← / → | Previous / next workspace |
| ⌘ / | Keybinding cheat sheet |
| ⌘ + / ⌘ − / ⌘ 0 | Zoom terminal font / browser page |
| ⌘ K | Clear terminal |
| ⌘ L, ⌘ R, ⌘ [, ⌘ ] | Browser: address bar, reload, back, forward |
| ⌃ ⌘ F | Toggle macOS full screen |
| ⌘ Q | Quit |

Browser windows have the WebKit inspector enabled (right-click → Inspect Element).
`localhost` and plain-http dev servers load fine. Links that open a new window
(`target=_blank`, `window.open`) open as a new tile.

## Architecture

```
Sources/MacLucent/
  main.swift, AppDelegate.swift   app entry, menu, main window, icon
  Core/
    Config.swift        hyprland.conf-like settings (gaps, borders, rounding, animations, colors)
    LayoutTree.swift    dwindle binary tree: insert/remove/swap/resize, geometry, neighbours
    Workspace.swift     a workspace + its view (gap dragging, empty hint)
    TileWindow.swift    window decoration: gradient border, rounding, shadow
    WindowManager.swift workspaces, focus, keybindings, animations
  Apps/
    TileApp.swift       the protocol every app implements + AppRegistry
    TerminalApp.swift   SwiftTerm terminal running bash
    StatsApp.swift      live stats dashboard (SystemStats.swift samples the numbers)
    BrowserApp.swift    WKWebView browser with address bar
  UI/
    DesktopView.swift   wallpaper, stage, overlay host
    BarView.swift       waybar-style top bar
    Overlays.swift      launcher + keybinding help
```

### Floating workspaces

Each workspace is either **tiled** (dwindle) or **floating**. Toggle the current one with ⌘ ⇧ F, or pick
them in Settings → Workspaces; the choice is saved. On a floating workspace windows can overlap:

- ⌘-drag moves a window, ⌘-right-drag resizes it, or drag just outside a window's border to resize from that edge
- clicking a window raises it; with focus-follows-mouse, hovering raises it too (turn off
  "Raise on hover" in Settings to focus without raising)
- new windows open centered and cascade

The tiled arrangement is kept while a workspace floats, so switching back restores it, and each
window remembers its floating position for next time.

### Settings

⌘ , (or the launcher) opens the Settings app: floating workspaces, gaps, border size and colors, rounding, shadow,
inactive dimming, terminal opacity and font, blur, animation speeds, browser home page and
search URL, and the wallpaper. Changes apply live and are saved to
`~/.config/mac-lucent/settings.json` (hand-editable; unknown or missing keys are ignored).

### Stats

⌘ I (or launcher → **Stats**) opens a live dashboard, refreshed every second: mac-lucent's version,
git commit and uptime; CPU and memory of mac-lucent itself and of the shells in its terminals
(including everything they started), with 60-second sparklines (hover for values); system CPU,
memory, disk and load; per-workspace window counts and modes; and per-terminal process counts.
WebKit's web-content processes run outside mac-lucent's process tree, so browser page memory
isn't included in the mac-lucent figures.

### Adding a new app

1. Create a class conforming to `TileApp` (provide a `view`, `title`, `symbolName`, `focus()`, `shutdown()`).
2. Register it in `AppRegistry.apps` in `Apps/TileApp.swift`.

It then shows up in the launcher (⌘ D) and tiles like any other window. Set `singleInstance: true`
on its `AppDescriptor` to focus the existing window instead of opening another (as Settings does).
Apps can read `Config.shared` and observe `.configDidChange` to react to settings changes.

### Customising

- Wallpaper: choose one in Settings, or put an image at `~/.config/mac-lucent/wallpaper.png`.
- Fonts: the terminal uses the first installed of JetBrainsMono Nerd Font, MesloLGS NF,
  FiraCode Nerd Font, SF Mono, Menlo.
- Shell: uses Homebrew bash (`/opt/homebrew/bin/bash`) if installed, otherwise `/bin/bash`.

### Performance notes

- SwiftTerm is pinned to **1.10.1** (CoreGraphics renderer on the normal AppKit display cycle).
  The 1.99.x pre-releases add an off-main render loop that stalled 150–300 ms on real typing;
  1.11–1.20 need the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) to build.
- Live blur is off by default; `ML_BLUR=1` turns on NSVisualEffectView blur behind terminals and the bar.
- SwiftTerm 1.10.1 treats every `CSI … u` as "restore cursor", which broke kitty-keyboard-aware
  TUIs such as Claude Code (redraws landed at the top of the window). `TerminalOutputFilter`
  strips those sequences from shell output; `ML_PTY_LOG=<file>` records raw output for debugging.
- `ML_BACKGROUND=1` launches without taking keyboard focus (for scripted test runs).
- `ML_LATENCY_LOG=1` logs per-keystroke latency (deliver / echo / drawn) to
  `~/Library/Logs/mac-lucent/latency.log`; `--bench-typing` runs a synthetic typing benchmark
  (`ML_BENCH_INTERVAL` sets the gap between keys).

### Debug flags

`--windowed`, `--open terminal,browser`, `--workspace N`, `--launcher`, `--help-overlay`,
`--type 'cmd\n'` (types into all terminals), `--snapshot out.png` (renders the desktop and quits),
`--no-confirm-quit`.
