# Operations

The whole system is one BEAM node with one dependency and one file. There is
no database to back up, no migration to run, and no schema — which means most
of what usually goes in this document does not exist.

## Running it

```sh
cd web && npm ci && npm run build   # once, and after any client change
rebar3 shell                        # http://localhost:8080
```

`rebar3 shell` boots `fw_web` and everything under it with `config/sys.config`.

## Deploying

```sh
fly deploy
```

The `Dockerfile` builds the client in a node stage, the release in an erlang
stage, and ships an alpine image containing only the release.

Two environment variables matter, both read once at boot:

| variable | effect |
|---|---|
| `PORT` | listen port; defaults to the value in `sys.config` (8080) |
| `FW_ALLOWED_ORIGINS` | comma-separated origins allowed to open a websocket |
| `FW_SNAPSHOT_FILE` | where rooms are written so a release does not lose them |

**`FW_SNAPSHOT_FILE` is what turns durability on.** Unset, rooms are never
written down and a restart destroys every one of them. Set, it must point at a
path that survives a deploy — a Fly volume, mounted in `fly.toml`. It is the
only file this application writes, and it holds aliases and availability at
rest; [ADR 0011](adr/0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md)
covers what that costs.

**Set `FW_ALLOWED_ORIGINS` before making a deployment public.** Unset, every
origin is accepted — a development default, not a policy. An origin is not an
identity; what it buys is that another website cannot open a socket using a
visitor's browser.

Everything else — TTL, grace period, room and attendee caps, the rate
limit — lives in `config/sys.config` and is baked into the image.

## One machine, on purpose

A room lives in the memory of the process that created it, so `fly.toml` pins
`min_machines_running = 1`, `auto_stop_machines = false`, and one volume.

**Do not run two.** Two things break. The DETS file is local and has no
cross-node locking, so two writers corrupt it — and on Fly a volume attaches to
one machine anyway, so you would get two files each holding half the rooms.
More fundamentally, a room is a process: if two people in the same room land on
different machines, one of them is talking to a machine that has never heard of
that hash, and loading it on both gives two processes that both think they own
it. [ADR 0012](adr/0012-one-instance-and-what-more-would-take.md) has the
reasoning and the scaling path.

`auto_stop_machines = false` is the setting to be careful with: letting Fly
stop an idle machine would take every room in progress with it, and idle is the
normal state of this application. Idle does not mean unused.

## How much it holds

Measured for a full week at quarter-hour resolution:

| room | in memory | snapshot |
|---|---|---|
| 8 attendees, all answered | 3.0 kB | 2.0 kB |
| 64 attendees, all answered | 22.7 kB | 14.3 kB |

At `max_rooms = 5000` that is 15–110 MB of RAM and 10–70 MB of file, so the
configured ceiling binds well before a 512 MB machine does. DETS itself stops
at 2 GB, which this cannot reach.

The file does not shrink when rooms are deleted; DETS reuses the space, so
expect it to sit near its high-water mark for the day. If you raise
`max_rooms`, the number to check is memory, not disk: multiply the ceiling by
23 kB for the worst case.

## Watching it

`GET /healthz` returns status, the current room count and uptime. That is
everything the server will report, and the omission is deliberate: per-room
metrics would be a directory of which rooms exist and how busy they are, which
is precisely what the design promises not to keep.

After a deploy, watch the room count climb back rather than expecting it to
have been preserved — rooms are recreated by their hosts, not restored.

Logs contain no room hash, alias, availability, timezone or host token. If you
find yourself adding a log line that would help debug a specific room, that is
the design working as intended — there is no way to debug a specific room, because there
is no way to identify one.

Crash dumps are disabled in `config/vm.args`. A dump would be the one artefact
that outlives the rooms it contains.

## What failure looks like

**A room crashes.** Its supervisor does not restart it (`temporary`), the
directory entry is removed by the monitor, and connected clients receive
`closed` with reason `failed`. The link stops working. Other rooms are
unaffected — that isolation is why the code is free to crash rather than
defend.

**The node restarts or is deployed.** Every room process dies and every room
comes back. `fw_rooms:restore/0` reads the snapshot file before the listener
starts, so the rooms are already there when the first request arrives — look
for `freewhen restored N rooms` in the boot log. Clients reconnect on their own
within a few seconds. Rooms whose deadline passed while the node was down are
dropped rather than revived.

If snapshots are off, or the file was lost with its volume, the fallback is
[ADR 0008](adr/0008-rooms-are-resumed-from-the-host-token.md): a host's browser
reopens the room at the same address from its token, and everyone resubmits
what their own browser held. That only works while the host's tab is open,
which is why the snapshot exists.

**Writes feel slow, or the volume is busy.** Each room writes at most once
every two seconds, and only when something changed, so a room being actively
painted costs one write per two seconds rather than one per cell. If that is
still too much, the interval is `?SNAPSHOT_EVERY_MS` in `fw_room_server`, and
raising it only widens the window a hard kill can lose.

**The snapshot file will not write.** Logged as a warning; rooms carry on in
memory and durability is lost until it is fixed. A full disk must not take a
meeting down with it, so nothing crashes. Check the volume before the next
deploy, because that is when it will cost something.

**Memory climbs.** The ceilings are `max_rooms`, `max_attendees_per_room` and
the bounded grid (2016 slots maximum). Room creation is rate limited per client
address; the limiter sweeps its own buckets every minute so that rotating
addresses cannot turn it into the leak it exists to prevent. Check
`/healthz` for the room count before assuming a leak — 5000 rooms is the
configured cap and roughly the expected ceiling.

**Someone floods `POST /api/rooms`.** They get 429s from the token bucket, and
503s once `max_rooms` is reached. Existing rooms are never evicted to admit a
new one: refusing is correct, sacrificing someone's meeting is not.
