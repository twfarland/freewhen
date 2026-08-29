-module(fw_room_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOKEN, <<"host-token-0123456789abcdef">>).
-define(IDLE, 2_592_000_000).
-define(SLOT_MS, 900_000).

grid() ->
    {ok, Grid} = fw_grid:new(0, 15, 8),
    Grid.

room() -> room(#{}).

room(Overrides) ->
    Params = maps:merge(
        #{
            grid => grid(),
            duration_slots => 2,
            host_token => ?TOKEN,
            capacity => 3,
            idle_ms => ?IDLE
        },
        Overrides
    ),
    {ok, Room} = fw_room:new(Params, 1000),
    Room.

joined(Ids) -> lists:foldl(fun join/2, room(), Ids).

join(Id, Room) ->
    {ok, Next} = fw_room:join(Id, Id, 1000, Room),
    Next.

answered(Id, FreeSlots, Room) ->
    {ok, Next} = fw_room:submit(Id, FreeSlots, 1000, Room),
    Next.

all_week() -> lists:seq(0, 7).

free_except(Busy) -> [Slot || Slot <- all_week(), not lists:member(Slot, Busy)].

%%% ---- construction ----

a_new_room_expires_one_idle_window_from_now_test() ->
    ?assertEqual(1000 + ?IDLE, fw_room:expires_at(room())).

%% A room lives on idleness, not age: arranging a meeting across organisations
%% can take weeks, and a room that died mid-negotiation would be worse than
%% useless.
joining_pushes_the_deadline_out_test() ->
    Later = 1000 + ?IDLE - 1,
    {ok, Room} = fw_room:join(<<"a">>, <<"a">>, Later, room()),
    ?assertEqual(Later + ?IDLE, fw_room:expires_at(Room)).

answering_pushes_the_deadline_out_test() ->
    Later = 1000 + ?IDLE - 1,
    {ok, Room} = fw_room:submit(<<"a">>, [0], Later, joined([<<"a">>])),
    ?assertEqual(Later + ?IDLE, fw_room:expires_at(Room)).

a_room_nobody_touches_still_runs_out_test() ->
    {ok, Room} = fw_room:join(<<"a">>, <<"a">>, 2000, room()),
    ?assert(fw_room:is_expired(2000 + ?IDLE, Room)).

%% Picking settles the room, and a settled room is not a negotiation any more:
%% the runtime swaps it onto a fixed grace rather than an idle window.
picking_does_not_push_the_deadline_out_test() ->
    Room = joined([<<"a">>]),
    Before = fw_room:expires_at(Room),
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 2000, Room),
    ?assertEqual(Before, fw_room:expires_at(Picked)).

a_new_room_has_nobody_in_it_and_nothing_chosen_test() ->
    ?assertEqual([], fw_room:attendees(room())),
    ?assertEqual(undefined, fw_room:picked(room())),
    ?assertEqual(undefined, fw_schedule:chosen(room())).

a_meeting_longer_than_the_grid_cannot_be_scheduled_test() ->
    Params = #{
        grid => grid(),
        duration_slots => 9,
        host_token => ?TOKEN,
        capacity => 3,
        idle_ms => ?IDLE
    },
    ?assertEqual({error, bad_duration}, fw_room:new(Params, 1000)).

%%% ---- joining ----

attendees_are_listed_in_the_order_they_joined_test() ->
    Room = joined([<<"c">>, <<"a">>, <<"b">>]),
    ?assertEqual(
        [<<"c">>, <<"a">>, <<"b">>],
        [fw_attendee:id(A) || A <- fw_room:attendees(Room)]
    ).

the_same_id_cannot_join_twice_test() ->
    Joined = joined([<<"a">>]),
    ?assertEqual({error, duplicate}, fw_room:join(<<"a">>, <<"a">>, 1000, Joined)).

a_room_at_capacity_refuses_the_next_arrival_test() ->
    Full = joined([<<"a">>, <<"b">>, <<"c">>]),
    ?assertEqual({error, full}, fw_room:join(<<"d">>, <<"d">>, 1000, Full)).

joining_an_expired_room_is_refused_test() ->
    ?assertEqual({error, expired}, fw_room:join(<<"a">>, <<"a">>, 1000 + ?IDLE, room())).

