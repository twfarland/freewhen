-module(fw_room_sup).
-moduledoc """
Rooms, one process each.

Every room is `temporary`, and that is a decision rather than a default. A room
holds its entire state in memory; if it crashes, that state is gone. Restarting
it would produce an empty room answering to the same URL, so everyone who had
already submitted a mask would silently be dropped from a meeting they believe
they are in. Failing loudly — the URL stops working — is the better outcome,
and the connections watching it are told.

`intensity => 0` for the same reason: a room dying is a normal, expected event
here, and it must never be counted as supervisor churn that takes the runtime
down with it.
""".

-behaviour(supervisor).

-export([start_link/0, start_room/1, init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_room(fw_room_server:args()) -> supervisor:startchild_ret().
start_room(Args) -> supervisor:start_child(?MODULE, [Args]).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 0, period => 1},
    Room = #{
        id => fw_room_server,
        start => {fw_room_server, start_link, []},
        restart => temporary,
        shutdown => 5_000,
        type => worker
    },
    {ok, {Flags, [Room]}}.
