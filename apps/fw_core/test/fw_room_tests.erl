-module(fw_room_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOKEN, <<"host-token-0123456789abcdef">>).
-define(TTL, 86_400_000).
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
            ttl_ms => ?TTL
        },
        Overrides
    ),
    {ok, Room} = fw_room:new(Params, 1000),
    Room.

joined(Ids) -> lists:foldl(fun join/2, room(), Ids).

join(Id, Room) ->
    {ok, Next} = fw_room:join(Id, Id, 1000, Room),
    Next.

answered(Id, BusySlots, Room) ->
    {ok, Next} = fw_room:submit(Id, BusySlots, 1000, Room),
    Next.

%%% ---- construction ----

a_room_expires_one_ttl_after_it_is_created_test() ->
    ?assertEqual(1000 + ?TTL, fw_room:expires_at(room())).

a_new_room_has_nobody_in_it_and_nothing_chosen_test() ->
    ?assertEqual([], fw_room:attendees(room())),
    ?assertEqual(undefined, fw_room:picked(room())),
    ?assertEqual(undefined, fw_room:chosen(room())).

a_meeting_longer_than_the_grid_cannot_be_scheduled_test() ->
    Params = #{
        grid => grid(),
        duration_slots => 9,
        host_token => ?TOKEN,
        capacity => 3,
        ttl_ms => ?TTL
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
    ?assertEqual({error, expired}, fw_room:join(<<"a">>, <<"a">>, 1000 + ?TTL, room())).

a_bad_alias_is_refused_by_the_room_too_test() ->
    ?assertEqual({error, bad_alias}, fw_room:join(<<"a">>, <<>>, 1000, room())).

%%% ---- leaving ----

leaving_removes_the_attendee_test() ->
    Room = fw_room:leave(<<"a">>, joined([<<"a">>, <<"b">>])),
    ?assertEqual([<<"b">>], [fw_attendee:id(A) || A <- fw_room:attendees(Room)]).

leaving_a_room_you_are_not_in_changes_nothing_test() ->
    Room = joined([<<"a">>]),
    ?assertEqual(fw_room:attendees(Room), fw_room:attendees(fw_room:leave(<<"z">>, Room))).

leaving_frees_a_place_test() ->
    Full = joined([<<"a">>, <<"b">>, <<"c">>]),
    Room = fw_room:leave(<<"a">>, Full),
    ?assertMatch({ok, _}, fw_room:join(<<"d">>, <<"d">>, 1000, Room)).

%%% ---- answering ----

a_stranger_cannot_answer_test() ->
    ?assertEqual(
        {error, unknown_attendee},
        fw_room:submit(<<"z">>, [0], 1000, joined([<<"a">>]))
    ).

a_slot_that_is_not_on_the_grid_is_refused_test() ->
    Joined = joined([<<"a">>]),
    ?assertEqual({error, bad_slot}, fw_room:submit(<<"a">>, [8], 1000, Joined)),
    ?assertEqual({error, bad_slot}, fw_room:submit(<<"a">>, [-1], 1000, Joined)).

answering_an_expired_room_is_refused_test() ->
    ?assertEqual(
        {error, expired},
        fw_room:submit(<<"a">>, [0], 1000 + ?TTL, joined([<<"a">>]))
    ).

%%% ---- the heatmap ----

an_attendee_who_has_not_answered_is_not_counted_test() ->
    ?assertEqual([0, 0, 0, 0, 0, 0, 0, 0], fw_room:heatmap(joined([<<"a">>]))).

an_attendee_who_answered_is_counted_where_they_are_free_test() ->
    Room = answered(<<"a">>, [1], joined([<<"a">>])),
    ?assertEqual([1, 0, 1, 1, 1, 1, 1, 1], fw_room:heatmap(Room)).

the_heatmap_is_the_sum_over_everyone_who_answered_test() ->
    One = answered(<<"a">>, [1], joined([<<"a">>, <<"b">>])),
    Two = answered(<<"b">>, [1, 2], One),
    ?assertEqual([2, 0, 1, 2, 2, 2, 2, 2], fw_room:heatmap(Two)).

answering_again_replaces_rather_than_accumulates_test() ->
    First = answered(<<"a">>, [0, 1, 2], joined([<<"a">>])),
    Second = answered(<<"a">>, [0], First),
    ?assertEqual([0, 1, 1, 1, 1, 1, 1, 1], fw_room:heatmap(Second)).

%%% ---- proposals ----

proposals_rank_the_windows_everyone_can_attend_test() ->
    Room = answered(<<"a">>, [0, 1, 2, 3], joined([<<"a">>])),
    ?assertEqual([4, 5, 6], [fw_proposal:slot(P) || P <- fw_room:proposals(Room)]).

%% The browser is given instants, never slot numbers to do arithmetic on.
a_proposal_carries_the_utc_instants_of_its_window_test() ->
    Room = answered(<<"a">>, [0, 1, 2, 3], joined([<<"a">>])),
    [Proposal | _Rest] = fw_room:proposals(Room),
    ?assertEqual(4 * ?SLOT_MS, fw_proposal:starts_at(Proposal)),
    ?assertEqual(6 * ?SLOT_MS, fw_proposal:ends_at(Proposal)),
    ?assertEqual(1, fw_proposal:free(Proposal)).

a_room_where_nobody_answered_offers_nothing_test() ->
    ?assertEqual([], fw_room:proposals(joined([<<"a">>]))).

%%% ---- picking ----

the_host_can_pick_a_slot_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, joined([<<"a">>])),
    ?assertEqual(4, fw_room:picked(Picked)).

the_chosen_time_is_a_proposal_with_its_instants_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, joined([<<"a">>])),
    Chosen = fw_room:chosen(Picked),
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
    ?assertEqual({error, expired}, fw_room:pick(4, ?TOKEN, 1000 + ?TTL, room())).

%%% ---- once settled, the room is read-only ----

nobody_may_join_after_a_slot_is_picked_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, room()),
    ?assertEqual({error, finalized}, fw_room:join(<<"a">>, <<"a">>, 1000, Picked)).

nobody_may_answer_again_after_a_slot_is_picked_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, joined([<<"a">>])),
    ?assertEqual({error, finalized}, fw_room:submit(<<"a">>, [0], 1000, Picked)).

the_host_may_not_change_their_mind_test() ->
    {ok, Picked} = fw_room:pick(4, ?TOKEN, 1000, room()),
    ?assertEqual({error, finalized}, fw_room:pick(2, ?TOKEN, 1000, Picked)).

%%% ---- budgets ----

%% How much memory a room costs is what decides how many a machine can hold,
%% and availability dominates it. Held as a set of slot numbers this room was
%% 38 kB; packed it is under 4 kB. A change that quietly reverted the
%% representation would be invisible without this.
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
        ttl_ms => ?TTL
    },
    {ok, Empty} = fw_room:new(Params, 1000),
    BusyAllWeek = lists:seq(0, 671),
    lists:foldl(fun(N, Room) -> crowd(N, BusyAllWeek, Room) end, Empty, lists:seq(1, Count)).

crowd(N, Busy, Room) ->
    Id = <<"attendee-", (integer_to_binary(N))/binary>>,
    {ok, Joined} = fw_room:join(Id, Id, 1000, Room),
    {ok, Answered} = fw_room:submit(Id, Busy, 1000, Joined),
    Answered.

%%% ---- expiry ----

a_room_is_expired_exactly_at_its_deadline_test() ->
    Room = room(),
    ?assertNot(fw_room:is_expired(1000 + ?TTL - 1, Room)),
    ?assert(fw_room:is_expired(1000 + ?TTL, Room)).