a_bad_alias_is_refused_by_the_room_too_test() ->
    ?assertEqual({error, bad_alias}, fw_room:join(<<"a">>, <<>>, 1000, room())).

%%% ---- answering ----

a_stranger_cannot_answer_test() ->
    ?assertEqual(
        {error, unknown_attendee},
        fw_room:submit(<<"z">>, [0], 1000, joined([<<"a">>]))
    ).

an_answer_of_no_free_time_is_still_an_answer_test() ->
    Room = answered(<<"a">>, [], joined([<<"a">>])),
    ?assertEqual([0, 0, 0, 0, 0, 0, 0, 0], fw_schedule:heatmap(Room)),
    ?assertEqual([], fw_schedule:proposals(Room)).

a_slot_that_is_not_on_the_grid_is_refused_test() ->
    Joined = joined([<<"a">>]),
    ?assertEqual({error, bad_slot}, fw_room:submit(<<"a">>, [8], 1000, Joined)),
    ?assertEqual({error, bad_slot}, fw_room:submit(<<"a">>, [-1], 1000, Joined)).

answering_an_expired_room_is_refused_test() ->
    ?assertEqual(
        {error, expired},
        fw_room:submit(<<"a">>, [0], 1000 + ?IDLE, joined([<<"a">>]))
    ).

%%% ---- the heatmap ----

an_attendee_who_has_not_answered_is_not_counted_test() ->
    ?assertEqual([0, 0, 0, 0, 0, 0, 0, 0], fw_schedule:heatmap(joined([<<"a">>]))).

an_attendee_who_answered_is_counted_where_they_are_free_test() ->
    Room = answered(<<"a">>, free_except([1]), joined([<<"a">>])),
    ?assertEqual([1, 0, 1, 1, 1, 1, 1, 1], fw_schedule:heatmap(Room)).

the_heatmap_is_the_sum_over_everyone_who_answered_test() ->
    One = answered(<<"a">>, free_except([1]), joined([<<"a">>, <<"b">>])),
    Two = answered(<<"b">>, free_except([1, 2]), One),
    ?assertEqual([2, 0, 1, 2, 2, 2, 2, 2], fw_schedule:heatmap(Two)).

answering_again_replaces_rather_than_accumulates_test() ->
    First = answered(<<"a">>, [0], joined([<<"a">>])),
    Second = answered(<<"a">>, [3, 4], First),
    ?assertEqual([0, 0, 0, 1, 1, 0, 0, 0], fw_schedule:heatmap(Second)).

%%% ---- proposals ----

proposals_rank_the_windows_everyone_can_attend_test() ->
    Room = answered(<<"a">>, [4, 5, 6, 7], joined([<<"a">>])),
    ?assertEqual([4, 5, 6], [fw_proposal:slot(P) || P <- fw_schedule:proposals(Room)]).

%% The browser is given instants, never slot numbers to do arithmetic on.
a_proposal_carries_the_utc_instants_of_its_window_test() ->
    Room = answered(<<"a">>, [4, 5, 6, 7], joined([<<"a">>])),
    [Proposal | _Rest] = fw_schedule:proposals(Room),
    ?assertEqual(4 * ?SLOT_MS, fw_proposal:starts_at(Proposal)),
    ?assertEqual(6 * ?SLOT_MS, fw_proposal:ends_at(Proposal)),
    ?assertEqual(1, fw_proposal:free(Proposal)).

a_room_where_nobody_answered_offers_nothing_test() ->
    ?assertEqual([], fw_schedule:proposals(joined([<<"a">>]))).

%%% ---- picking ----

the_host_can_pick_a_slot_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, joined([<<"a">>])),
    ?assertEqual(4, fw_room:picked(Picked)).

the_chosen_time_is_a_proposal_with_its_instants_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, joined([<<"a">>])),
    Chosen = fw_schedule:chosen(Picked),
    ?assertEqual(4, fw_proposal:slot(Chosen)),
    ?assertEqual(4 * ?SLOT_MS, fw_proposal:starts_at(Chosen)),
    ?assertEqual(6 * ?SLOT_MS, fw_proposal:ends_at(Chosen)).

