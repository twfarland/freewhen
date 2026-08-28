# 0011. A local DETS snapshot, so a restart keeps the rooms

- Status: Accepted
- Date: 2026-08-29
- Supersedes: [0001](0001-no-database-rooms-live-in-ram.md)

## Context

[0001](0001-no-database-rooms-live-in-ram.md) said no database, no cache and no
disk, and accepted that a deploy destroys every room.
[0008](0008-rooms-are-resumed-from-the-host-token.md) softened that by letting a
host's browser reopen a room at the same address. Both were the right calls at
the time and neither is enough: resume only works while the host's tab is open,
and "your meeting vanished because we shipped" is not a thing a scheduling tool
gets to say.

The options were weighed as follows.

**ETS** does not help. It survives a process crash but not a VM restart, and
the loss we care about is the machine being replaced.

**CRDTs, or Yjs** are the most interesting suggestion and they do not fit, for
a reason worth writing down. A CRDT makes the room a replicated value that
every participant holds, so the server becomes a relay and losing it costs
nothing. But *every participant holding the room* means every participant
holding everyone's raw availability — and the entire product is that the server
publishes counts and never who. Restrict the CRDT so that each attendee holds
only their own entry, and it is a map with one writer per key: no concurrent
writes, no conflicts, nothing for a CRDT to resolve. It collapses into exactly
the resubmit-on-reconnect that 0008 already does. Yjs would additionally be a
large dependency built for collaborative text.

**Mnesia** would work. It is OTP, it does `disc_copies`, and it offers
replication if this ever became multi-node. It also brings a schema, a create-
or-load dance at boot, transactions this application has no use for, and a set
of failure modes — table load order, split brain — that are entirely wasted on
one node with one table of one key.

**DETS** is Mnesia with everything removed that we do not need: one file, one
key, one value, part of stdlib, no server, no schema, no dependency.

## Decision

A second port, `fw_room_snapshots`, with two adapters.

`fw_snapshots_none` writes nothing and is the default, so development and the
whole test suite never touch a disk. `fw_snapshots_dets` keeps one DETS file
and is switched on by pointing `FW_SNAPSHOT_FILE` at a durable path — on Fly, a
volume.

A room writes itself down when it is created and after every change, and the
snapshot is deleted when the room ends. `fw_rooms:restore/0` runs at boot,
before the web layer starts, and revives everything still in the file; rooms
whose deadline passed while the node was down are dropped rather than revived.

Two rules make it safe:

- A room is forgotten only when it terminates with reason `normal`, meaning it
  expired or its settled grace ran out. A shutdown or a crash keeps the
  snapshot, because those are the cases it exists for. Forgetting on every
  reason would erase every room during exactly the event we are protecting
  against.
- A write that fails is logged and ignored. A full disk costs durability, not
  the meeting.

RAM remains the source of truth. The file is a copy that exists to be read once
at boot and is never queried.

## Consequences

A release stops costing anything. Rooms come back with everyone in them and
their availability intact, whether or not any browser is open, which is what
0008 could not promise.

**Room state now exists at rest, and that is a real reversal.** A snapshot
holds aliases and availability. Anyone who can read the volume can read the
rooms — which was previously impossible rather than merely restricted. The
mitigations are that the adapter is opt-in, the file lives on an encrypted
volume, entries are deleted the moment a room ends, and nothing in the file
outlives its TTL. The README says this plainly instead of continuing to claim
there is nowhere for data to go.

Durability is bounded by the volume. A Fly volume survives deploys and machine
restarts in its region; it does not survive the loss of its host, and it does
not follow the app to another region. For rooms that live a day, that is a
reasonable ceiling, and 0008's resume remains as the layer beneath it: if the
volume is empty or gone, a host can still reopen the room from their token.

The room process now knows its own hash, which it previously did not. That was
a small privacy nicety — a process dump revealed no addresses — and it is spent
here, because a snapshot has to be filed under something.

`fw_room` now owns its own serialisation (`to_binary/1`, `from_binary/1`) with
a version tag, because the module that owns the shape is the one that can say
whether a stored copy is still readable. A release that changes the shape must
bump `?SNAPSHOT`; snapshots that do not match are discarded at boot rather than
misread, and a test covers that path.

## Alternatives considered

Covered in Context: ETS (wrong scope), CRDTs and Yjs (incompatible with
counts-only publishing, and degenerate where they would fit), Mnesia (correct
but larger than the problem).

**Keeping 0008 alone.** Zero infrastructure and the strongest privacy position.
Rejected because it is best-effort in a way users cannot predict: whether your
room survives depends on whether someone else left a tab open.

**An external object store.** Survives host loss and region moves. Rejected as
an operational dependency and a network round trip on every room change, for a
system whose case for existing is that it is one node with nothing attached.
