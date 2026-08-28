-module(fw_room_snapshots).
-moduledoc """
Where a room is written down so that a restart does not lose it.

The second port, and the reason the first one was worth declaring: this is the
whole of the answer to "what survives a deploy", and swapping it changes
nothing above.

Two adapters ship. `fw_snapshots_none` writes nothing and is the default, so
development and the test suite never touch a disk. `fw_snapshots_dets` keeps a
single stdlib DETS file — no database, no server, no schema — and is switched
on by pointing `FW_SNAPSHOT_FILE` at a durable path.

A snapshot is a room's whole state, which means aliases and availability at
rest. That is a real departure from holding everything in RAM and it is why the
adapter is opt-in rather than assumed; see `docs/adr/0011`.
""".

-doc """
Record a room's current state under its hash.

Called after every change, so it must be cheap and must not block the room. It
is allowed to lose the most recent writes on a hard kill — the room's own TTL
bounds how wrong a stale snapshot can be.
""".
-callback save(fw_room_store:hash(), fw_room:t()) -> ok.

-doc "Drop a room that has ended. Must succeed for a hash that was never saved.".
-callback forget(fw_room_store:hash()) -> ok.

-doc """
Everything worth restoring, read once at boot.

Entries that cannot be read back — written by an older release whose room
shape differed — must be skipped rather than crashing the boot.
""".
-callback all() -> [{fw_room_store:hash(), fw_room:t()}].
