-module(fw_web_SUITE).
-moduledoc "End to end: a real listener, real sockets, the protocol as documented.".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    health_reports_the_room_count/1,
    a_room_is_created_with_a_hash_and_a_host_token/1,
    two_rooms_never_share_a_hash_or_a_token/1,
    a_hash_is_derived_from_its_host_token/1,
    a_malformed_creation_request_is_refused/1,
    a_creation_request_with_an_impossible_grid_is_refused/1,
    a_method_other_than_post_is_refused/1,
    the_client_is_served/1,
    an_unknown_room_is_not_found/1,
    connecting_sends_the_room_immediately/1,
    joining_replies_with_an_id_then_announces_the_attendee/1,
    every_watcher_sees_a_change/1,
    answering_updates_the_heatmap_and_the_proposals/1,
    a_proposal_carries_utc_instants/1,
    an_attendee_id_is_never_published/1,
    only_the_host_can_pick_a_slot/1,
    picking_settles_the_room/1,
    a_garbage_frame_is_answered_with_an_error/1,
    a_lost_room_is_resumed_at_the_same_hash/1,
    resuming_a_live_room_leaves_it_alone/1,
    resuming_with_the_wrong_token_reaches_a_different_room/1
]).

all() ->
    [
        health_reports_the_room_count,
        a_room_is_created_with_a_hash_and_a_host_token,
        two_rooms_never_share_a_hash_or_a_token,
        a_hash_is_derived_from_its_host_token,
        a_malformed_creation_request_is_refused,
        a_creation_request_with_an_impossible_grid_is_refused,
        a_method_other_than_post_is_refused,
        the_client_is_served,
        an_unknown_room_is_not_found,
        connecting_sends_the_room_immediately,
        joining_replies_with_an_id_then_announces_the_attendee,
        every_watcher_sees_a_change,
        answering_updates_the_heatmap_and_the_proposals,
        a_proposal_carries_utc_instants,
        an_attendee_id_is_never_published,
        only_the_host_can_pick_a_slot,
        picking_settles_the_room,
        a_garbage_frame_is_answered_with_an_error,
        a_lost_room_is_resumed_at_the_same_hash,
        resuming_a_live_room_leaves_it_alone,
        resuming_with_the_wrong_token_reaches_a_different_room
    ].

%% Port 0 so the suite runs on a busy machine; the bound port is read back.
init_per_suite(Config) ->
    {ok, _Gun} = application:ensure_all_started(gun),
    ok = load(fw_runtime),
    ok = application:set_env(fw_runtime, max_attendees_per_room, 4),
    ok = application:set_env(fw_runtime, create_bucket, #{
        capacity => 1_000, refill_per_sec => 1_000, cost => 1
    }),
    ok = load(fw_web),
    ok = application:set_env(fw_web, port, 0),
    {ok, _Started} = application:ensure_all_started(fw_web),
    [{port, fw_web_sup:port()} | Config].

%% rebar3 has already loaded the applications by the time a suite runs.
load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

end_per_suite(_Config) ->
    ok = application:stop(fw_web),
    ok = application:stop(fw_runtime).

%%% ---- creating rooms ----

health_reports_the_room_count(Config) ->
    {200, Body} = http_get(Config, "/healthz"),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Body)),
    ?assert(is_integer(maps:get(<<"rooms">>, Body))).

