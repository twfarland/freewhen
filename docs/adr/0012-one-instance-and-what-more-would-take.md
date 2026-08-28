# 0012. One instance, and what more would take

- Status: Accepted
- Date: 2026-08-29

## Context

FreeWhen is a stateful service. A room is a live process holding its own state
and pushing changes to the websockets watching it. That is unusual if your
instinct is that services are stateless and scale horizontally because all the
state is in a database, so it is worth writing down what running more than one
instance would actually mean here.

Two separate things break, and the smaller one gets noticed first.

**The snapshot file.** DETS is a local file opened by one node. It has no
cross-node locking; two nodes writing the same file interleave and corrupt it.
On Fly the question is moot in a different way — a volume attaches to exactly
one machine, so two machines would have two files, each holding a disjoint,
unsynchronised half of the rooms.

**Routing, which is the real problem.** Suppose the file were a shared database
that solved all of that. A room is a process, and processes do not span
machines. Alice's websocket lands on machine A and Bob's on machine B; the room
lives on A; `fw_directory` on B has never heard of that hash. Load the room
from the shared store on B as well and there are now two processes both
believing they own it, both broadcasting, both writing conflicting snapshots.
Split brain, in a scheduling tool.

Stateless services do not avoid this. They move it into a database that is
itself a stateful service, sharded and failed-over by somebody else. The
question is not whether to have stateful infrastructure, but whether to run it
or rent it.

## Decision

Exactly one instance. `fly.toml` pins `min_machines_running = 1`,
`auto_stop_machines = false`, and one volume.

This is affordable because of what a room actually costs, measured rather than
assumed. With availability packed one bit per slot, a room with eight
attendees who have each answered for a full week is **3 kB in memory and 2 kB
on disk**; sixty-four attendees is 23 kB and 14 kB. At the configured ceiling
of 5,000 rooms that is **15–110 MB of RAM and 10–70 MB of file** — comfortable
on the smallest machine Fly sells, with the ceiling itself, not the hardware,
as the binding constraint. `fw_room_tests` asserts the per-room budget so a
change to the representation cannot quietly multiply it.

Scaling out, when one machine is genuinely not enough, means **sharding with
affinity**, not replication and not statelessness. The room hash is already the
partition key, and it is already in the websocket path (`/ws/rooms/:hash`), so
an edge that does not own a hash can answer with Fly's `fly-replay` header
naming the machine that does. What is missing is the hash-to-machine map, which
is itself state — rendezvous hashing over the machine list would avoid storing
it, at the cost of moving rooms whenever the machine set changes.

## Consequences

Capacity is one machine's memory, and we know what that buys: thousands of
concurrent rooms, against a product whose realistic peak is far below that. The
ceiling arrives long after the point where this would be worth revisiting.

The failure domain is one machine. If it dies, every room is unreachable until
it comes back, and the volume comes back with it. Rooms are hours old and the
resume path in [ADR 0008](0008-rooms-are-resumed-from-the-host-token.md) covers
the case where the volume does not.

We own the sharding we have not written. A database would have given us
horizontal scaling for free, and the price of not having one is that the day we
need two machines is a real piece of work rather than a config change. That
trade is right while one machine is this far from full, and it is recorded here
so that the decision is re-made deliberately rather than discovered.

Deploys are a stop and a start, never an overlap, so nothing depends on two
instances briefly coexisting. That is also why snapshots exist
([ADR 0011](0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md)).

## Alternatives considered

**Stateless instances with all room state in Postgres or Redis.** The familiar
shape, and it scales horizontally without thought. It costs the reason to be on
the BEAM at all: a room would be read and written on every message instead of
being a process that holds it, and pushing a change to a websocket on another
machine would need a pub/sub layer on top — so the "simpler" architecture ends
up with a database, a broker, and a cache-coherency problem this design does
not have. It also puts every room's availability in a system that outlives it,
which is what the product refuses to do.

**Replication with a leader (Raft, or Mnesia across nodes).** Correct, and
consensus machinery for a value that lives four hours and is owned by whoever
holds a link. Enormously more failure modes than the failure it prevents.

**Two machines with sticky sessions by cookie.** Stickiness at the connection
level does not help: two people in the *same room* must reach the same machine,
and they are different connections. The affinity has to be on the room hash,
which is the sharding answer above.
