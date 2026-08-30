# Operations

One BEAM node, one runtime dependency, one file. No database to back up, no
migration to run, no schema — which is why most of what usually goes in this
document does not exist.

Running it on a laptop is [DEVELOPING.md](DEVELOPING.md); this is the deployed
machine. Why it is shaped this way is [ARCHITECTURE.md](ARCHITECTURE.md).

## The machine, once

A **Hetzner CX22** (2 vCPU, 4 GB) running **Ubuntu 24.04**, your SSH key, and
an `A` record. The measured worst case is about 1.15 GB of room state at the
configured caps, so 4 GB is the smallest size that fits it with the OS and
Caddy; anything smaller means lowering `max_rooms` to match.

```sh
cp deploy/inventory.example.ini deploy/inventory.ini   # gitignored
$EDITOR deploy/inventory.ini                           # host and domain
ansible-galaxy collection install -r deploy/requirements.yml
ansible-playbook -i deploy/inventory.ini deploy/site.yml
ansible-playbook -i deploy/inventory.ini deploy/reboot.yml   # prove it comes back
```

## Deploying

```sh
cd web && npm ci && npm run build && cd ..
rebar3 as prod tar
ansible-playbook -i deploy/inventory.ini deploy/site.yml
```

**Build on Ubuntu 24.04.** The release bundles ERTS, so it is linked against
the glibc of whatever built it, and on any other platform `rebar3 as prod tar`
does not even produce a POSIX start script. CI pins `ubuntu-24.04` and the
playbook asserts the target's distribution before shipping anything.

The playbook is idempotent and restarts the node only when the release actually
changed, so re-running it to fix a firewall rule does not drop every open
websocket.

| playbook | |
|---|---|
| `site.yml` | provision and deploy. Safe to re-run |
| `site.yml --tags deploy` | ship the code and restart, skipping the machine |
| `site.yml --tags reload` | ship the code and swap it in **without** restarting |
| `site.yml --tags provision` | the machine only, no code |
| `status.yml` | read-only: services, health, disk, snapshot, node memory |
| `reboot.yml` | the recovery drill — reboot and refuse to finish until the site answers |

### From CI

`.github/workflows/deploy.yml` does all of it on `workflow_dispatch` or a `v*`
tag, on `ubuntu-24.04` so the glibc matches by construction. It runs the full
check suite first, refuses a tag that disagrees with the version in
`rebar.config`, smoke-tests the public URL afterwards, and attaches the tarball
to a GitHub Release. Four secrets: `DEPLOY_HOST`, `DEPLOY_DOMAIN`,
`SSH_PRIVATE_KEY`, and `SSH_KNOWN_HOSTS` (from `ssh-keyscan`, pinned rather
than scanned at deploy time).

This is also the answer on Windows: Ansible has no native Windows control node,
and Windows cannot build a deployable release anyway.

### Reloading without a restart

`--tags reload` unpacks the release and `code:atomic_load/1`s exactly the
modules that changed, on the running node. No socket drops, no rooms
interrupted.

**For changed function bodies only.** It does not migrate `gen_server` state,
restructure supervision or change application environment. Change the shape of
`fw_room_server`'s record and the new code meets the old state, which crashes
that room — one room, because rooms are `temporary`, but a real one.
`--tags deploy` is the honest answer to anything structural, and a restart
costs about two seconds of reconnection and no rooms.

It refuses rather than damages: `soft_purge` fails if a process is still
running the previous version, so a second reload before the first has drained
stops with an error instead of killing rooms.

## Coming back by itself

Nothing needs a human after a reboot, which matters because
`unattended-upgrades` reboots at 04:00 UTC for a kernel with nobody watching.

| | |
|---|---|
| the node | `freewhen.service`, enabled, `Restart=always` with `StartLimitIntervalSec=0` so it never gives up |
| the proxy | `caddy.service`, enabled, certificate already on disk |
| the firewall | `ufw`, enabled — 22, 80, 443 in, nothing else |
| the rooms | restored from the snapshot before the listener opens |

`StartLimitIntervalSec=0` is the setting to be careful with in the other
direction: without it, systemd gives up after five restarts in ten seconds and
leaves the unit `failed`, which is exactly the state that needs somebody to
notice. `reboot.yml` tests the claim rather than believing it.

**Do not run two nodes.** The DETS file has no cross-node locking, and a room
is a process: two machines means one has never heard of a hash, or both load it
and split-brain. Nothing stops the node for you — no autoscaler, no idle
shutdown — but `systemctl stop freewhen` takes every room with it and only the
snapshot brings them back.

## Environment

Four variables, read once at boot, all set by the systemd unit.

| variable | effect |
|---|---|
| `PORT` | listen port; defaults to `sys.config` (8080) |
| `FW_BIND` | interface to bind; `127.0.0.1` in production, unset in development |
| `FW_ALLOWED_ORIGINS` | comma-separated origins allowed to open a websocket |
| `FW_SNAPSHOT_FILE` | where rooms are written so a restart does not lose them |

**`FW_SNAPSHOT_FILE` is what turns durability on.** Unset, rooms are never
written down and a restart destroys every one — including that 04:00 reboot.
Set, it is `/var/lib/freewhen/rooms.dets`, mode 0700, the only file this
application writes, and it holds aliases and availability at rest.

**`FW_BIND=127.0.0.1` is load-bearing, not tidiness.** Caddy on the same host
is then the only thing that can reach the node, which is the only reason
`fw_peer` may believe `x-forwarded-for`. Open the node to the world and the
rate limiter can be defeated by a header.

