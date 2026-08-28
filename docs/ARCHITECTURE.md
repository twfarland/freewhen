# Architecture

About 1,170 lines of Erlang across 32 modules and 735 of TypeScript across 9,
plus 815 lines of tests. Staying that size is the design constraint: everything
below exists because a requirement needs it.

## The shape

```
  browser                                    one BEAM node
  ┌───────────────────────┐                  ┌───────────────────────────────┐
  │ preset + drag to paint│                  │  fw_web                       │
  │        ↓              │  POST /api/rooms │   http/  ws/  json/           │
  │  busy bits + timezone │ ───────────────► │            │                  │
  │        ↕              │                  │  fw_runtime│                  │
  │  format instants in   │  ws /ws/rooms/:h │   ports/  rooms/  support/    │
  │  everyone's timezone  │ ◄──────────────► │            │                  │
  └───────────────────────┘  computed state  │  fw_core   │                  │
                                             │   domain/  — pure functions   │
                                             └───────────────────────────────┘
```

**The server decides; the browser formats.** Every domain fact is computed in
`fw_core` and published whole — the heatmap, the ranked proposals *with their
UTC start and end instants*, who has answered, whether the room is settled. The
client turns instants into words. See
[ADR 0009](adr/0009-the-server-decides-the-browser-formats.md).

What crosses left to right: a set of busy slots and an alias. Nothing else
exists to send — there is no calendar integration
([ADR 0006](adr/0006-availability-is-entered-by-hand.md)) and no timezone
([ADR 0010](adr/0010-the-server-holds-no-timezone.md)). Every instant the
server holds is UTC; each browser canonicalises against its own locale.

## The three applications

Dependencies point one way, enforced by `.claude/hooks/check_erl.escript` and
`xref`. Inside each app, the directory says what a module *is*.

### `fw_core/src/domain/` — the domain

Pure. No processes, no clock, no randomness, no config, no JSON, no
dependencies. Time and entropy arrive as arguments.

| module | owns |
|---|---|
| `fw_grid` | the time grid, and the UTC instant of any slot or window |
| `fw_availability` | when one attendee is busy, as a **set of slots** |
| `fw_attendee` | an id, an alias, and possibly an answer |
| `fw_heatmap` | free-counts per slot, windows, and their ranking |
| `fw_proposal` | a meeting time: when it is, and how many can be there |
| `fw_room` | the aggregate, and every rule about what may happen |

`fw_availability` is asked questions in slots — "is this person busy at 09:15"
— because that is what the business means. Inside, it holds one bit per slot,
which is invisible to every caller and is what makes a room affordable: as a
set of slot numbers a sixteen-person room was 38 kB, packed it is under 4 kB,
and multiplied by every live room that is the difference between hundreds and
thousands. The readable thing is the API; the compact thing is the storage.
`fw_room_tests` asserts the budget so it cannot silently regress.

`fw_room` is the only module that decides anything.

### `fw_runtime` — rooms as processes

| directory | module | owns |
|---|---|---|
| `ports/` | `fw_room_store` | resolving a hash to a process |
| | `fw_room_snapshots` | what survives a restart |
| `rooms/` | `fw_room_server` | one room's process: commands in, watchers notified |
| | `fw_room_sup` | rooms, `simple_one_for_one` and `temporary` |
| | `fw_directory` | the store adapter: ETS, cleaned up by monitors |
| | `fw_snapshots_none` | the default: nothing is written down |
| | `fw_snapshots_dets` | one stdlib DETS file, switched on by config |
| | `fw_rooms` | creating, resuming, restoring and finding |
| `support/` | `fw_ids` | entropy, and the hash-from-token derivation |
| | `fw_clock` | where "now" enters the system |
| | `fw_bucket`, `fw_limiter` | a pure token bucket and its ETS home |
| | `fw_settings` | configuration, read once at boot |

`fw_runtime_sup` is `rest_for_one` with the directory first. A directory that
restarts has forgotten every hash, so the rooms below it are addressable by
nobody; restarting them too is the honest outcome.

