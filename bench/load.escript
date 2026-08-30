#!/usr/bin/env escript
%%! -noshell
%%
%% Fill the node to its room ceiling, measure what that costs, and throw it all
%% away. Nothing here touches a machine you care about: the snapshot goes to a
%% scratch file that is deleted on the way out, and the node dies with the
%% script.
%%
%%   rebar3 compile && escript bench/load.escript
%%   escript bench/load.escript --rooms 20000 --attendees 16 --mode adversarial
%%
%% The numbers in config/sys.config and docs/ARCHITECTURE.md were calculated
%% from a single measured room. This is how you find out whether the
%% multiplication holds — and, more usefully, how long `fw_rooms:restore/0`
%% takes at the ceiling, because that runs before the listener opens and
%% nobody has ever timed it.
%%
%% Deliberately not an HTTP test. Room creation is rate limited to about one
%% per ten seconds per address, so driving this through cowboy would measure
%% the limiter. This drives fw_runtime directly and measures capacity.

-mode(compile).

-define(SLOT_MINUTES, 15).
-define(SLOTS, 672).
-define(DURATION, 2).

main(Argv) ->
    Opts = options(Argv),
    [code:add_patha(P) || P <- filelib:wildcard("_build/default/lib/*/ebin")],
    Dir = scratch(),
    try run(Opts, Dir) of
        ok -> ok
    after
        file:del_dir_r(Dir)
    end.

run(Opts, Dir) ->
    #{rooms := Want, attendees := Attendees, mode := Mode} = Opts,
    banner(Opts),
    ok = boot(Want, Attendees, filename:join(Dir, "load.dets")),
    settled(),
    Baseline = erlang:memory(total),
    io:format("baseline   ~s before any room exists~n~n", [mb(Baseline)]),

    {FillUs, Made} = timer:tc(fun() -> fill(Want, Attendees, Mode) end),
    stage("settling"),
    settled(),
    report_fill(Made, Attendees, FillUs, Baseline),

    stage("ceiling"),
    report_ceiling(),
    stage("disk"),
    report_disk(filename:join(Dir, "load.dets")),
    stage("restart"),
    report_restore(),
    io:format("~nscratch ~ts discarded~n", [Dir]).

%%% ---- filling ----

fill(Want, Attendees, Mode) ->
    {ok, Grid} = fw_grid:new(erlang:system_time(millisecond), ?SLOT_MINUTES, ?SLOTS),
    Params = #{grid => Grid, duration_slots => ?DURATION},
    Free = availability(Mode),
    lists:foldl(fun(N, Made) -> made(one(Params, Attendees, Free), N, Want, Made) end,
                0, lists:seq(1, Want)).

