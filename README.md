# MacScope

MacScope is a focused, keyboard-driven system monitor and process manager for macOS.
It presents live CPU, memory, disk, and network status together with a sortable unified
process table and guarded macOS maintenance tools.

## Features

- Live CPU and SoC temperature, memory pressure, data-volume capacity, disk I/O,
  and network throughput
- One unified Top 20 process table with sortable CPU, memory, disk, network, PID,
  thread-count, and runtime columns
- Per-process resource details, 60-second trends, files, and network connections
- Search and dashboard filters (`user:NAME` and `pid:NUMBER` are supported)
- Guarded terminate, force-kill, pause, resume, and nice-priority actions
- Junk scanning, application uninstall with exact Bundle ID residue detection, large-file
  and duplicate-file cleanup, and memory relief
- Single-application uninstall review with selectable related data and other installed
  copies available as optional items in the same removal operation
- Per-item cleanup paths, states, animated activity feedback, and determinate progress
  remain visible after each cleanup operation
- Responsive low-overhead monitoring, compact native overlay scrollers, and an adjustable
  translucent sidebar that samples content behind the MacScope window
- Native Help and About interfaces with direct access to the GitHub project
- Responsive process/tools workspace with compact tabs
- Runtime-adjustable Top process count, defaulting to 20 rows
- Persistent language, refresh, row count, temperature, smoothing, interface, and
  process-list preferences, plus cache cleanup behavior and large-file threshold
- Six built-in themes, live color editing, and portable JSON theme import/export

## Requirements

- macOS 13 or newer for the native app
- Python 3.11 or newer for the terminal app
- A terminal with Unicode and 256-color support

MacScope uses the built-in macOS `nettop`, `memory_pressure`, and `vm_stat` tools. It
does not request administrator privileges. macOS may prevent inspection or management
of protected system processes; MacScope reports those failures without invoking
`sudo`. Cleanup failures are classified per item, including administrator approval,
Full Disk Access, ordinary permission denial, running applications, and files changed
since scanning. Failed items remain visible and can be retried after the underlying
issue is resolved. MacScope never displays its own password field or reads administrator
credentials. On supported Apple Silicon Macs, SoC temperature is read directly from the
local IOHID temperature sensors, also without elevated privileges.

## Run from the repository

```bash
uv sync
uv run macscope
```

To install the command for the current user:

```bash
uv tool install .
macscope
```

## Native macOS app

The native app is a standalone SwiftUI/AppKit application with no terminal, Python,
Textual, or `uv` runtime dependency. It provides live CPU and SoC temperature, memory,
disk, and network status; per-process disk and network activity; a searchable and sortable
native process table; a 60-second process inspector; guarded quit actions; and persistent
monitoring, appearance, cleanup, language, and theme settings. Native system tools cover
junk cleanup, reviewed application uninstall with exact Bundle ID residue matching, large
files, duplicate files, and inactive file-cache release. Destructive operations show every
path and its progress, use Trash by default, and request administrator approval only through
the standard macOS authorization dialog when it is actually required.

Build and open the application with:

```bash
native/scripts/run_app.sh
```

The generated ad-hoc-signed application is written to
`native/build/MacScope.app`.

Build a compressed development DMG with:

```bash
native/scripts/build_dmg.sh
```

The default image is written to `native/build/MacScope-0.4.6-dynamic-metrics.dmg`. The
app is ad-hoc signed and not notarized, so it is intended for local development rather
than public distribution.

## Keyboard

| Key | Action |
| --- | --- |
| `Tab`, `Shift+Tab` | Move between the process table and tools |
| Arrow keys | Select a process |
| Click a table header | Sort ascending or descending |
| `1`, `2`, `3`, `4` | Sort by CPU, memory, disk read, or network download |
| `Enter` | Open process details |
| `/` | Search all processes |
| `f` | Filter the process table |
| `t` | Send `SIGTERM` after confirmation |
| `k` | Send `SIGKILL` after confirmation |
| `Space` | Pause or resume a process after confirmation |
| `r` | Change nice priority after confirmation |
| `s` | Open Settings |
| `l` | Set the Top process count from 1 to 20 |
| `+`, `-` | Add or remove one Top process row |
| `p` | Pause or resume monitoring |
| `?` | Open the complete in-app keyboard reference |
| `q` | Quit |

Process CPU follows the macOS convention and may exceed 100% when a process uses more
than one core. Disk and network rates are interval deltas; the first sample is shown as
zero until a second set of counters is available.

## Settings

Press `s` to configure MacScope. English is the default interface language, with
Simplified Chinese available. Refresh intervals are `0.5`, `1`, `2`, or `5` seconds,
with `2` seconds as the default;
the default Top row count can be set from 1 to 20. Temperature can be displayed in
Celsius or Fahrenheit. Smoothing, network-interface selection, MacScope process
visibility, and inactive I/O rows are configurable as well.

Default process sorting, duplicate-file minimum size, and maintenance scan folders are
configurable. These preferences are stored with the rest of the application settings and
restored on the next launch. File selections, scan results, and destructive confirmations
are intentionally session-only.

Maintenance settings control whether rebuildable caches are moved to Trash or deleted
permanently, and set the large-file scan threshold. Applications, residues, large files,
duplicates, logs, and diagnostic reports always go to Trash. MacScope never empties the
Trash, requests `sudo`, or terminates processes without confirmation.

Application uninstall starts with one selected app. Its review dialog contains the app,
Bundle ID, exact path, selectable related data, and any other registered copies with the
same Bundle ID. Those copies can be selected and removed in the same operation. Applications
are processed before selected related data; if the original app cannot be removed, its
related data is left untouched. Every processed path keeps its exact success or failure state
visible and failed items remain available for retry.

Large-file and duplicate scans cover the current user's Downloads, Desktop, Documents,
and Movies folders by default. The folders can be changed in Settings. Application
uninstall scans `/Applications` and `~/Applications`,
while excluding macOS system applications. Package contents and symbolic links are not
traversed.

Settings are saved atomically to:

```text
~/Library/Application Support/MacScope/settings.plist
```

The `+`, `-`, and `l` shortcuts change the Top row count for the current session. Set
**Default Top rows** in Settings to persist a value for future launches.

## Themes

Built-in themes are Graphite Dark, Paper Light, Solarized Dark, Nord, Monokai, and High
Contrast. Theme changes preview immediately. **Customize** opens the color editor with
hex inputs, swatches, and a text-contrast check. Custom themes are stored in:

```text
~/Library/Application Support/MacScope/themes/
```

Use **Import** and **Export** in Settings with `.macscope-theme.json` files. Theme files
accept only MacScope's semantic color tokens, not arbitrary Textual CSS. A theme may
contain every token or inherit from an installed theme and override a subset:

```json
{
  "format": "macscope-theme",
  "version": 1,
  "id": "ocean",
  "name": "Ocean",
  "author": "Example",
  "mode": "dark",
  "extends": "graphite-dark",
  "colors": {
    "accent": "#4CC9F0",
    "cpu": "#4CC9F0",
    "memory": "#72EFDD",
    "disk": "#F9C74F",
    "network": "#F15BB5"
  }
}
```

Available tokens are `background`, `surface`, `surface_alt`, `border`, `text`, `muted`,
`accent`, `focus`, `selection_background`, `selection_text`, `cpu`, `memory`, `disk`,
`network`, `normal`, `warning`, and `danger`. Colors must use `#RRGGBB` format. Imported
themes are fully validated, including their inheritance chain, before MacScope saves
them.
