# chituview — Design Spec

**Date:** 2026-07-22
**Status:** Approved for implementation planning

## Purpose

A read-only, live terminal dashboard for Chitu-based resin 3D printers that speak
the **SDCP (Smart Device Control Protocol) V3.0.0** over the local network. It
discovers a printer (or takes its IP), opens a WebSocket, and renders live print
status — filename, progress bar, layer counts, elapsed/remaining time, error
state — updating in real time. A keypress opens the printer's camera in an
external video player.

Developed against a **UniFormation GK3 Pro** (firmware V1.4.9) but the protocol is
shared across Chitu-firmware printers (Elegoo, other UniFormation), so the tool is
intentionally not model-specific.

### Read-only by design (v1)
v1 sends **no print-control commands** (no pause/resume/stop, no file management).
The only commands it issues are status/attribute queries and the camera
enable/disable toggle. This removes any risk of interrupting an in-progress print.
Control features are explicitly deferred (see Out of Scope).

## Background: the SDCP protocol (verified against the real printer)

Full reconnaissance notes live at `~/uniformation-gk3pro-sdcp-reference.md`. The
essentials this project depends on:

- **Discovery** — UDP. Send ASCII `M99999` to port **3000** (broadcast to find
  printers, or unicast to a known IP). Printer replies with a JSON identity object
  containing `MainboardID`, `MainboardIP`, `MachineName`, `BrandName`,
  `FirmwareVersion`, `ProtocolVersion`.
- **Control/status** — WebSocket at `ws://<ip>:3030/websocket`. Plain `ws://`
  (no TLS). Request envelope:
  ```json
  {
    "Id": "<hex>",
    "Data": { "Cmd": <int>, "Data": {…}, "RequestID": "<hex>",
              "MainboardID": "<id>", "TimeStamp": <unix>, "From": 0 },
    "Topic": "sdcp/request/<MainboardID>"
  }
  ```
  The printer **pushes** messages unprompted on topics `sdcp/status/<id>`,
  `sdcp/attributes/<id>`, `sdcp/response/<id>`, `sdcp/error/<id>`.
- **Camera** — not always streaming. Send `Cmd 386 {"Enable":1}`; the printer
  starts RTSP and replies with `VideoUrl` (`rtsp://<ip>:554/video`, H.264
  1280×720). `Cmd 386 {"Enable":0}` stops it. Max 2 concurrent viewers.

### Commands used by v1
| Cmd | Purpose |
|-----|---------|
| `0`   | Request status refresh |
| `1`   | Request attributes |
| `386` | Enable/disable camera → returns `VideoUrl` |

Status enums and other command numbers are recorded in `Chituview::Protocol` but
unused commands are not issued in v1.

### Real captured payloads (used as test fixtures)
The status and attributes JSON captured from the live printer are checked into
`test/fixtures/` and drive the `PrinterState` parsing tests. Example status:
```json
{ "Status": { "CurrentStatus": [1], "PrintInfo": {
  "Status": 2, "CurrentLayer": 1514, "TotalLayer": 1697,
  "CurrentTicks": 16852229, "TotalTicks": 18818950,
  "ErrorNumber": 0, "Filename": "bison - rays.ctb",
  "TaskId": "9baff5e4-…" } } }
```

## Architecture

Two layers with a clean seam between them: a protocol layer with no UI (fully unit
testable), and a TUI layer built on the charm-ruby Elm architecture.

### Layer 1 — Protocol (no UI)

**`Chituview::Discovery`**
- `.discover(timeout:, broadcast_addr:)` → `[PrinterInfo, …]` — UDP broadcast
  `M99999` on :3000, collect + parse replies until timeout.
- `.probe(ip, timeout:)` → `PrinterInfo | nil` — unicast to a known IP.
- `PrinterInfo` is a small struct (`name`, `ip`, `mainboard_id`, `machine_name`,
  `brand`, `firmware`, `protocol`).
- Socket is injectable for testing.

**`Chituview::Protocol`**
- Constants: command numbers (`STATUS=0`, `ATTRIBUTES=1`, `CAMERA=386`), status
  enums, topic prefixes.
