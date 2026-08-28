# Plan

## Where this is

A working product. Create a room, share the link, join under an alias, set your
availability from a preset and drag to adjust, see the heatmap update live for
everyone, and have whoever started the room pick a time and export an
invitation. Rooms delete themselves, and a release no longer costs them.

```
rebar3 do compile, eunit, ct, xref, dialyzer    94 unit + 26 integration, clean
cd web && npm run check && npm run build        strict tsc, 10 kB gzipped
```

## Done

**Domain** (`fw_core/src/domain/`, 6 modules, ~380 lines, 71 unit tests). Grid,
availability, attendee, heatmap, proposal, room aggregate. Pure — every rule is
a function of its arguments, so the suite runs in two seconds with no setup.

Availability is a **set of busy slots**, not a bitmap. The bitmap survives on
the wire, where it is worth 84 bytes against 2.5 kB, and is translated at the
edge by `fw_busy_codec`.

**Runtime** (`fw_runtime`, 13 modules across `ports/`, `rooms/`, `support/`).
A room per process, `temporary` under `simple_one_for_one`. Two ports:
`fw_room_store` (ETS directory, cleaned up by monitors) and
`fw_room_snapshots` (`none` or `dets`). TTL and finalise-grace timers driven
from the domain's own `expires_at`. Token-bucket rate limiting with a sweep.

**Edge** (`fw_web`, 11 modules across `http/`, `ws/`, `json/`). Create, resume,
health, the websocket, the static client. The protocol lives in one module.

**Durability** ([ADR 0011](adr/0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md)).
Rooms are snapshotted to one DETS file and restored at boot, so a deploy keeps
them with everyone in them. Off by default — `FW_SNAPSHOT_FILE` turns it on —
so development and CI never touch a disk. Five integration tests, including
restarting the application, an expired snapshot, and an unreadable one.

**Resume** ([ADR 0008](adr/0008-rooms-are-resumed-from-the-host-token.md)).
A room's hash is the SHA-256 of its host token, so a host's browser can reopen
a room from nothing. The layer beneath snapshots, for a store that was off or
lost.

**Server decides, browser formats.** Proposals carry UTC start and end
instants; the client does no scheduling arithmetic. The server holds no
timezone at all ([ADR 0010](adr/0010-the-server-holds-no-timezone.md)).

**Client** (`web/`, 9 modules, ~735 lines, Lit templates). Presets and
drag-painting, live heatmap in local time, `.ics` export, reconnect and
recovery.

**Guardrails.** `CLAUDE.md`, four skills, and a hook that rejects an edit
breaking the layer rules or the 200-line/30-line size limits. Eleven ADRs, two
of them superseding earlier ones. CI runs the client typecheck and build, then
compile, eunit, ct, xref and dialyzer.

## Next, in order

1. **Client tests.** Still none, and there are three pure modules that deserve
   them: `mask.ts` (bit packing, base64url round trip, the weekday preset
   across a clock change), `time.ts`, and `memory.ts`. Needs a test runner,
   which is a dependency and therefore an ADR; `node --test` over esbuild
   output would avoid adding one.

2. **A seat id.** Clients find themselves in the attendee list by matching
   their own alias, so two people picking the same alias make the highlight
   ambiguous. Cosmetic. A second, non-secret id per attendee fixes it.

3. **Tell clients a shutdown is coming.** Recovery begins when the socket
   drops, which costs a few seconds of confusion. A `closed` with a distinct
   reason on graceful shutdown would let clients wait rather than error.

4. **A working-hours preset that is not 9–5.** Hardcoded to Monday–Friday,
   09:00–17:00 local. Letting someone drag the boundaries once and reuse them
   fits anyone whose week is not that, and stays client-side.

## Deliberately not doing

**Any calendar integration.** [ADR 0006](adr/0006-availability-is-entered-by-hand.md)
records why the `.ics` importer was built, measured against painting, and
deleted.

**A real database, or Mnesia.** One key, one value, no queries. DETS is what
that needs; [ADR 0011](adr/0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md)
has the comparison.

**CRDTs or Yjs.** They would make the room a value every participant holds,
which means every participant holding everyone's raw availability — the exact
thing the product refuses to do. Restricted to one writer per key they collapse
into the resubmit-on-reconnect already in place. Reasoning in
[ADR 0011](adr/0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md).

**Storing anything about a person.** No accounts, no email, no timezone.

**Running more than one instance.** A room is a process and the snapshot file
is local, so two instances means split brain and a corrupt file. Scaling out
means sharding by room hash with `fly-replay`, not statelessness;
[ADR 0012](adr/0012-one-instance-and-what-more-would-take.md) records why, and
what it would take. One machine holds thousands of rooms.

**More ports.** Two, both with a real second implementation or an imminent one.

## Known limits

- **One machine is the capacity and the failure domain.** Measured, a room is
  3–23 kB in memory, so the configured 5,000-room ceiling costs 15–110 MB and
  binds long before the hardware does.
- **Durability stops at the volume.** A Fly volume survives deploys and
  restarts, not the loss of its host, and it does not follow the app to another
  region. Resume is the layer beneath it, and that needs the host's tab open.
- **Room state exists at rest** when snapshots are on: aliases and availability
  in one file on an encrypted volume, deleted per room the moment the room
  ends. This is a deliberate reversal of the original no-disk position and the
  README says so.
- Anyone with a room link can join under any alias. Same trust model as a
  shared document link; the attendee cap and the 24-hour life bound it.
- The server shows counts, never who is free when. Right for external parties;
  wrong when "Sarah cannot make Tuesday and Sarah is essential" is the actual
  question.
- Everyone reads the grid in their own timezone, and nobody sees what a slot
  means for anyone else. That was briefly built and removed with the timezone
  field ([ADR 0010](adr/0010-the-server-holds-no-timezone.md)).
