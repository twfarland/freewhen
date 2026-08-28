-module(fw_room_store).
-moduledoc """
Where a room hash is resolved to the process holding that room.

The one port in this system, and it earns its place: everything about how rooms
survive — or do not survive — a restart happens behind these three callbacks.
The adapter today is `fw_directory`, an ETS table cleaned up by monitors. A
future adapter that hands rooms to a replacement node, or restores them from a
snapshot, changes this and nothing above it.

Ports are not free, and there is exactly one here on purpose. Every other
dependency the domain has dissolved into a value passed inward — `fw_room`
takes `Now` rather than owning a clock — and a behaviour with one
implementation and no prospect of a second is ceremony, not architecture.

The implementation is chosen in `fw_settings`, so a test can supply its own.
""".

-export_type([hash/0]).

-type hash() :: binary().

-doc """
Claim a hash for a process.

Must fail rather than overwrite: a hash that is already taken belongs to a
live room, and reassigning it would hand one room's participants to another.
""".
-callback insert(hash(), pid()) -> ok | {error, collision}.

-doc "Resolve a hash. Must not block, and must not create anything.".
-callback find(hash()) -> {ok, pid()} | error.

-doc "How many rooms exist, for the creation cap and the health endpoint.".
-callback count() -> non_neg_integer().
