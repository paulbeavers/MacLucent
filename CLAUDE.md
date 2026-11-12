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
- **Terminal scroller hidden**; terminal tint only fills the padding ring (no double alpha).
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

Debug flags / env: `--windowed`, `--borderless`, `--open terminal,browser`, `--workspace N`,
`--launcher`, `--help-overlay`, `--type 'cmd\n'`, `--snapshot out.png`, `--no-confirm-quit`,
`--bench-typing` (+`ML_BENCH_INTERVAL`), `ML_LATENCY_LOG=1`, `ML_PTY_LOG=<file>`,
`ML_WINDOW_LOG=1`, `ML_SESSION_FILE=<path>`, `ML_NO_SESSION=1`, `ML_BLUR=1`, `ML_BACKGROUND=1`.
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

- **Branch `native-apps-wip` (pushed to origin):** tiling real Mac app windows via the
  Accessibility API (yabai/AeroSpace approach: position real windows over tiles, park off-screen
  per workspace, CGEvent tap for global hotkeys, backdrop window level). Paused — Dock pop-up and
  window sizing issues; user said "more than I want to deal with now". True embedding of other
  apps' windows is impossible on macOS.
- **App ideas discussed** (none started): Ports/dev-servers list, Scratchpad notes, Projects
  (per-project workspace layouts), Git status/diff, Files browser, Markdown/HTML live preview,
  Dev toolbox (JSON/Base64/JWT/regex), clipboard history, HTTP client.
- Browser can't embed real Safari (SFSafariViewController is iOS-only) or Firefox (no Gecko
  embedding on macOS); CEF (Chromium) would be possible but heavy.
- Name check: "Tatami" is taken by a macOS tiling workspace manager; "Lucent" has no WM conflict
  (Nokia holds a LUCENT telecom mark — check USPTO before any commercial release).