**Set `FW_ALLOWED_ORIGINS` before going public.** The playbook sets it from the
inventory's `domain`. Unset, every origin is accepted — a development default,
not a policy. An origin is not an identity; it buys you that another website
cannot open a socket using a visitor's browser.

Everything else is in `config/sys.config` and ships inside the release: the
idle window (`room_idle_ms`, 30 days), how long a room outlives the meeting it
scheduled (`finalize_grace_ms`, 24 hours **after the meeting ends**, not after
the decision), the caps, and the rate limit.

## How much it holds

Measured at the ceiling with `bench/load.escript`:

| 20,000 rooms | per room | total RAM | snapshot | restore at boot |
|---|---|---|---|---|
| 8 attendees, ordinary week | 12.4 kB | 242 MB | 37 MB | 2.7s |
| 16 attendees, maximally fragmented | 58.8 kB | ~1.15 GB | ~205 MB | ~12s |

`MemoryMax=2G` in the systemd unit is sized against the second row. DETS stops
at 2 GB, which even that does not reach. **Restore is dead time**: the listener
does not open until it finishes, so a full room table costs a few seconds on
every deploy and every 04:00 reboot, and up to a dozen against crafted input.

Re-run the bench before raising either cap — the number to check is memory, not
disk, and it is measured rather than multiplied for a reason.

The ceiling holds a **month** of rooms, not a day, because a room lives on
idleness. 20,000 is roughly 660 new rooms a day sustained; past that, creation
is refused rather than anything being evicted.

The file does not shrink when rooms are deleted; DETS reuses the space, so
expect it to sit near its high-water mark.

## Watching it

`GET /healthz` returns status, room count and uptime. That is everything the
server will report: per-room metrics would be a directory of which rooms exist
and how busy they are, which is precisely what the design promises not to keep.

```sh
ansible-playbook -i deploy/inventory.ini deploy/status.yml   # changes nothing
ssh root@<host>
sudo -u freewhen /opt/freewhen/current/bin/freewhen remote_console
journalctl -u freewhen -f
```

**observer** is a GUI, so it runs on your machine over an SSH tunnel. The node
is named `freewhen@127.0.0.1` with its distribution port pinned to 9100 exactly
so this works — a tunnel cannot forward a random port, and an address needs no
name resolution.

```sh
ssh -N -L 4369:127.0.0.1:4369 -L 9100:127.0.0.1:9100 root@<host>
# elsewhere; any local epmd would shadow the tunnel
epmd -kill
erl -name obs@127.0.0.1 -setcookie freewhen_local -hidden -run observer
```

Then **Nodes → Connect Node → `freewhen@127.0.0.1`**. The cookie in
`config/vm.args` is not a secret: distribution is bound to loopback and `ufw`
opens neither 4369 nor 9100, so the tunnel is the only way in. `runtime_tools`
is in the release because observer loads `observer_backend` onto the node it
watches.

Logs contain no room hash, alias, availability or host token. If you find
yourself wanting a log line to debug a specific room, that is the design
working — there is no way to identify one. Crash dumps are disabled in
`config/vm.args` for the same reason.

## What failure looks like

**A room crashes.** Not restarted (`temporary`), its directory entry removed by
the monitor, connected clients get `closed` with reason `failed`, and the link
stops working. Other rooms are unaffected — that isolation is why the code is
free to crash rather than defend.

**The node restarts, deploys, or reboots for a kernel.** Every room process
dies and every room comes back: `fw_rooms:restore/0` reads the snapshot before
the listener starts, so look for `freewhen restored N rooms` in the boot log.
Clients reconnect within a few seconds. Rooms whose deadline passed while the
node was down are dropped rather than revived. If snapshots were off, or the
disk went with the machine, a host's browser reopens the room from its token
and everyone resubmits — which only works while that tab is open.

**The snapshot will not write.** Logged as a warning; rooms carry on in memory
and durability is lost until it is fixed. A full disk must not take a meeting
down with it, so nothing crashes. Check `df` on `/var/lib` before the next
restart, because that is when it will cost something.

**Writes feel slow.** Each room writes at most once every two seconds and only
when something changed. The interval is `?SNAPSHOT_EVERY_MS` in
`fw_room_server`, and raising it only widens the window a hard kill can lose.

**A reload is refused.** A process is still running the previous version of a
module — usually a second `--tags reload` before the first drained. Nothing
changed; deploy properly and take the restart.

**Memory climbs.** The ceilings are `max_rooms`, `max_attendees_per_room` and
the bounded grid (2016 slots). Check `/healthz` for the room count before
assuming a leak. The limiter sweeps its own buckets every minute so rotating
addresses cannot turn it into the leak it exists to prevent.

**Someone floods `POST /api/rooms`.** 429s from the token bucket, then 503s
once `max_rooms` is reached. Existing rooms are never evicted to admit a new
one: refusing is correct, sacrificing someone's meeting is not.

## Deliberately absent

**No backups.** The file holds meetings still being arranged — up to a month of
them now, which is a longer exposure than it used to be. Losing it costs those
meetings, and hosts can reopen a room from the token their browser holds.

**No monitoring stack.** Point any external pinger at `/healthz`.

**No rollback mechanism.** Download the previous tarball from its GitHub
Release into `_build/prod/rel/freewhen/` and run `--tags deploy`. No state on
disk cares which version wrote it.
