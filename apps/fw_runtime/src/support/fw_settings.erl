-module(fw_settings).
-moduledoc """
The application's configuration, read once at startup and never again.

`load/0` runs in `fw_runtime_app:start/2` and stores the result in
`persistent_term`; `get/0` is a lock-free read. Every other module in the
system takes what it needs as an argument, so that no function's behaviour
depends on ambient state a test cannot see.
""".

-export([load/0, get/0]).
-export_type([t/0]).

-type t() :: #{
    room_ttl_ms := pos_integer(),
    finalize_grace_ms := pos_integer(),
    max_rooms := pos_integer(),
    max_attendees_per_room := pos_integer(),
    create_bucket := fw_bucket:config(),
    room_store := module(),
    snapshots := module(),
    snapshot_file := string()
}.

-define(KEY, {?MODULE, settings}).

-spec load() -> t().
load() ->
    Settings = #{
        room_ttl_ms => env(room_ttl_ms, 86_400_000),
        finalize_grace_ms => env(finalize_grace_ms, 300_000),
        max_rooms => env(max_rooms, 5_000),
        max_attendees_per_room => env(max_attendees_per_room, 64),
        create_bucket => env(create_bucket, #{capacity => 10, refill_per_sec => 1, cost => 10}),
        room_store => env(room_store, fw_directory),
        snapshots => snapshots(),
        snapshot_file => snapshot_file()
    },
    ok = persistent_term:put(?KEY, Settings),
    Settings.

-spec get() -> t().
get() -> persistent_term:get(?KEY).

%%% ---- internal ----

%% Pointing FW_SNAPSHOT_FILE at a durable path is the whole of turning
%% durability on. Unset, rooms are never written down and a restart loses them.
snapshots() ->
    case env(snapshots, undefined) of
        undefined -> default_snapshots(os:getenv("FW_SNAPSHOT_FILE"));
        Module -> Module
    end.

default_snapshots(false) -> fw_snapshots_none;
default_snapshots("") -> fw_snapshots_none;
default_snapshots(_Path) -> fw_snapshots_dets.

snapshot_file() ->
    case os:getenv("FW_SNAPSHOT_FILE") of
        false -> env(snapshot_file, "/data/freewhen.dets");
        "" -> env(snapshot_file, "/data/freewhen.dets");
        Path -> Path
    end.

env(Key, Default) -> application:get_env(fw_runtime, Key, Default).