- `.request(cmd:, mainboard_id:, data: {}, timestamp:, id:, request_id:)` → Hash
  envelope. IDs/timestamp are injectable so output is deterministic under test.
- `.classify(topic)` → `:status | :attributes | :response | :error | :unknown`.

**`Chituview::Client`**
- Wraps a `TCPSocket` + the `websocket` gem for handshake/framing.
- `#connect` — TCP connect, WebSocket handshake, start reader thread.
- Reader thread: `readpartial` → feed frames → parse JSON → wrap as a typed
  message (`{type:, payload:}`) → push onto a thread-safe `Queue` exposed via
  `#inbox`.
- `#request(cmd, data = {})` — serialize an envelope and send a text frame.
- `#close` — stop reader thread, close socket.
- The socket factory is injectable (`connect_socket:` lambda) so tests drive a
  fake bidirectional pipe instead of a real printer.

**`Chituview::PrinterState`**
- Immutable value object built from a status payload via
  `.from_status(hash, attributes: nil)`.
- Derived, presentation-ready fields: `filename`, `current_layer`, `total_layer`,
  `progress` (0.0–1.0), `status_label` (human string from enum), `error?`,
  `error_number`, `elapsed` / `remaining` (Durations from ticks), `printing?`.
- Pure data + arithmetic; no I/O. Heavily unit-tested against real fixtures.

### Layer 2 — TUI (charm-ruby: bubbletea / lipgloss / bubbles)

**`Chituview::Dashboard`** — the Bubbletea Model.
- State: current `PrinterState`, `PrinterInfo`/attributes, connection status
  (`:connecting | :live | :reconnecting | :error`), last-error message, a
  `bubbles` Progress component, quitting flag.
- `#init` → returns the initial command batch (start the inbox-listen loop; kick a
  status refresh; start a redraw tick).
- `#update(msg)`:
  - `StatusMsg` → replace `PrinterState`, mark `:live`, re-issue the listen cmd.
  - `AttributesMsg` → store attributes.
  - `ConnLostMsg` → set `:reconnecting`, schedule a reconnect command (backoff).
  - `TickMsg` → advance spinner/animation, re-issue tick.
  - `KeyMsg`: `q`/`ctrl+c` → quit (disable camera, close client); `c` → camera
    command; `r` → force reconnect.
- `#view` → pure function of state, rendered with lipgloss (see Layout).

**Async bridge (the one real technical risk).** Status frames arrive on the
client's reader thread; Bubbletea runs a synchronous loop. The mechanism to inject
external messages into the loop will be confirmed by a **spike before full
implementation**:
- Preferred: the Ruby port exposes a `program.send(msg)`-style injector (Go's
  `Program.Send`). The reader thread calls it directly.
- Fallback: a Bubbletea command that blocks on `client.inbox` with a short timeout
  (e.g. `Queue#pop` via a timed wrapper), returns the next message, and is
  re-issued from `update` (the standard "listen for activity" pattern).
Both are viable; the spike only decides which. This is the first implementation
task and gates the rest of the TUI work.

**`Chituview::Camera`**
- `#open(client, ip)` — send `Cmd 386 {"Enable":1}`, read `VideoUrl` from the
  response, `Process.spawn` a detached viewer trying `mpv` → `ffplay` → `vlc`.
- Returns a status string for the footer (`"camera opened in mpv"` /
  `"no video player found"`); never raises into the UI.
- On dashboard quit, best-effort `Cmd 386 {"Enable":0}`.

**`Chituview::CLI` + `bin/chituview`**
- Args: `chituview [IP]`, `--discover` (list found printers and exit),
  `--timeout N`, `--help`, `--version`.
- No IP → run discovery; if exactly one printer, use it; if several, list and let
  the user pass one; if none, print a manual-IP hint.
- Then construct `Client`, connect, and hand off to `Bubbletea.run(Dashboard.new(…))`.

