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
    one_change_publishes_exactly_one_state/1,
    a_proposal_carries_utc_instants/1,
    an_attendee_id_is_never_published/1,
    only_the_host_can_pick_a_slot/1,
    a_time_cannot_be_chosen_until_everybody_has_answered/1,
    picking_puts_a_time_on_the_table/1,
    availability_changing_invalidates_the_chosen_time/1,
    the_host_can_move_the_meeting_again/1,
    the_host_can_go_ahead_without_the_silent/1,
    cancelling_ends_the_room_for_everybody/1,
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
        one_change_publishes_exactly_one_state,
        a_proposal_carries_utc_instants,
        an_attendee_id_is_never_published,
        only_the_host_can_pick_a_slot,
        a_time_cannot_be_chosen_until_everybody_has_answered,
        picking_puts_a_time_on_the_table,
        availability_changing_invalidates_the_chosen_time,
        the_host_can_move_the_meeting_again,
        the_host_can_go_ahead_without_the_silent,
        cancelling_ends_the_room_for_everybody,
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
    fw_ws_client:submit(Socket, Id, free([0, 3, 4, 5, 6, 7])),
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
    fw_ws_client:submit(Socket, Id, free([0, 3, 4, 5, 6, 7])),
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

%% A client that answered the broadcast by resubmitting would ping-pong with
%% the server forever, because every successful command publishes a state. The
%% browser had exactly that bug; this is the wire-level guard against it.
one_change_publishes_exactly_one_state(Config) ->
    {Socket, _Hash, _Token} = watched(Config),
    _Initial = state(Socket),
    fw_ws_client:join(Socket, <<"Blue Falcon">>),
    #{<<"attendeeId">> := Id} = fw_ws_client:recv(Socket),
    _AfterJoin = state(Socket),
    fw_ws_client:submit(Socket, Id, free([0, 1, 2])),
    _AfterSubmit = state(Socket),
    fw_ws_client:silent(Socket),
    fw_ws_client:close(Socket).

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

%% Choosing while somebody is still deciding is how a meeting gets booked over
%% the one person who could not make it.
a_time_cannot_be_chosen_until_everybody_has_answered(Config) ->
    {Socket, _Hash, Token} = watched(Config),
    {_Id, Empty} = joined_as(Socket, <<"Blue Falcon">>),
    ?assertEqual(<<"collecting">>, maps:get(<<"phase">>, Empty)),
    fw_ws_client:pick(Socket, Token, 4),
    ?assertEqual(
        #{<<"type">> => <<"error">>, <<"reason">> => <<"still_waiting">>},
        fw_ws_client:recv(Socket)
    ),
    fw_ws_client:close(Socket).