Two ports, and each has two implementations or an obvious second one.
`fw_room_snapshots` earns it outright: `none` and `dets` both ship, and the
test suite runs on `none` so nothing in CI touches a disk. Everything else the
domain needs dissolved into a value passed inward, and a behaviour with one
implementation and no prospect of a second is ceremony.

### `fw_web` — the edge

| directory | module | owns |
|---|---|---|
| `http/` | `fw_rooms_handler` | `POST /api/rooms`, create and resume |
| | `fw_health_handler` | `GET /healthz` |
| | `fw_origin`, `fw_peer` | origin policy, rate-limit key |
| `ws/` | `fw_ws_handler` | one connection, one room |
| `json/` | `fw_room_json` | the protocol, in one module |
| | `fw_busy_codec` | packed bits ↔ slot numbers |
| | `fw_json` | the codec, and decode failures as values |

## The protocol

Documented in `fw_room_json`. Four messages each way, no correlation ids, and
every change sends the whole room already computed
([ADR 0003](adr/0003-a-plain-json-protocol-over-one-websocket.md)).

A successful command sends no reply of its own; the `state` message that
follows is the confirmation, and every watcher gets it including the sender.

## What a room costs

Measured, not estimated, for a full week at quarter-hour resolution:

| room | in memory | snapshot |
|---|---|---|
| 8 attendees, all answered | 3.0 kB | 2.0 kB |
| 64 attendees, all answered | 22.7 kB | 14.3 kB |

At the configured ceiling of 5,000 rooms that is 15–110 MB of RAM and 10–70 MB
of file. Memory is the binding constraint, not the file, and the ceiling itself
binds before the hardware does on the smallest machine Fly sells.

Snapshot writes are debounced to one every two seconds per room, so a drag
across the grid costs one write rather than one per cell, and no disk write
sits in the path of a client's request. A hard kill can lose up to that; a
graceful stop flushes and loses nothing.

## Surviving a release

Two layers, and the first does the work.

**Snapshots.** A room writes itself to a DETS file when it is created and after
every change, and `fw_rooms:restore/0` reads them back at boot before the
listener starts. Rooms whose deadline passed while the node was down are
dropped. A room is forgotten only when it terminates `normal` — expired or
settled — so a shutdown or a crash keeps it, which is the whole point. Off by
default; `FW_SNAPSHOT_FILE` turns it on.
[ADR 0011](adr/0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md) covers
why DETS rather than Mnesia, and why a CRDT does not fit.

**Resume.** A room's hash is the SHA-256 of its host token, so presenting the
token proves the right to that address. A host's browser can reopen a room the
server has completely forgotten — the layer beneath snapshots, for a store that
was off, empty or lost with its volume
([ADR 0008](adr/0008-rooms-are-resumed-from-the-host-token.md)).

## The client

`web/`, TypeScript with Lit templates, bundled by esbuild to one file of 10 kB
gzipped ([ADR 0007](adr/0007-the-client-renders-with-lit-templates.md)).

| module | owns |
|---|---|
| `view.ts` | every screen, as pure functions from state to a template |
| `grid.ts` | the week's template, and delegated drag-painting |
| `time.ts` | formatting instants, in any timezone |
| `mask.ts` | the bit array, its presets, and base64url |
| `memory.ts` | what this browser holds so a room can come back |
| `invite.ts` | the `.ics` for the chosen slot |
| `socket.ts` | the connection, and reconnecting forever |
| `protocol.ts` | the wire, as types |
| `main.ts` | state, actions, recovery, and one `render()` call |

## What is deliberately missing

No database, no cache, no schema — one file, read once at boot
([0011](adr/0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md)).
No accounts, sessions or password resets ([0005](adr/0005-secrets-are-capabilities-not-accounts.md)).
No calendar integration, by API or by file ([0006](adr/0006-availability-is-entered-by-hand.md)).
No timezone, anywhere on the server ([0010](adr/0010-the-server-holds-no-timezone.md)).
