# CLAUDE.md — Lucent

Lucent is a native macOS app (Swift/AppKit, no Xcode project — SwiftPM + a build script)
that gives a **Hyprland-style tiling workspace** inside one full-screen window: workspaces,
dwindle tiling, gaps/rounded/gradient borders, a waybar-like top bar, and tiled apps
(bash terminals, a tabbed WebKit browser, Settings, Stats). It is "Lucent for the Mac" — the
macOS counterpart of the user's **Lucent Hyprland config** project. Formerly named *mac-lucent*.

The README covers user-facing features and keybindings; this file covers how to work on it.

## Build, run, ship

```bash
./scripts/build-app.sh            # release → build/Lucent.app (debug: ./scripts/build-app.sh debug)
open build/Lucent.app             # native full screen (own Space); --windowed / --borderless also exist
```

- After every change: **rebuild `build/Lucent.app`** so the user can just relaunch it.
- The build script stamps the git commit (`MLGitCommit`, "(modified)" if dirty) and SwiftTerm
  version into Info.plist — Stats shows them. Rebuild after committing so it shows the clean hash.
- Ad-hoc signed with a stable designated requirement (bundle id) in `scripts/build-app.sh`.
- Remote: `git@github.com:paulbeavers/MacLucent.git` (SSH works). **Don't rename the remote.**
- Bundle ID stays `dev.maclucent.mac-lucent` (changing it would drop browser cookies/logins).
  Swift module/target stays `MacLucent`; SwiftPM product is `lucent`.

## Architecture (Sources/MacLucent)

| File | Role |
|---|---|
| `main.swift`, `AppDelegate.swift` | Window setup (native full screen default), menus, full-screen title-bar hiding, autosave timer, debug flags |
| `Core/WindowManager.swift` | The "compositor": workspaces, focus, keybindings (local NSEvent monitor), animations, floating drags |
| `Core/LayoutTree.swift` | Dwindle binary tree: insert/remove/swap/resize, geometry, neighbour search |
| `Core/Workspace.swift` | Workspace model (tiled/floating mode) + view (gap-drag resize, floating edge resize, empty hint) |
| `Core/TileWindow.swift` | Window decoration: gradient border, rounding, shadow, dim |
| `Core/Config.swift` | All settings (hyprland.conf-like), persistence to `~/.config/lucent/settings.json`, legacy-folder migration |
| `Core/Session.swift` | Session save/restore (`session.json`), app-agnostic |
| `Core/BundledFonts.swift` | Registers fonts in `Resources/Fonts` for the process |
| `Core/Themes.swift`, `UI/ThemePicker.swift` | Lucent `*.theme` parser, `Palette` (19 roles), theme library; Settings grid + launcher picker |
| `Apps/TileApp.swift` | **`TileApp` protocol, `AppDescriptor`, `AppRegistry`, `AppShortcut`, `JSONValue`** |
| `Apps/TerminalApp.swift` / `TerminalCompat.swift` | SwiftTerm terminal running bash; PTY output filter |
| `Apps/BrowserApp.swift` | Tabbed WKWebView browser (`BrowserTab`, `TabBarView`) |
| `Apps/SettingsApp.swift`, `Apps/StatsApp.swift`, `Apps/SystemStats.swift` | Settings UI; Stats dashboard + samplers |
| `Apps/ScratchpadApp.swift`, `Apps/NotesStore.swift` | Scratchpad: Markdown notes as files in `~/.config/lucent/notes` (`MarkdownStyler`, click-to-toggle tasks) |
| `Apps/PortsApp.swift`, `Apps/PortScanner.swift` | Ports: listening TCP sockets via libproc (`isDev` filter), open/terminal/stop actions |
| `UI/` | Desktop (wallpaper, stage, overlays), bar, launcher + help overlays |
| `LatencyProbe.swift`, `TypingBenchmark.swift` | Debug-only typing latency tools |

### Adding an app = one file + one registry entry
Conform to `TileApp` (view, title, symbolName, focus, shutdown; optional handleKey,
requestClose, sessionState) and add an `AppDescriptor` to `AppRegistry.apps` (id, name, symbol,
`shortcut: .key("X")`, `make`, optional `restore`, `singleInstance`). Launcher, shortcut, help
sheet, File menu, empty-workspace hint, Stats counts and session restore all derive from it.
Don't add per-app `switch` statements elsewhere. App shortcuts must not clash with WM keys
(D W F J Tab, digits, arrows).

### Conventions
- Everything is `@MainActor`; AppKit callbacks/KVO/timers wrap in `MainActor.assumeIsolated`.
- Coordinates: workspace/tile views are flipped (y down).
- Colors come from `Config.shared.palette` (the active theme's 19 Lucent roles; `accent` = mauve,
  the highlight role). Theme and settings changes post `.configDidChange` — every view that reads
  colours must recolour on it (`refreshColors`/`applyColors` pattern; Settings rebuilds its form).
  Never hard-code colours; use `c.appearance` instead of `.darkAqua` (light themes exist).