picking_puts_a_time_on_the_table(Config) ->
    {Socket, _Hash, Token} = watched(Config),
    Ready = answered(Socket, <<"Blue Falcon">>, [4, 5, 6, 7]),
    ?assertEqual(<<"ready">>, maps:get(<<"phase">>, Ready)),
    fw_ws_client:pick(Socket, Token, 4),
    Settled = state(Socket),
    Chosen = maps:get(<<"chosen">>, Settled),
    ?assertEqual(4, maps:get(<<"slot">>, Chosen)),
    ?assertEqual(4 * 900_000, maps:get(<<"startsAt">>, Chosen)),
    ?assertEqual(1, maps:get(<<"free">>, Chosen)),
    ?assertEqual(<<"confirmed">>, maps:get(<<"phase">>, Settled)),
    %% Somebody late to the room is not locked out of a meeting that has not
    %% happened yet — but they do make it provisional until they answer.
    fw_ws_client:join(Socket, <<"Late Arrival">>),
    ?assertMatch(#{<<"type">> := <<"joined">>}, fw_ws_client:recv(Socket)),
    ?assertEqual(<<"provisional">>, maps:get(<<"phase">>, state(Socket))),
    fw_ws_client:close(Socket).

%% Nobody has to remember to withdraw an acceptance: the answer people already
%% gave is the only thing a confirmation is made of.
availability_changing_invalidates_the_chosen_time(Config) ->
    {Socket, _Hash, Token} = watched(Config),
    {Id, _Ready} = answered_as(Socket, <<"Blue Falcon">>, [4, 5, 6, 7]),
    fw_ws_client:pick(Socket, Token, 4),
    ?assertEqual(<<"confirmed">>, maps:get(<<"phase">>, state(Socket))),
    fw_ws_client:submit(Socket, Id, free([0, 1])),
    Invalidated = state(Socket),
    ?assertEqual(<<"provisional">>, maps:get(<<"phase">>, Invalidated)),
    ?assertEqual(0, maps:get(<<"free">>, maps:get(<<"chosen">>, Invalidated))),
    fw_ws_client:close(Socket).

%% The scenario the whole reschedule model exists for: a time is agreed, the
%% plan changes, and the same link has to keep working.
the_host_can_move_the_meeting_again(Config) ->
    {Socket, _Hash, Token} = watched(Config),
    _Ready = answered(Socket, <<"Blue Falcon">>, [4, 5, 6, 7]),
    fw_ws_client:pick(Socket, Token, 4),
    ?assertEqual(4, maps:get(<<"slot">>, maps:get(<<"chosen">>, state(Socket)))),
    fw_ws_client:unpick(Socket, Token),
    Reopened = state(Socket),
    ?assertEqual(null, maps:get(<<"chosen">>, Reopened)),
    ?assertEqual(<<"ready">>, maps:get(<<"phase">>, Reopened)),
    fw_ws_client:pick(Socket, Token, 6),
    ?assertEqual(6, maps:get(<<"slot">>, maps:get(<<"chosen">>, state(Socket)))),
    fw_ws_client:close(Socket).

%% The one way past the gate, for somebody who opened the link and went away.
the_host_can_go_ahead_without_the_silent(Config) ->
    {Socket, Hash, Token} = watched(Config),
    _Ready = answered(Socket, <<"Blue Falcon">>, [4, 5, 6, 7]),
    Silent = fw_ws_client:connect(port(Config), Hash),
    {_Id, _Snapshot} = joined_as(Silent, <<"Ghost">>),
    ?assertEqual(<<"collecting">>, maps:get(<<"phase">>, state(Socket))),
    fw_ws_client:exclude_silent(Socket, Token),
    Without = state(Socket),
    ?assertEqual(<<"ready">>, maps:get(<<"phase">>, Without)),
    ?assertEqual([<<"Blue Falcon">>], [A || #{<<"alias">> := A} <- attendees(Without)]),
    fw_ws_client:close(Silent),
    fw_ws_client:close(Socket).

%% Cancelling has to reach everybody watching, and has to be told apart from a
%% room that simply ran out of time — a host's own browser reopens a room it
%% believes was lost, and would otherwise resurrect what it just called off.
cancelling_ends_the_room_for_everybody(Config) ->
    {Socket, Hash, Token} = watched(Config),
    Guest = fw_ws_client:connect(port(Config), Hash),
    _Initial = state(Guest),
    _Ready = answered(Socket, <<"Blue Falcon">>, [4, 5, 6, 7]),
    _Echo = state(Guest),
    _Answer = state(Guest),
    fw_ws_client:cancel(Socket, Token),
    ?assertEqual(
        #{<<"type">> => <<"closed">>, <<"reason">> => <<"cancelled">>},
        last(Socket)
    ),
    ?assertEqual(
        #{<<"type">> => <<"closed">>, <<"reason">> => <<"cancelled">>},
        last(Guest)
    ),
    ?assertEqual(error, fw_rooms:find(Hash)).

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

%% Joins and answers, which is the least a room needs before a time may be
%% chosen in it at all.
answered_as(Socket, Alias, Slots) ->
    {Id, _Joined} = joined_as(Socket, Alias),
    fw_ws_client:submit(Socket, Id, free(Slots)),
    {Id, state(Socket)}.

answered(Socket, Alias, Slots) ->
    {_Id, Snapshot} = answered_as(Socket, Alias, Slots),
    Snapshot.

attendees(Snapshot) -> maps:get(<<"attendees">>, Snapshot).

%% Frames keep arriving until the room goes; the last one is the goodbye.
last(Socket) -> last(Socket, fw_ws_client:recv(Socket)).

last(Socket, #{<<"type">> := <<"state">>}) -> last(Socket, fw_ws_client:recv(Socket));
last(_Socket, Frame) -> Frame.

free(Slots) ->
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
