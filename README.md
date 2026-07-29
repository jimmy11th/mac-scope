# MacScope

MacScope is a focused, keyboard-driven system monitor and process manager for macOS.
It presents live CPU, memory, disk, and network status together with a sortable unified
process table and guarded macOS maintenance tools.

## Features

- Live CPU and SoC temperature, memory pressure, data-volume capacity, disk I/O,
  and network throughput
- One unified Top 5 process table with sortable CPU, memory, disk, network, PID,
  thread-count, and runtime columns
- Per-process resource details, 60-second trends, files, and network connections
- Search and dashboard filters (`user:NAME` and `pid:NUMBER` are supported)
- Guarded terminate, force-kill, pause, resume, and nice-priority actions
- Junk scanning, application uninstall with exact Bundle ID residue detection, large-file
  and duplicate-file cleanup, and memory relief
- App-centered uninstall workflow: related cache, preferences, saved state, application
  data, and container data are selectable only after their owning app is selected
- Responsive process/tools workspace with compact tabs
- Runtime-adjustable Top process count, defaulting to five rows
- Persistent language, refresh, row count, temperature, smoothing, interface, and
  process-list preferences, plus cache cleanup behavior and large-file threshold
- Six built-in themes, live color editing, and portable JSON theme import/export

## Requirements

- macOS 13 or newer
- Python 3.11 or newer
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

## Native shell prototype

The phase-one macOS shell keeps the Textual interface intact while hosting it in a
standard AppKit window backed by a SwiftTerm pseudo-terminal. It is a development
prototype: it launches the repository through `uv` and does not yet bundle Python or
request elevated permissions.

Build and open the application with:

```bash
native/scripts/run_app.sh
```

Run the native launch-configuration checks with:

```bash
swift run --package-path native MacScopeShellConfigCheck
```

The generated ad-hoc-signed application is written to
`native/build/MacScope.app`. Set `MACSCOPE_UV_PATH` before building when `uv` is not on
the current `PATH`. The shell never opens Terminal.app.

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
Simplified Chinese available. Refresh intervals are `0.5`, `1`, `2`, or `5` seconds;
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

During application uninstall, the application is processed before its selected related
data. If the application cannot be removed, its related data is left untouched. If the
application succeeds but a related item fails, the completed application remains as a
context row while each retained item shows its exact state and stays available for retry.

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
