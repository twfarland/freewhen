-module(fw_availability_tests).

-include_lib("eunit/include/eunit.hrl").

grid() ->
    {ok, Grid} = fw_grid:new(0, 15, 8),
    Grid.

free(Slots) ->
    {ok, Availability} = fw_availability:from_slots(Slots, grid()),
    Availability.

%%% ---- the safe default ----

%% Anything unsaid is not free. A scheduler that invents availability produces
%% meetings nobody can attend.
someone_who_has_said_nothing_is_free_nowhere_test() ->
    ?assertEqual([], fw_availability:free_slots(fw_availability:none())),
    ?assertEqual(0, fw_availability:free_count(fw_availability:none())),
    ?assertNot(fw_availability:free_at(0, fw_availability:none())).

a_slot_beyond_what_was_answered_is_not_free_test() ->
    ?assertNot(fw_availability:free_at(7, free([0, 1]))),
    ?assertNot(fw_availability:free_at(99, free([0, 1]))).

%%% ---- stretches ----

consecutive_slots_become_one_stretch_test() ->
    ?assertEqual([{1, 4}], fw_availability:free_intervals(free([1, 2, 3]))).

a_gap_starts_a_new_stretch_test() ->
    ?assertEqual([{1, 3}, {5, 7}], fw_availability:free_intervals(free([1, 2, 5, 6]))).

a_lone_slot_is_a_stretch_of_one_test() ->
    ?assertEqual([{4, 5}], fw_availability:free_intervals(free([4]))).

stretches_come_back_in_order_however_they_arrived_test() ->
    ?assertEqual([{1, 3}, {5, 7}], fw_availability:free_intervals(free([6, 1, 5, 2]))).

repeating_a_slot_says_nothing_new_test() ->
    ?assertEqual([{1, 3}], fw_availability:free_intervals(free([2, 1, 2, 1]))).

free_all_week_is_a_single_stretch_test() ->
    ?assertEqual([{0, 8}], fw_availability:free_intervals(free(lists:seq(0, 7)))).

%%% ---- slots ----

being_free_is_a_question_about_one_slot_test() ->
    Free = free([1, 2]),
    ?assertNot(fw_availability:free_at(0, Free)),
    ?assert(fw_availability:free_at(1, Free)),
    ?assert(fw_availability:free_at(2, Free)),
    ?assertNot(fw_availability:free_at(3, Free)).

free_slots_are_the_slots_that_went_in_test() ->
    ?assertEqual([1, 2, 5, 6], fw_availability:free_slots(free([5, 2, 6, 1]))).

free_count_is_how_much_time_not_how_many_stretches_test() ->
    ?assertEqual(4, fw_availability:free_count(free([1, 2, 5, 6]))).

%%% ---- refusals ----

a_slot_off_the_end_of_the_grid_is_rejected_test() ->
    ?assertEqual({error, bad_slot}, fw_availability:from_slots([8], grid())).

a_negative_slot_is_rejected_test() ->
    ?assertEqual({error, bad_slot}, fw_availability:from_slots([-1], grid())).

a_slot_that_is_not_an_integer_is_rejected_test() ->
    ?assertEqual({error, bad_slot}, fw_availability:from_slots([<<"3">>], grid())),
    ?assertEqual({error, bad_slot}, fw_availability:from_slots([1.5], grid())).

something_that_is_not_a_list_of_slots_is_rejected_test() ->
    ?assertEqual({error, bad_slot}, fw_availability:from_slots(<<0, 1>>, grid())),
    ?assertEqual({error, bad_slot}, fw_availability:from_slots(undefined, grid())).

%% Intervals cost what the caller sends, so something has to bound it. A week
%% painted every other slot is not an answer a person means, and it is the
%% shape a crafted one would take.
an_answer_too_fragmented_to_be_meant_is_rejected_test() ->
    {ok, Week} = fw_grid:new(0, 15, 672),
    Alternating = [Slot || Slot <- lists:seq(0, 671), Slot rem 2 =:= 0],
    ?assertEqual({error, too_fragmented}, fw_availability:from_slots(Alternating, Week)),
    Reasonable = lists:seq(0, 63),
    ?assertMatch({ok, _}, fw_availability:from_slots(Reasonable, Week)).

sixty_four_separate_stretches_are_still_accepted_test() ->
    {ok, Week} = fw_grid:new(0, 15, 672),
    Stretches = [Slot || Slot <- lists:seq(0, 671), (Slot div 2) rem 2 =:= 0, Slot < 256],
    {ok, Availability} = fw_availability:from_slots(Stretches, Week),
    ?assertEqual(64, length(fw_availability:free_intervals(Availability))).
