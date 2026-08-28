-module(fw_snapshots_none).
-moduledoc """
The default: rooms are not written down, and a restart loses them.

This is what development and the test suite run, so neither ever touches a
disk, and it is what a deployment runs until someone deliberately points
`FW_SNAPSHOT_FILE` at a durable path.
""".

-behaviour(fw_room_snapshots).

-export([start_link/1, save/2, forget/1, all/0]).

-doc "Nothing to own, so nothing to supervise.".
-spec start_link(map()) -> ignore.
start_link(_Settings) -> ignore.

-spec save(fw_room_store:hash(), fw_room:t()) -> ok.
save(_Hash, _Room) -> ok.

-spec forget(fw_room_store:hash()) -> ok.
forget(_Hash) -> ok.

-spec all() -> [].
all() -> [].
