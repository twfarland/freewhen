-module(fw_room_snapshots).
-moduledoc """
Where a room is written down so that a restart does not lose it.

Two adapters ship. `fw_snapshots_none` writes nothing and is the default, so
development and the test suite never touch a disk. `fw_snapshots_dets` keeps
one stdlib DETS file and is switched on by pointing `FW_SNAPSHOT_FILE` at a
durable path.

A snapshot is a room's whole state — aliases and availability at rest. That is
a departure from holding everything in RAM, and why it is opt-in.
""".

-doc """
Record a room's current state under its hash.

Called after every change, so it must be cheap and must not block the room. It
is allowed to lose the most recent writes on a hard kill — the room's own life
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