## Data flow
```
UDP discovery ─► PrinterInfo (ip + mainboard_id)
      │
      ▼
Client#connect (WS handshake) ─► reader Thread ─► inbox Queue ─┐
      │  request(0) status, request(1) attributes              │
      ▼                                                         ▼
Bubbletea.run(Dashboard): listen cmd drains inbox ─► StatusMsg ─► update ─► view
      ▲                                                                       │
      └─────────── KeyMsg: c=camera · r=reconnect · q=quit ◄──────────────────┘
```

## UI layout (lipgloss)
```
┌─ UniFormation GK3 Pro · 192.168.50.133 ──────────┐
│ bison - rays.ctb                                 │
│ ████████████████████░░░░   89%   layer 1514/1697 │
│ status: printing        error: none              │
│ elapsed 4h 40m          remaining ~32m           │
├──────────────────────────────────────────────────┤
│ ● live   ·   [c]amera   [r]econnect   [q]uit      │
└──────────────────────────────────────────────────┘
```
- Border color reflects connection status (green live / yellow reconnecting /
  red error).
- Progress bar is the `bubbles` Progress component.
- When disconnected, the body shows the last-known state dimmed with a
  "reconnecting…" banner.

## Error handling
| Condition | Behavior |
|-----------|----------|
| Discovery finds nothing | Message + hint to pass IP explicitly; exit non-zero |
| WS connect fails | Retry with capped exponential backoff; show `:connecting` |
| WS closes / read error mid-run | `:reconnecting`, auto-retry with backoff, keep last state on screen |
| Malformed / unknown frame | Skipped; optionally counted in a debug tally |
| Camera: no player / cmd 386 error | Non-fatal footer note; dashboard continues |
| `q` / SIGINT | Disable camera (best effort), close client, restore terminal, exit 0 |

Auto-reconnect is in scope for v1 (confirmed): capped exponential backoff, last
state remains visible while reconnecting.

## Testing (minitest, TDD)
- **Protocol**: envelope shape with injected id/timestamp; `classify` topics.
- **PrinterState**: parsing + all derived fields, driven by the **real captured
  payloads** in `test/fixtures/` (status mid-print, attributes, edge cases:
  layer 0, total 0, error set, missing fields).
- **Discovery**: parse a canned identity reply via an injected fake UDP socket.
- **Client**: injected fake socket/pipe feeds frames; assert inbox receives typed
  messages and `request` serializes correct bytes.
- **View**: `Dashboard#view` is pure over state → assert rendered string contains
  expected fields for representative states (live, reconnecting, error, camera
  note). ANSI may be stripped for stable assertions.
- **Camera**: injected spawn stub → assert correct viewer/URL selection and
  fallback order; no real process launched.

The async-bridge spike is validated by a small live/manual smoke test, not a unit
test.

## Gem structure
```
~/Repos/chituview/
├── chituview.gemspec
├── Gemfile
├── Rakefile
├── README.md
├── bin/chituview
├── lib/
│   ├── chituview.rb
│   └── chituview/
│       ├── version.rb
│       ├── cli.rb
│       ├── discovery.rb
│       ├── protocol.rb
│       ├── client.rb
│       ├── printer_state.rb
│       ├── camera.rb
│       └── dashboard.rb
└── test/
    ├── test_helper.rb
    ├── fixtures/            # real captured SDCP payloads
    └── *_test.rb
```

### Dependencies
- Runtime: `bubbletea`, `lipgloss`, `bubbles`, `websocket`
- Development: `minitest`, `rake`
- External (optional, runtime): `mpv` / `ffplay` / `vlc` for the camera

## Out of scope (v1 — deferred)
- Any print control (pause/resume/stop) or file management (list/upload/delete/
  start print). The protocol layer will note the relevant command numbers but the
  UI will not issue them.
- In-terminal camera rendering (sixel/kitty) — unreliable under tmux; external
  player only.
- Multi-printer simultaneous dashboards, cloud/remote access, historical task
  browsing, timelapse.

## Open items resolved
- Test framework: **minitest**.
- Auto-reconnect: **in scope** for v1.
- Camera: **external viewer** (`mpv` → `ffplay` → `vlc`), triggered by `c`.
- Name: **chituview**.