a_room_is_created_with_a_hash_and_a_host_token(Config) ->
    {201, #{<<"hash">> := Hash, <<"hostToken">> := Token}} = create(Config),
    ?assertEqual(22, byte_size(Hash)),
    ?assertEqual(43, byte_size(Token)).

two_rooms_never_share_a_hash_or_a_token(Config) ->
    {201, #{<<"hash">> := First, <<"hostToken">> := FirstToken}} = create(Config),
    {201, #{<<"hash">> := Second, <<"hostToken">> := SecondToken}} = create(Config),
    ?assertNotEqual(First, Second),
    ?assertNotEqual(FirstToken, SecondToken).

%% The derivation is what makes a room resumable: presenting the token proves
%% the right to the hash, so the server can recreate a room it has forgotten.
a_hash_is_derived_from_its_host_token(Config) ->
    {201, #{<<"hash">> := Hash, <<"hostToken">> := Token}} = create(Config),
    ?assertEqual(Hash, fw_ids:hash_of(Token)).

a_malformed_creation_request_is_refused(Config) ->
    ?assertMatch({400, #{<<"error">> := <<"bad_request">>}}, post_raw(Config, <<"not json">>)),
    ?assertMatch({400, #{<<"error">> := <<"bad_request">>}}, post_raw(Config, <<"{}">>)).

a_creation_request_with_an_impossible_grid_is_refused(Config) ->
    ?assertMatch({400, #{<<"error">> := <<"bad_slots">>}}, create(Config, #{<<"slots">> => 0})),
    ?assertMatch(
        {400, #{<<"error">> := <<"bad_slot_minutes">>}},
        create(Config, #{<<"slotMinutes">> => 0})
    ),
    ?assertMatch(
        {400, #{<<"error">> := <<"bad_duration">>}},
        create(Config, #{<<"durationSlots">> => 99})
    ).

a_method_other_than_post_is_refused(Config) ->
    ?assertMatch({405, _}, http_get(Config, "/api/rooms")).

%% A room link is a client-side route, so every path under /m must return the
%% page rather than a 404 from the router.
the_client_is_served(Config) ->
    ?assertMatch({200, <<"<!doctype html>", _/binary>>}, raw_get(Config, "/")),
    ?assertMatch({200, <<"<!doctype html>", _/binary>>}, raw_get(Config, "/m/anything")),
    ?assertMatch({200, _}, raw_get(Config, "/static/app.js")),
    ?assertMatch({200, _}, raw_get(Config, "/static/style.css")).

%%% ---- connecting ----

an_unknown_room_is_not_found(Config) ->
    ?assertEqual(404, fw_ws_client:upgrade_status(port(Config), <<"nJ8kQpZ2vX4mLwRt6yBc7A">>)).

connecting_sends_the_room_immediately(Config) ->
    {Socket, _Hash, _Token} = watched(Config),
    Room = state(Socket),
    ?assertEqual(
        #{<<"startsAt">> => 0, <<"slotMinutes">> => 15, <<"slots">> => 8},
        maps:get(<<"grid">>, Room)
    ),
    ?assertEqual(2, maps:get(<<"durationSlots">>, Room)),
    ?assertEqual([], maps:get(<<"attendees">>, Room)),
    ?assertEqual(lists:duplicate(8, 0), maps:get(<<"heatmap">>, Room)),
    ?assertEqual([], maps:get(<<"proposals">>, Room)),
    ?assertEqual(null, maps:get(<<"chosen">>, Room)),
    fw_ws_client:close(Socket).

%%% ---- taking part ----

joining_replies_with_an_id_then_announces_the_attendee(Config) ->
    {Socket, _Hash, _Token} = watched(Config),
    _Initial = state(Socket),
    fw_ws_client:join(Socket, <<"Blue Falcon">>),
    ?assertMatch(#{<<"type">> := <<"joined">>, <<"attendeeId">> := _}, fw_ws_client:recv(Socket)),
    ?assertMatch([#{<<"alias">> := <<"Blue Falcon">>, <<"ready">> := false}],
                 maps:get(<<"attendees">>, state(Socket))),
    fw_ws_client:close(Socket).

every_watcher_sees_a_change(Config) ->
    {Host, Hash, _Token} = watched(Config),
    Guest = fw_ws_client:connect(port(Config), Hash),
    _HostInitial = state(Host),
    _GuestInitial = state(Guest),
    fw_ws_client:join(Guest, <<"Blue Falcon">>),
    _Joined = fw_ws_client:recv(Guest),
    ?assertMatch([#{<<"alias">> := <<"Blue Falcon">>}], maps:get(<<"attendees">>, state(Host))),
    ?assertMatch([#{<<"alias">> := <<"Blue Falcon">>}], maps:get(<<"attendees">>, state(Guest))),
    fw_ws_client:close(Host),
    fw_ws_client:close(Guest).

answering_updates_the_heatmap_and_the_proposals(Config) ->
    {Socket, _Hash, _Token} = watched(Config),
    {Id, _Announced} = joined_as(Socket, <<"Blue Falcon">>),
    fw_ws_client:submit(Socket, Id, busy([1, 2])),
    Room = state(Socket),
    ?assertEqual([1, 0, 0, 1, 1, 1, 1, 1], maps:get(<<"heatmap">>, Room)),
    ?assertMatch([#{<<"alias">> := <<"Blue Falcon">>, <<"ready">> := true}],
                 maps:get(<<"attendees">>, Room)),
    ?assertMatch(#{<<"slot">> := 3, <<"free">> := 1}, hd(maps:get(<<"proposals">>, Room))),
    fw_ws_client:close(Socket).

%% Slot 3 of a grid starting at 0 with 15-minute slots, two slots long.
a_proposal_carries_utc_instants(Config) ->
    {Socket, _Hash, _Token} = watched(Config),
    {Id, _Announced} = joined_as(Socket, <<"Blue Falcon">>),
    fw_ws_client:submit(Socket, Id, busy([1, 2])),
    Proposal = hd(maps:get(<<"proposals">>, state(Socket))),
    ?assertEqual(3 * 900_000, maps:get(<<"startsAt">>, Proposal)),
    ?assertEqual(5 * 900_000, maps:get(<<"endsAt">>, Proposal)),
    fw_ws_client:close(Socket).

%% An attendee id is a capability: whoever holds it may replace that person's
%% availability. It must never appear in a snapshot every watcher receives.
an_attendee_id_is_never_published(Config) ->
    {Socket, _Hash, _Token} = watched(Config),
    {Id, Announced} = joined_as(Socket, <<"Blue Falcon">>),
    ?assertEqual(nomatch, binary:match(fw_json:encode(Announced), Id)),
    fw_ws_client:close(Socket).

%%% ---- settling ----

only_the_host_can_pick_a_slot(Config) ->
    {Socket, _Hash, _Token} = watched(Config),
    _Initial = state(Socket),
    fw_ws_client:pick(Socket, <<"not-the-host-token">>, 4),
    ?assertEqual(
        #{<<"type">> => <<"error">>, <<"reason">> => <<"forbidden">>},
        fw_ws_client:recv(Socket)
    ),
    fw_ws_client:silent(Socket),
    fw_ws_client:close(Socket).

picking_settles_the_room(Config) ->
    {Socket, _Hash, Token} = watched(Config),
    _Initial = state(Socket),
    fw_ws_client:pick(Socket, Token, 4),
    Chosen = maps:get(<<"chosen">>, state(Socket)),
    ?assertEqual(4, maps:get(<<"slot">>, Chosen)),
    ?assertEqual(4 * 900_000, maps:get(<<"startsAt">>, Chosen)),
    fw_ws_client:join(Socket, <<"Late Arrival">>),
    ?assertEqual(
        #{<<"type">> => <<"error">>, <<"reason">> => <<"finalized">>},
        fw_ws_client:recv(Socket)
    ),
    fw_ws_client:close(Socket).

a_garbage_frame_is_answered_with_an_error(Config) ->
    {Socket, _Hash, _Token} = watched(Config),
    _Initial = state(Socket),
    {Pid, Stream} = Socket,
    gun:ws_send(Pid, Stream, {text, <<"this is not a message">>}),
    ?assertMatch(#{<<"type">> := <<"error">>}, fw_ws_client:recv(Socket)),
    gun:ws_send(Pid, Stream, {text, <<"{\"type\":\"nonsense\"}">>}),
    ?assertEqual(
        #{<<"type">> => <<"error">>, <<"reason">> => <<"unrecognised message">>},
        fw_ws_client:recv(Socket)
    ),
    fw_ws_client:close(Socket).

%%% ---- surviving a release ----

%% Killing the room process is what a deploy does to every room at once. The
%% host's token is enough to bring the address back with nothing stored.
a_lost_room_is_resumed_at_the_same_hash(Config) ->
    {201, #{<<"hash">> := Hash, <<"hostToken">> := Token}} = create(Config),
    ok = destroy(Hash),
    ?assertEqual(404, fw_ws_client:upgrade_status(port(Config), Hash)),
    ?assertMatch({201, #{<<"hash">> := Hash}}, create(Config, #{<<"resume">> => Token})),
    Socket = fw_ws_client:connect(port(Config), Hash),
    ?assertEqual([], maps:get(<<"attendees">>, state(Socket))),
    fw_ws_client:close(Socket).

resuming_a_live_room_leaves_it_alone(Config) ->
    {Socket, Hash, Token} = watched(Config),
    {_Id, _Announced} = joined_as(Socket, <<"Blue Falcon">>),
    ?assertMatch({201, #{<<"hash">> := Hash}}, create(Config, #{<<"resume">> => Token})),
    fw_ws_client:silent(Socket),
    Rejoined = fw_ws_client:connect(port(Config), Hash),
    ?assertMatch([#{<<"alias">> := <<"Blue Falcon">>}], maps:get(<<"attendees">>, state(Rejoined))),
    fw_ws_client:close(Socket),
    fw_ws_client:close(Rejoined).

%% A token nobody owns simply derives a different hash. There is no room to
%% take over, because taking over would need a preimage of somebody's hash.
resuming_with_the_wrong_token_reaches_a_different_room(Config) ->
    {201, #{<<"hash">> := Hash}} = create(Config),
    {201, #{<<"hash">> := Other}} = create(Config, #{<<"resume">> => <<"an-invented-token">>}),
    ?assertNotEqual(Hash, Other).

%%% ---- helpers ----

port(Config) -> ?config(port, Config).

watched(Config) ->
    {201, #{<<"hash">> := Hash, <<"hostToken">> := Token}} = create(Config),
    {fw_ws_client:connect(port(Config), Hash), Hash, Token}.

destroy(Hash) ->
    {ok, Pid} = fw_rooms:find(Hash),
    Monitor = erlang:monitor(process, Pid),
    true = exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 5_000 -> error(room_would_not_die)
    end.

state(Socket) ->
    #{<<"type">> := <<"state">>, <<"room">> := Room} = fw_ws_client:recv(Socket),
    Room.

%% Consumes the opening snapshot, joins, and returns the new id together with
%% the snapshot that announced it.
joined_as(Socket, Alias) ->
    _Initial = state(Socket),
    fw_ws_client:join(Socket, Alias),
    #{<<"attendeeId">> := Id} = fw_ws_client:recv(Socket),
    {Id, state(Socket)}.

busy(Slots) ->
    Bits = <<<<(bit(lists:member(Slot, Slots))):1>> || Slot <- lists:seq(0, 7)>>,
    base64:encode(Bits, #{mode => urlsafe, padding => false}).

bit(true) -> 1;
bit(false) -> 0.

%%% ---- HTTP ----

create(Config) -> create(Config, #{}).

create(Config, Overrides) ->
    Body = maps:merge(
        #{
            <<"startsAt">> => 0,
            <<"slotMinutes">> => 15,
            <<"slots">> => 8,
            <<"durationSlots">> => 2
        },
        Overrides
    ),
    post_raw(Config, fw_json:encode(Body)).

post_raw(Config, Body) ->
    request(Config, fun(Pid) ->
        gun:post(Pid, "/api/rooms", [{<<"content-type">>, <<"application/json">>}], Body)
    end).

http_get(Config, Path) ->
    request(Config, fun(Pid) -> gun:get(Pid, Path) end).

request(Config, Send) ->
    {Status, Body} = raw(Config, Send),
    {ok, Decoded} = fw_json:decode(Body),
    {Status, Decoded}.

raw_get(Config, Path) ->
    raw(Config, fun(Pid) -> gun:get(Pid, Path) end).

raw(Config, Send) ->
    {ok, Pid} = gun:open("localhost", port(Config), #{protocols => [http]}),
    {ok, http} = gun:await_up(Pid, 5_000),
    Stream = Send(Pid),
    Result = await(Pid, Stream),
    gun:close(Pid),
    Result.

await(Pid, Stream) ->
    case gun:await(Pid, Stream, 5_000) of
        {response, fin, Status, _Headers} ->
            {Status, <<"{}">>};
        {response, nofin, Status, _Headers} ->
            {ok, Body} = gun:await_body(Pid, Stream, 5_000),
            {Status, Body}
    end.