- **Themes are shared with the sibling repo `../lucent` (the Hyprland config).** Its
  `config/hypr/themes/*.theme` is the source of truth; `scripts/sync-themes.sh` copies them into
  `Resources/Themes` (build does this). Mapping mirrors `theme.sh`/`theme.lua`: focused border
  mauve→blue 45°, unfocused `border`/surface0, terminal = foot's ANSI mapping, `terminal` key =
  another theme's terminal palette, light themes → opaque terminal and no black dimming.
- Shortcuts use `Config.shared.mod` (⌘ or ⌥, user setting), never hard-coded `.command`;
  display strings written with "⌘" go through `Config.shortcut()` / `modSymbol`.
- Swift 6.4 toolchain, Swift 5.9 language mode; keep the build warning-free.

## Decisions you must not undo (and why)

- **SwiftTerm pinned to exactly 1.10.1.** 1.99.x (pre-2.0) has an off-main render loop that
  stalled 150–300 ms on real typing; 1.11–1.20 need the Metal toolchain (not installed:
  `xcodebuild -downloadComponent MetalToolchain`). 1.10.1 = CoreGraphics renderer, fast.
- **`TerminalOutputFilter`** strips `CSI ? u` / `CSI > n u` / `CSI < u` / `CSI = n u` from PTY
  output: SwiftTerm 1.10.1 treats every `CSI … u` as restore-cursor, which made Claude Code's
  prompts redraw at the top of the window. Handles sequences split across reads.
- **bash starts via Lucent's rc file**, not `--login`: `bash --rcfile <tmp>/lucent-bash-startup.sh -i`
  (written by `TerminalApp.startupFile`). It sources /etc/profile, then ~/.bash_profile /
  .bash_login / .profile, else ~/.bashrc (the user has only a ~/.bashrc — the Lucent Mac bash setup —
  and zsh as login shell; a plain login bash skipped it and looked bare), then prepends
  `__lucent_osc7` to PROMPT_COMMAND (passing PROMPT_COMMAND via env was overwritten by the user's
  rc). Don't edit the user's dotfiles to fix shell setup.
- **Window operations (`CSI Ps;… t`, XTWINOPS) never reach SwiftTerm.** In this build its
  `windowCommand` traps with "unexpected enum case" (Neovim sends `CSI 22;0;0t` at startup — it
  crashed Lucent). `TerminalOutputFilter` removes them and `LucentTerminalView.answerWindowOp`
  answers the size queries (14/15/16/18/19, 20/21 empty); move/resize/title-stack are ignored.
- **macOS window restoration is off** (`ApplePersistenceIgnoreState`, `isRestorable = false`):
  Lucent restores its own session, and after a crash macOS otherwise blocks the next launch with
  a modal "reopen windows?" alert (it froze a test instance on the user's screen).
- **Terminal scroller hidden**; terminal tint only fills the padding ring (no double alpha).
- **Split borders are dragged in `WindowManager`'s local event monitor** (`beginSplitDrag` /
  `continueSplitDrag`), not by `WorkspaceView`'s mouseDown: AppKit's routing to the view behind the
  tiles stopped delivering those drags (user: "any horizontal resize does not work — it used to").
  The monitor sees every event first, so it works whatever is under the pointer. The grab zone
  (`LayoutTree` divider rects) covers the gap plus 5 px into each tile, so grabbing a border works;
  the resize cursor is set (deferred) from the mouse-moved monitor. Note: synthetic drag events
  sent with `NSApp.sendEvent` are NOT routed to a view's `mouseDragged` — test drags through the
  monitors (which do see them), or call the handlers directly.
- **Overlays on top of app content must not take mouse events.** AppKit hit-tests views even at
  `alphaValue` 0: `TileWindow`'s inactive-dim view covered every tile and swallowed mouse-wheel
  scrolling (trackpad and Page Up/Down still worked, which hid it). It is now a
  `PassthroughView` (`hitTest` → nil); use that for any purely visual overlay. To debug input
  routing, check `window.contentView?.hitTest(pointInWindow)` — it should be the app's own view.
- **Ports app** (`Mod+P`): `PortScanner` walks every PID with libproc (`proc_listpids` →
  `PROC_PIDLISTFDS` → `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`, TCP sockets in `TSI_S_LISTEN`); no
  `lsof` subprocess. Only the user's own processes are visible (fine — those are the ones they
  can stop). Full scan < 0.1 s, refreshed every 2 s only while the tile is on screen. IPv4/IPv6
  sockets for the same pid+port merge into one row ("*" > "localhost" > address). Default filter
  is `ListeningPort.isDev`: working directory ≠ "/" (app helpers and macOS services run from "/")
  or a name in `devTools`; everything else is behind "Show all" — on this Mac that hides
  ControlCenter/AirPlay, rapportd, Adobe/Creative Cloud helpers and VS Code's helper. Add tools to
  `devTools` rather than loosening the folder rule. Actions use `WindowManager.openURL` (new tab in
  an existing browser, else a browser tile) and `openTerminal(in:)`; Stop = SIGTERM, then an
  NSAlert offering SIGKILL.
