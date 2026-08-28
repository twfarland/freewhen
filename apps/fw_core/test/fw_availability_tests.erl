-module(fw_availability_tests).

-include_lib("eunit/include/eunit.hrl").

grid() ->
    {ok, Grid} = fw_grid:new(0, 15, 8),
    Grid.

busy(Slots) ->
    {ok, Availability} = fw_availability:from_slots(Slots, grid()),
    Availability.

a_new_attendee_is_busy_nowhere_test() ->
    ?assertEqual([], fw_availability:busy_slots(fw_availability:free())),
    ?assertEqual(0, fw_availability:busy_count(fw_availability:free())).

busy_slots_are_remembered_test() ->
    ?assertEqual([1, 2, 7], fw_availability:busy_slots(busy([1, 2, 7]))).

busy_slots_come_back_in_slot_order_test() ->
    ?assertEqual([1, 2, 7], fw_availability:busy_slots(busy([7, 1, 2]))).

repeating_a_slot_says_nothing_new_test() ->
    ?assertEqual([1, 2], fw_availability:busy_slots(busy([2, 1, 2, 1]))).

being_busy_is_a_question_about_one_slot_test() ->
    Busy = busy([1, 2]),
    ?assertNot(fw_availability:busy_at(0, Busy)),
    ?assert(fw_availability:busy_at(1, Busy)),
    ?assert(fw_availability:busy_at(2, Busy)),
    ?assertNot(fw_availability:busy_at(3, Busy)).

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

busy_all_week_is_a_valid_answer_test() ->
    Every = lists:seq(0, 7),
    ?assertEqual(8, fw_availability:busy_count(busy(Every))).
