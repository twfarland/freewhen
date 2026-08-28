# 0001. No database: a room lives in RAM and dies there

- Status: Superseded by
  [0011](0011-a-local-snapshot-so-a-restart-keeps-the-rooms.md). No database
  still holds and RAM is still the source of truth; "no disk" does not.
- Date: 2026-08-28

## Context

FreeWhen exists to be the scheduling tool you can send to someone outside your
company without either of you signing up for anything or leaving a record. That
promise is only worth as much as it can be checked. "We delete your data" is a
policy; "there is nowhere for your data to go" is a property.

A scheduling room is also short-lived by nature. It is created to answer one
question — when can these people meet — and once answered it has no further
use. Nothing about it needs to survive the week, let alone a restart.

The BEAM already provides supervised, isolated, addressable in-memory processes
with timers. A database would be adding durability that the product actively
does not want.

## Decision

There is no database, no cache, and no disk. A room is one `gen_server`'s
state, addressed through an ETS table that maps hash to pid. When the process
ends, for any reason, the room is gone.

Nothing is written down anywhere else either: crash dumps are disabled in
`vm.args`, and no log line may contain a room hash, alias, mask or host token.

## Consequences

The privacy claim becomes checkable rather than promised. There is no export
endpoint to secure, no backup to leak, no retention policy to get wrong, and a
subpoena or a breach yields whatever was in RAM at that instant and nothing
else. This is the entire product.

Operations become unusually simple. There is no migration, no connection pool,
no backup schedule, and no stateful dependency to run alongside the app. The
release is one binary and a health check.

A restart destroys every room in progress. This is not mitigated, because
mitigating it means persistence. It is instead made cheap: rooms are short,
losing one costs a re-share of a link, and the client keeps its own mask
locally so a participant re-submits rather than re-syncing.

The application cannot scale horizontally without routing by hash. One node
holds all the rooms it created, and a second node knows nothing of them. This
is a real ceiling and it is documented in `docs/OPERATIONS.md` rather than
designed around: a single small machine holds thousands of rooms, and the day
that is not enough is a good day to revisit this.

Memory is the resource to bound, so it is bounded explicitly: a cap on rooms, a
cap on attendees per room, a bounded grid, and a rate limit on the one endpoint
that allocates.

## Alternatives considered

**Postgres or SQLite with a TTL sweep.** The ordinary choice, and it survives
restarts. Rejected because durability is the thing being sold against: the
moment rows exist, so does everything that reads them.

**Redis with expiry.** Lighter, still an operational dependency, still a place
where the data sits and can be dumped. It buys restart survival and multi-node
addressing, and costs the property that makes the product make sense.

**Mnesia.** In-memory tables would technically satisfy this, but it is a
distributed database with schema, transactions and split-brain semantics, in
exchange for something a `gen_server` and an ETS table already do.
