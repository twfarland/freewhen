-module(fw_runtime_sup).
-moduledoc """
The runtime's root.

`rest_for_one`, and the child order is the reason. A room is reachable only
through the directory, so a directory that has restarted has forgotten every
hash it knew and the rooms below it are addressable by nobody — memory held for
nothing. Restarting them along with it is the honest outcome, and it is safe
precisely because rooms are ephemeral: there was never anything to preserve.

The limiter comes last because nothing depends on it, so its own restart
disturbs nothing.
""".

-behaviour(supervisor).

-export([start_link/1, init/1]).

-spec start_link(fw_settings:t()) -> supervisor:startlink_ret().
start_link(Settings) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Settings).

-spec init(fw_settings:t()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Settings) ->
    Flags = #{strategy => rest_for_one, intensity => 5, period => 10},
    Children = [snapshots(Settings), worker(fw_directory), rooms(), worker(fw_limiter)],
    {ok, {Flags, Children}}.

%%% ---- internal ----

worker(Module) ->
    #{
        id => Module,
        start => {Module, start_link, []},
        restart => permanent,
        shutdown => 5_000,
        type => worker
    }.

%% First, so that nothing which reads snapshots can start before the file is
%% open, and last to stop, so a graceful shutdown flushes it.
snapshots(#{snapshots := Module} = Settings) ->
    #{
        id => fw_room_snapshots,
        start => {Module, start_link, [Settings]},
        restart => permanent,
        shutdown => 10_000,
        type => worker
    }.

rooms() ->
    #{
        id => fw_room_sup,
        start => {fw_room_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    }.