- **Native full screen is the default** (user wants the separate Space / Mission Control page).
  The notch strip is intentionally unused — user said not to worry about it. The title bar is
  hidden in full screen (container + AppKit's lazily created full-screen title-bar window made
  transparent/shadowless) so only the menu bar reveals — no faint line.
- **Blur off by default** (`ML_BLUR=1` / Settings) — costs compositing time.
- Menu items for app launches follow the modifier key; Settings… stays in the app menu.
- ⌥Tab cycles **only workspaces that have windows** (user tried "all workspaces" and reverted).
- Session restore: on by default; old-format session files still load (`resolvedState`).
  Test runs never read/write the session or migrate the config folder.

## Testing without disturbing the user (important)

The user runs Lucent while we work. Test instances must not interfere:
- Launch tests with **`ML_BACKGROUND=1`** (never activates/steals keyboard focus) and a
  self-terminating flag like `--snapshot <png>`; or background them with `& P=$!` and `kill $P`.
- **Never `pkill`/`killall` the app by name** — it kills the user's copy (happened once).
- Never launch a test in native full screen (it creates a Space on the user's screen) — use `--windowed`.
- Screen capture isn't permitted; `--snapshot` renders the desktop via `layer.render` (image is
  vertically flipped — `sips -f vertical`; a just-opened terminal may render blank — harmless).
- For one-off checks, add a temporary env-gated hook in `AppDelegate.runDebugArguments`, run, then
  restore the file from a backup copy (pattern used throughout). Synthetic keys/mouse via
  `NSApp.sendEvent(NSEvent.keyEvent/mouseEvent …)` go through the real monitors.
- No Accessibility permission for the shell: can't post real HID events.
- **Never clear website data (cookies/cache) from a test instance**: test copies use the same
  bundle ID, so `WKWebsiteDataStore.default()` is the user's real browser store — clearing it signs
  them out everywhere. Test `BrowsingData` history clearing only (the `.clearBrowserHistory`
  notification), and never open the modal Clear dialog in a background test.
- To test Ports, start a throwaway server in the scratchpad (`python3 -m http.server PORT --bind
  127.0.0.1` from a scratch folder), keep its PID and kill it afterwards. For quick scanner checks,
  compile `PortScanner.swift` plus the `ProcStats` part of `SystemStats.swift` into a small CLI with
  `swiftc` (StatsSampler references `TerminalApp`, so extract just `ProcStats`). Don't trigger Stop
  in a test instance — its NSAlert is modal and appears on the user's screen.

Debug flags / env: `--windowed`, `--borderless`, `--open terminal,browser`, `--workspace N`,
`--launcher`, `--help-overlay`, `--type 'cmd\n'`, `--snapshot out.png`, `--no-confirm-quit`,
`--bench-typing` (+`ML_BENCH_INTERVAL`), `ML_LATENCY_LOG=1`, `ML_PTY_LOG=<file>`,
`ML_WINDOW_LOG=1`, `ML_SESSION_FILE=<path>`, `ML_NOTES_DIR=<dir>` (Scratchpad tests — never touch
the user's notes), `ML_NO_SESSION=1`, `ML_BLUR=1`, `ML_BACKGROUND=1`.
Logs go to `~/Library/Logs/Lucent/`.

## Working with this user

- **Commit and push only when asked** ("commit and push"). Split unrelated changes into separate
  commits (hunk-level when files are shared; verify the first commit builds on its own).
  Commit messages end with the Co-Authored-By line from the session.
- After building, say plainly whether it's built and how to relaunch (`open build/Lucent.app`).
- They test by hand and report; ask for specifics (which app, what happened) when vague.
- Prefers Option (⌥) as modifier, floating workspace 1, focus-follows-mouse + raise-on-hover,
  Cascadia Code font — but these are their settings, not defaults to hard-code.

## Parked work and ideas

- **Tiling native Mac apps — tried twice and dropped (user decision, 2026-11-11). Don't propose
  it again unless asked.** True embedding of another app's window is impossible on macOS; the only
  route is the yabai/AeroSpace one (Accessibility API positions real windows over tiles, parks them
  off-screen per workspace, CGEvent tap for global hotkeys, Lucent's window as a desktop-level
  backdrop). Problems hit: app windows can't enter Lucent's full-screen Space (they opened on the
  wrong Space/workspace), the Dock appears whenever another app is frontmost (only fixable by
  toggling the system Dock auto-hide), and apps fight the sizes they're given. The branches
  (`native-apps-wip`, `native-apps`) were deleted; Lucent has only its own built-in tile apps.
- **App ideas discussed** (Ports and Scratchpad are done): Projects
  (per-project workspace layouts), Git status/diff, Files browser, Markdown/HTML live preview,
  Dev toolbox (JSON/Base64/JWT/regex), clipboard history, HTTP client.
- Browser can't embed real Safari (SFSafariViewController is iOS-only) or Firefox (no Gecko
  embedding on macOS); CEF (Chromium) would be possible but heavy.
- Name check: "Tatami" is taken by a macOS tiling workspace manager; "Lucent" has no WM conflict
  (Nokia holds a LUCENT telecom mark — check USPTO before any commercial release).
