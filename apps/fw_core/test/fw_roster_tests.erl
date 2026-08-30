-module(fw_roster_tests).

-include_lib("eunit/include/eunit.hrl").

grid() ->
    {ok, Grid} = fw_grid:new(0, 15, 8),
    Grid.

availability(Slots) ->
    {ok, Availability} = fw_availability:from_slots(Slots, grid()),
    Availability.

added(Ids, Roster) -> lists:foldl(fun add/2, Roster, Ids).

add(Id, Roster) ->
    {ok, Next} = fw_roster:add(Id, Id, 4, Roster),
    Next.

answered(Id, Slots, Roster) ->
    {ok, Next} = fw_roster:answer(Id, availability(Slots), Roster),
    Next.

aliases(Roster) -> [fw_attendee:alias(A) || A <- fw_roster:list(Roster)].

%%% ---- admitting ----

an_empty_roster_has_nobody_in_it_test() ->
    ?assertEqual([], fw_roster:list(fw_roster:empty())).

members_are_listed_in_the_order_they_joined_test() ->
    Roster = added([<<"c">>, <<"a">>, <<"b">>], fw_roster:empty()),
    ?assertEqual([<<"c">>, <<"a">>, <<"b">>], aliases(Roster)).

%% Answering must not move somebody up or down the list under the reader.
answering_does_not_reorder_the_list_test() ->
    Roster = answered(<<"a">>, [0], added([<<"c">>, <<"a">>, <<"b">>], fw_roster:empty())),
    ?assertEqual([<<"c">>, <<"a">>, <<"b">>], aliases(Roster)).

the_same_id_cannot_be_added_twice_test() ->
    Roster = added([<<"a">>], fw_roster:empty()),
    ?assertEqual({error, duplicate}, fw_roster:add(<<"a">>, <<"a">>, 4, Roster)).

a_full_roster_refuses_the_next_arrival_test() ->
    Roster = added([<<"a">>, <<"b">>], fw_roster:empty()),
    ?assertEqual({error, full}, fw_roster:add(<<"c">>, <<"c">>, 2, Roster)).

a_bad_alias_is_refused_test() ->
    ?assertEqual({error, bad_alias}, fw_roster:add(<<"a">>, <<>>, 4, fw_roster:empty())).

%%% ---- answering ----

a_stranger_cannot_answer_test() ->
    ?assertEqual(
        {error, unknown_attendee},
        fw_roster:answer(<<"z">>, availability([0]), added([<<"a">>], fw_roster:empty()))
    ).

answering_again_replaces_the_last_answer_test() ->
    Roster = answered(<<"a">>, [3], answered(<<"a">>, [0], added([<<"a">>], fw_roster:empty()))),
    [Attendee] = fw_roster:list(Roster),
    ?assert(fw_availability:free_at(3, fw_attendee:availability(Attendee))),
    ?assertNot(fw_availability:free_at(0, fw_attendee:availability(Attendee))).

%%% ---- the gate ----

%% A time cannot be chosen for nobody, so an empty roster is not "everybody
%% answered" however true that reads.
nobody_at_all_is_not_everybody_answered_test() ->
    ?assertNot(fw_roster:everyone_answered(fw_roster:empty())).

one_silent_member_holds_the_gate_shut_test() ->
    Roster = answered(<<"a">>, [0], added([<<"a">>, <<"b">>], fw_roster:empty())),
    ?assertNot(fw_roster:everyone_answered(Roster)).

everybody_answered_opens_the_gate_test() ->
    Roster = answered(<<"b">>, [0], answered(<<"a">>, [0], added([<<"a">>, <<"b">>], fw_roster:empty()))),
    ?assert(fw_roster:everyone_answered(Roster)).

%% Saying "no time at all works for me" is an answer, not silence.
an_answer_of_no_free_time_opens_the_gate_test() ->
    Roster = answered(<<"a">>, [], added([<<"a">>], fw_roster:empty())),
    ?assert(fw_roster:everyone_answered(Roster)).

%%% ---- going ahead without them ----

the_silent_are_forgotten_and_the_rest_are_kept_test() ->
    Roster = answered(<<"a">>, [0], added([<<"a">>, <<"b">>, <<"c">>], fw_roster:empty())),
    Kept = answered(<<"c">>, [0], Roster),
    ?assertEqual([<<"a">>, <<"c">>], aliases(fw_roster:without_silent(Kept))).

excluding_the_silent_opens_the_gate_test() ->
    Roster = answered(<<"a">>, [0], added([<<"a">>, <<"b">>], fw_roster:empty())),
    ?assert(fw_roster:everyone_answered(fw_roster:without_silent(Roster))).

%% Excluding everybody would leave a roster that can never choose a time, which
%% is the same shut gate rather than an open one.
excluding_when_nobody_answered_leaves_nobody_test() ->
    Roster = fw_roster:without_silent(added([<<"a">>], fw_roster:empty())),
    ?assertEqual([], fw_roster:list(Roster)),
    ?assertNot(fw_roster:everyone_answered(Roster)).
