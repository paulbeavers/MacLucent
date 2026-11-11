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

The app opens in native full screen with one terminal. Use `--windowed` to start
in a regular window. During development, `swift run mac-lucent --windowed` works too.

## Keybindings (⌘ is the "Super" key)

| Keys | Action |
|---|---|
| ⌘ ↩ | New terminal (opens in the focused terminal's directory) |
| ⌘ B | New browser |
| ⌘ D | App launcher |
| ⌘ W | Close window |
| ⌘ ← ↑ ↓ → | Move focus |
| ⌘ ⇧ ← ↑ ↓ → | Swap window with neighbour |
| ⌘ ⌃ ← ↑ ↓ → | Resize split (or drag the gap between windows) |
| ⌘ J | Toggle split direction |
| ⌘ F | Fullscreen the focused window |
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
    BrowserApp.swift    WKWebView browser with address bar
  UI/
    DesktopView.swift   wallpaper, stage, overlay host
    BarView.swift       waybar-style top bar
    Overlays.swift      launcher + keybinding help
```

### Adding a new app (e.g. Settings)

1. Create a class conforming to `TileApp` (provide a `view`, `title`, `symbolName`, `focus()`, `shutdown()`).
2. Register it in `AppRegistry.apps` in `Apps/TileApp.swift`.

It then shows up in the launcher (⌘ D) and tiles like any other window. A settings app
can edit `Config.shared` and call `Config.shared.notifyChanged()` to apply changes live.

### Customising

- Wallpaper: put an image at `~/.config/mac-lucent/wallpaper.png`.
- Fonts: the terminal uses the first installed of JetBrainsMono Nerd Font, MesloLGS NF,
  FiraCode Nerd Font, SF Mono, Menlo.
- Shell: uses Homebrew bash (`/opt/homebrew/bin/bash`) if installed, otherwise `/bin/bash`.

### Debug flags

`--windowed`, `--open terminal,browser`, `--workspace N`, `--launcher`, `--help-overlay`,
`--type 'cmd\n'` (types into all terminals), `--snapshot out.png` (renders the desktop and quits),
`--no-confirm-quit`.
