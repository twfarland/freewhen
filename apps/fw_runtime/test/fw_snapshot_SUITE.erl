-module(fw_snapshot_SUITE).
-moduledoc """
Durability, tested the only way that means anything: stop the application,
start it again, and see whether the rooms are there.

The DETS file goes in the suite's private directory, so nothing here touches a
path anyone else uses.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(STALE, <<"AAAAAAAAAAAAAAAAAAAAAA">>).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    a_room_survives_a_restart_with_everyone_in_it/1,
    a_room_that_expired_while_down_is_not_revived/1,
    a_room_that_ended_on_purpose_is_forgotten/1,
    an_unreadable_snapshot_is_discarded_not_fatal/1,
    without_a_snapshot_store_a_restart_loses_everything/1
]).

all() ->
    [
        a_room_survives_a_restart_with_everyone_in_it,
        a_room_that_expired_while_down_is_not_revived,
        a_room_that_ended_on_purpose_is_forgotten,
        an_unreadable_snapshot_is_discarded_not_fatal,
        without_a_snapshot_store_a_restart_loses_everything
    ].

init_per_testcase(Case, Config) ->
    File = filename:join(?config(priv_dir, Config), atom_to_list(Case) ++ ".dets"),
    ok = boot(#{snapshots => adapter(Case), snapshot_file => File}),
    [{snapshot_file, File} | Config].

end_per_testcase(_Case, _Config) ->
    ok = application:stop(fw_runtime).

adapter(without_a_snapshot_store_a_restart_loses_everything) -> fw_snapshots_none;
adapter(_Case) -> fw_snapshots_dets.

%%% ---- tests ----

%% What a deploy does, and what has to survive it.
a_room_survives_a_restart_with_everyone_in_it(Config) ->
    {Hash, _Token} = room(),
    {ok, Pid} = fw_rooms:find(Hash),
    {ok, {joined, Id}} = fw_room_server:command(Pid, {join, <<"Blue Falcon">>}),
    {ok, ok} = fw_room_server:command(Pid, {submit, Id, [1, 2]}),

    ok = restart(Config),

    {ok, Restored} = fw_rooms:find(Hash),
    {ok, Room} = fw_room_server:watch(Restored, self()),
    ?assertEqual([<<"Blue Falcon">>], [fw_attendee:alias(A) || A <- fw_room:attendees(Room)]),
    ?assertEqual([1, 0, 0, 1, 1, 1, 1, 1], fw_room:heatmap(Room)).

%% Expiry is a promise about wall-clock time, not about uptime. Written
%% directly with a deadline already in the past, so nothing here waits.
a_room_that_expired_while_down_is_not_revived(Config) ->
    {Hash, _Token} = room(),
    File = ?config(snapshot_file, Config),
    ok = application:stop(fw_runtime),
    ok = write_snapshot(File, ?STALE, long_expired()),

    ok = boot(#{snapshots => fw_snapshots_dets, snapshot_file => File}),

    ?assertMatch({ok, _Pid}, fw_rooms:find(Hash)),
    ?assertEqual(error, fw_rooms:find(?STALE)).

a_room_that_ended_on_purpose_is_forgotten(Config) ->
    {Hash, _Token} = room(),
    {ok, Pid} = fw_rooms:find(Hash),
    Monitor = erlang:monitor(process, Pid),
    Pid ! expired,
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 5_000 -> error(room_would_not_stop)
    end,

    ok = restart(Config),

    ?assertEqual(error, fw_rooms:find(Hash)).

%% A release that changes the room's shape must not take the boot down with it.
an_unreadable_snapshot_is_discarded_not_fatal(Config) ->
    {Hash, _Token} = room(),
    File = ?config(snapshot_file, Config),
    ok = application:stop(fw_runtime),

    ok = write_snapshot(File, ?STALE, <<"not a room at all">>),

    ok = boot(#{snapshots => fw_snapshots_dets, snapshot_file => File}),
    ?assertMatch({ok, _Pid}, fw_rooms:find(Hash)),
    ?assertEqual(error, fw_rooms:find(?STALE)).

%% The default, and what development and the rest of the suite run on.
without_a_snapshot_store_a_restart_loses_everything(Config) ->
    {Hash, _Token} = room(),
    ok = restart(Config),
    ?assertEqual(error, fw_rooms:find(Hash)).

%%% ---- helpers ----

boot(Overrides) ->
    ok = load(fw_runtime),
    ok = application:set_env(fw_runtime, room_ttl_ms, 86_400_000),
    maps:foreach(fun(Key, Value) -> application:set_env(fw_runtime, Key, Value) end, Overrides),
    {ok, _Started} = application:ensure_all_started(fw_runtime),
    ok.

restart(Config) ->
    ok = application:stop(fw_runtime),
    boot(#{
        snapshots => application:get_env(fw_runtime, snapshots, fw_snapshots_none),
        snapshot_file => ?config(snapshot_file, Config)
    }).

load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

write_snapshot(File, Hash, Bytes) ->
    {ok, direct} = dets:open_file(direct, [{file, File}, {type, set}]),
    ok = dets:insert(direct, {Hash, Bytes}),
    dets:close(direct).

long_expired() ->
    {ok, Grid} = fw_grid:new(0, 15, 8),
    {ok, Room} = fw_room:new(
        #{
            grid => Grid,
            duration_slots => 2,
            host_token => <<"whatever">>,
            capacity => 4,
            ttl_ms => 1
        },
        0
    ),
    fw_room:to_binary(Room).

room() ->
    {ok, Grid} = fw_grid:new(0, 15, 8),
    {ok, #{hash := Hash, host_token := Token}} =
        fw_rooms:create(#{grid => Grid, duration_slots => 2}),
    {Hash, Token}.