someone_without_the_host_token_cannot_pick_test() ->
    ?assertEqual({error, forbidden}, fw_room:pick(4, <<"guess">>, 1000, room())).

a_token_of_the_right_length_but_wrong_value_cannot_pick_test() ->
    Wrong = binary:copy(<<"x">>, byte_size(?TOKEN)),
    ?assertEqual({error, forbidden}, fw_room:pick(4, Wrong, 1000, room())).

a_token_that_is_not_a_binary_cannot_pick_test() ->
    ?assertEqual({error, forbidden}, fw_room:pick(4, undefined, 1000, room())).

a_meeting_must_finish_inside_the_grid_test() ->
    ?assertEqual({error, bad_slot}, fw_room:pick(7, ?TOKEN, 1000, room())),
    ?assertMatch({ok, _}, fw_room:pick(6, ?TOKEN, 1000, room())).

picking_a_slot_that_is_not_a_slot_is_refused_test() ->
    ?assertEqual({error, bad_slot}, fw_room:pick(<<"4">>, ?TOKEN, 1000, room())).

picking_in_an_expired_room_is_refused_test() ->
    ?assertEqual({error, expired}, fw_room:pick(4, ?TOKEN, 1000 + ?IDLE, room())).

%%% ---- once settled, the room is read-only ----

nobody_may_join_after_a_slot_is_picked_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, room()),
    ?assertEqual({error, finalized}, fw_room:join(<<"a">>, <<"a">>, 1000, Picked)).

nobody_may_answer_again_after_a_slot_is_picked_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, joined([<<"a">>])),
    ?assertEqual({error, finalized}, fw_room:submit(<<"a">>, [0], 1000, Picked)).

an_answer_too_fragmented_to_be_meant_is_refused_test() ->
    {ok, Wide} = fw_grid:new(0, 15, 672),
    Params = #{
        grid => Wide,
        duration_slots => 2,
        host_token => ?TOKEN,
        capacity => 3,
        idle_ms => ?IDLE
    },
    {ok, Room} = fw_room:new(Params, 1000),
    {ok, Joined} = fw_room:join(<<"a">>, <<"a">>, 1000, Room),
    Alternating = [Slot || Slot <- lists:seq(0, 671), Slot rem 2 =:= 0],
    ?assertEqual({error, too_fragmented}, fw_room:submit(<<"a">>, Alternating, 1000, Joined)).

the_host_may_not_change_their_mind_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, room()),
    ?assertEqual({error, finalized}, fw_room:pick(2, ?TOKEN, 1000, Picked)).

%%% ---- budgets ----

%% How much memory a room costs is what decides how many a machine can hold,
%% and availability dominates it. Held as a set of slot numbers this room was
%% 38 kB; as stretches of free time it is a small fraction of that. A change
%% that quietly reverted the representation would be invisible without this.
a_full_week_for_sixteen_people_fits_in_four_kilobytes_test() ->
    {ok, Week} = fw_grid:new(0, 15, 672),
    Crowded = crowded(Week, 16),
    ?assert(byte_size(fw_room:to_binary(Crowded)) < 4096).

crowded(Grid, Count) ->
    Params = #{
        grid => Grid,
        duration_slots => 2,
        host_token => ?TOKEN,
        capacity => Count,
        idle_ms => ?IDLE
    },
    {ok, Empty} = fw_room:new(Params, 1000),
    FreeAllWeek = lists:seq(0, 671),
    lists:foldl(fun(N, Room) -> crowd(N, FreeAllWeek, Room) end, Empty, lists:seq(1, Count)).

crowd(N, Free, Room) ->
    Id = <<"attendee-", (integer_to_binary(N))/binary>>,
    {ok, Joined} = fw_room:join(Id, Id, 1000, Room),
    {ok, Answered} = fw_room:submit(Id, Free, 1000, Joined),
    Answered.

%%% ---- expiry ----

a_room_is_expired_exactly_at_its_deadline_test() ->
    Room = room(),
    ?assertNot(fw_room:is_expired(1000 + ?IDLE - 1, Room)),
    ?assert(fw_room:is_expired(1000 + ?IDLE, Room)).
