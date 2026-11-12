# Lucent

Lucent for the Mac — the macOS counterpart of the Lucent Hyprland config.

*(Formerly mac-lucent. Settings in `~/.config/mac-lucent` are moved to `~/.config/lucent` automatically.)*

A full-screen, Hyprland-style tiling workspace for macOS, built for software developers.
It runs as a normal macOS app (not a VM). Inside it you get workspaces, tiled
terminal windows running **bash** in a real PTY, and tiled **web browser** windows.

## Build & run

Requires Xcode / Swift 5.9+ and macOS 13+.

```bash
./scripts/build-app.sh          # release build → build/Lucent.app
open build/Lucent.app
```

The app opens in macOS full screen — its own Space, so it shows up as a page in Mission
Control (⌃↑) and you can swipe to and from it — and starts with one terminal. Use `--windowed`
for a regular window, or `--borderless` to cover the current Space without a full-screen Space. During development, `swift run lucent --windowed` works too.

## Keybindings (⌘ is the "Super" key)

The modifier is configurable: Settings → General → **Modifier key** switches every Lucent
shortcut below from ⌘ to ⌥ (standard macOS ones such as copy/paste, ⌘Q and ⌘⌥←/→ stay as they
are). With ⌥, **⌥Tab / ⌥⇧Tab** cycles through the workspaces that have windows (⌘Tab can't be
used — it belongs to macOS). Note that the terminal uses ⌥ as Meta, so ⌥ shortcuts Lucent
claims (e.g. ⌥B, ⌥F, ⌥D) no longer reach the shell.

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
| ⌘ T, ⌘ W, ⌘ ⇧ T | Browser: new tab, close tab (last tab closes the tile), reopen closed tab |
| ⌃ Tab / ⌃ ⇧ Tab, ⌘ ⇧ ] / ⌘ ⇧ [ | Browser: next / previous tab |
| ⌃ ⌘ F | Toggle macOS full screen |
| ⌘ Q | Quit |

Browser windows have tabs (all sharing one cookie store, so you stay signed in across them)
and the WebKit inspector (right-click → Inspect Element). `localhost` and plain-http dev
servers load fine. Links that open a new window (`target=_blank`, `window.open`) open as a
new tab; ⌘-click or middle-click opens a link in a background tab. Middle-click a tab or
click its × to close it; double-click empty tab-bar space for a new tab.

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
    BrowserApp.swift    tabbed WKWebView browser with address bar
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

### Themes

Lucent for the Mac uses **the same themes as the Lucent Hyprland config** — the `*.theme` files
from `../lucent/config/hypr/themes`, copied into `Resources/Themes` by `scripts/sync-themes.sh`
(run automatically by the build when the sibling repo is present). Pick one in **Settings → Theme**
(a card per theme) or from the launcher: **⌘ D → Themes…** — type to filter, ↑/↓ previews live,
Enter keeps it, Esc puts the old one back.

A theme recolours everything at once, mapped like on Hyprland: the focused border is the
`mauve → blue` gradient, unfocused borders `border` or `surface0`, highlights `mauve`, and the
terminal's 16 colours, cursor and selection follow foot's mapping. `terminal = <theme>` gives a
theme another theme's terminal (Lucent Light's dark terminal), light themes switch the app to light
appearance and an opaque terminal, and the built-in wallpaper is drawn from the theme. Extra
themes in `~/.config/lucent/themes/*.theme` are picked up too (same format).

### Session restore

When you quit (and every 15 seconds while running), Lucent saves your session to
`~/.config/lucent/session.json`: each workspace's tiling layout (split directions and sizes),
floating window positions, terminal folders, browser tabs (and the selected tab), Settings/Stats
windows, the focused window and the current workspace. On launch it's rebuilt exactly. Terminals
reopen in their folder with a fresh shell — running programs can't be restored. Turn it off in
Settings → General → **Restore windows on launch**. (Scripted test runs — `ML_BACKGROUND`,
`--snapshot` — never read or write the session; `ML_SESSION_FILE=<path>` points at another file.)

### Settings

⌘ , (or the launcher) opens the Settings app: floating workspaces, gaps, border size and colors, rounding, shadow,
inactive dimming, terminal opacity and font, blur, animation speeds, browser home page and
search URL, and the wallpaper. Changes apply live and are saved to
`~/.config/lucent/settings.json` (hand-editable; unknown or missing keys are ignored).

### Stats

⌘ I (or launcher → **Stats**) opens a live dashboard, refreshed every second: Lucent's version,
git commit and uptime; CPU and memory of Lucent itself and of the shells in its terminals
(including everything they started), with 60-second sparklines (hover for values); system CPU,
memory, disk and load; per-workspace window counts and modes; and per-terminal process counts.
WebKit's web-content processes run outside Lucent's process tree, so browser page memory
isn't included in the Lucent figures.

### Adding a new app

An app is **one file plus one registry entry** — no other framework code changes.

1. Create a class conforming to `TileApp` (`Apps/TileApp.swift`): provide `view`, `title`,
   `symbolName`, `focus()` and `shutdown()`. Optional hooks: `handleKey` (app shortcuts),
   `requestClose` (custom ⌘W, e.g. closing a tab), and `sessionState` (a `JSONValue` to save;
   return nil to opt out of session restore).
2. Add an `AppDescriptor` to `AppRegistry.apps`:

   ```swift
   AppDescriptor(id: "notes", name: "Notes", symbolName: "note.text", shortcut: .key("N"),
                 make: { _ in NotesApp() },
                 restore: { _, state in NotesApp(text: state["text"]?.string ?? "") })
   ```

From the descriptor the app automatically gets: a launcher entry, its keyboard shortcut (with the
⌘/⌥ modifier), a row in the ⌘/ help sheet and the File menu, single-instance behaviour
(`singleInstance: true`), counting in Stats, and session restore (`restore` defaults to `make`).
Shortcuts must not clash with the window-manager keys (D, W, F, J, Tab, digits, arrows).
Apps can read `Config.shared` and observe `.configDidChange` to react to settings changes.

### Customising

- Wallpaper: choose one in Settings, or put an image at `~/.config/lucent/wallpaper.png`.
- Fonts: Lucent ships with **JetBrains Mono**, **JetBrainsMono Nerd Font Mono** (with the
  icon glyphs prompt themes like Starship/Powerlevel use), **Fira Code**, **Cascadia Code** and
  **Hack** (in `Resources/Fonts`, registered for the app only — nothing is installed system-wide;
  each family's license is alongside it: SIL OFL 1.1, or MIT for Hack / Nerd Fonts patches).
  Pick one in Settings → Terminal → Font; "Automatic" uses JetBrainsMono Nerd Font Mono. Any
  monospaced font installed on the Mac is listed too.
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
  `~/Library/Logs/Lucent/latency.log`; `--bench-typing` runs a synthetic typing benchmark
  (`ML_BENCH_INTERVAL` sets the gap between keys).

### Debug flags

`--windowed`, `--open terminal,browser`, `--workspace N`, `--launcher`, `--help-overlay`,
`--type 'cmd\n'` (types into all terminals), `--snapshot out.png` (renders the desktop and quits),
`--no-confirm-quit`.