one(Params, Attendees, Free) ->
    case fw_rooms:create(Params) of
        {ok, #{hash := Hash}} ->
            {ok, Room} = fw_rooms:find(Hash),
            [answer(Room, Free) || _ <- lists:seq(1, Attendees)],
            true;
        {error, _Reason} ->
            false
    end.

answer(Room, Free) ->
    Alias = alias_of(rand:uniform(1 bsl 30)),
    {ok, {joined, Id}} = fw_room_server:command(Room, {join, Alias}),
    {ok, ok} = fw_room_server:command(Room, {submit, Id, Free}).

made(true, N, Want, Made) -> tick(N, Want), Made + 1;
made(false, N, Want, Made) -> tick(N, Want), Made.

tick(N, Want) when N rem 1000 =:= 0 -> io:format("  ~b/~b~n", [N, Want]);
tick(_N, _Want) -> ok.

alias_of(N) -> list_to_binary(["p", integer_to_list(N)]).

%% `real` is an ordinary working week: five stretches, which is what almost
%% every answer actually looks like. `adversarial` is the shape the cap in
%% fw_availability exists to bound — 64 separate stretches, the worst a client
%% is allowed to send.
availability(real) ->
    lists:append([lists:seq(D * 96 + 36, D * 96 + 67) || D <- lists:seq(0, 4)]);
availability(adversarial) ->
    [S || S <- lists:seq(0, ?SLOTS - 1), S rem 2 =:= 0, S div 2 < 64].

%%% ---- what it cost ----

report_fill(Made, Attendees, Us, Baseline) ->
    Total = erlang:memory(total),
    Rooms = Total - Baseline,
    Seconds = Us / 1_000_000,
    io:format("~nfilled     ~b rooms x ~b attendees in ~.1fs (~b rooms/s)~n",
              [Made, Attendees, Seconds, round(Made / Seconds)]),
    io:format("memory     ~s of rooms (~s total), ~s per room~n",
              [mb(Rooms), mb(Total), bytes(Rooms div max(1, Made))]),
    io:format("processes  ~b~n", [erlang:system_info(process_count)]).

report_ceiling() ->
    {ok, Grid} = fw_grid:new(erlang:system_time(millisecond), ?SLOT_MINUTES, ?SLOTS),
    Answer = fw_rooms:create(#{grid => Grid, duration_slots => ?DURATION}),
    io:format("ceiling    ~b live; one more -> ~p~n", [fw_rooms:count(), Answer]).

report_disk(File) ->
    case file:read_file_info(File) of
        {ok, Info} -> io:format("snapshot   ~s on disk~n", [mb(element(2, Info))]);
        {error, _} -> io:format("snapshot   off~n")
    end.

%% The number nobody has measured: this runs at boot, before the listener
%% opens, so it is dead time on every deploy and every 04:00 kernel reboot.
report_restore() ->
    Before = fw_rooms:count(),
    {StopUs, ok} = timer:tc(fun() -> application:stop(fw_runtime) end),
    io:format("stop       ~b rooms flushed in ~.2fs~n", [Before, StopUs / 1_000_000]),
    ok = application:start(fw_runtime),
    {Us, Restored} = timer:tc(fun fw_rooms:restore/0),
    io:format("restore    ~b of ~b rooms in ~.2fs~n", [Restored, Before, Us / 1_000_000]).

%%% ---- setup ----

boot(MaxRooms, Attendees, File) ->
    ok = application:load(fw_runtime),
    Env = [
        {max_rooms, MaxRooms},
        {max_attendees_per_room, Attendees},
        {snapshots, fw_snapshots_dets},
        {snapshot_file, File},
        %% The limiter guards the HTTP edge; this is not the HTTP edge.
        {create_bucket, #{capacity => 1_000_000_000, refill_per_sec => 1, cost => 0}}
    ],
    [ok = application:set_env(fw_runtime, K, V) || {K, V} <- Env],
    {ok, _Started} = application:ensure_all_started(fw_runtime),
    ok.

%% Room state lives in 20,000 process heaps, so an ungarbaged total says more
%% about allocation churn than about what is held.
settled() ->
    [erlang:garbage_collect(P) || P <- erlang:processes()],
    timer:sleep(200).

scratch() ->
    Dir = filename:join(
        [case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
         "fw-load-" ++ integer_to_list(erlang:unique_integer([positive]))]
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

stage(What) -> io:format("~n[~ts]~n", [What]).

banner(#{rooms := R, attendees := A, mode := M}) ->
    io:format("freewhen load: ~b rooms x ~b attendees, ~p availability~n", [R, A, M]),
    io:format("(nothing outside a scratch directory is touched)~n~n").

%%% ---- arguments ----

options(Argv) -> options(Argv, #{rooms => 20_000, attendees => 8, mode => real}).

options([], Opts) ->
    Opts;
options(["--rooms", N | Rest], Opts) ->
    options(Rest, Opts#{rooms := list_to_integer(N)});
options(["--attendees", N | Rest], Opts) ->
    options(Rest, Opts#{attendees := list_to_integer(N)});
options(["--mode", "real" | Rest], Opts) ->
    options(Rest, Opts#{mode := real});
options(["--mode", "adversarial" | Rest], Opts) ->
    options(Rest, Opts#{mode := adversarial});
options([Unknown | _Rest], _Opts) ->
    io:format("unknown option ~ts~n", [Unknown]),
    halt(2).

%%% ---- formatting ----

mb(Bytes) -> io_lib:format("~.1f MB", [Bytes / 1_048_576]).

bytes(N) when N > 1024 -> io_lib:format("~.1f kB", [N / 1024]);
bytes(N) -> io_lib:format("~b B", [N]).
