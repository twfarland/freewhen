-module(fw_grid_tests).

-include_lib("eunit/include/eunit.hrl").

grid() ->
    {ok, Grid} = fw_grid:new(1_700_000_000_000, 15, 96),
    Grid.

a_grid_reports_what_it_was_built_with_test() ->
    Grid = grid(),
    ?assertEqual(1_700_000_000_000, fw_grid:starts_at(Grid)),
    ?assertEqual(15, fw_grid:slot_minutes(Grid)),
    ?assertEqual(96, fw_grid:slots(Grid)).

a_negative_start_is_rejected_test() ->
    ?assertEqual({error, bad_start}, fw_grid:new(-1, 15, 96)).

a_non_integer_start_is_rejected_test() ->
    ?assertEqual({error, bad_start}, fw_grid:new(<<"soon">>, 15, 96)).

a_zero_length_slot_is_rejected_test() ->
    ?assertEqual({error, bad_slot_minutes}, fw_grid:new(0, 0, 96)).

a_slot_longer_than_a_day_is_rejected_test() ->
    ?assertEqual({error, bad_slot_minutes}, fw_grid:new(0, 1441, 96)).

an_empty_grid_is_rejected_test() ->
    ?assertEqual({error, bad_slots}, fw_grid:new(0, 15, 0)).

a_grid_past_a_week_of_five_minute_slots_is_rejected_test() ->
    ?assertEqual({error, bad_slots}, fw_grid:new(0, 15, 2017)),
    ?assertMatch({ok, _}, fw_grid:new(0, 15, 2016)).

slot_indices_run_from_zero_to_one_below_the_count_test() ->
    Grid = grid(),
    ?assert(fw_grid:is_slot(0, Grid)),
    ?assert(fw_grid:is_slot(95, Grid)),
    ?assertNot(fw_grid:is_slot(96, Grid)),
    ?assertNot(fw_grid:is_slot(-1, Grid)).

a_slot_that_is_not_an_integer_is_not_a_slot_test() ->
    ?assertNot(fw_grid:is_slot(<<"3">>, grid())),
    ?assertNot(fw_grid:is_slot(1.5, grid())).

a_window_must_end_inside_the_grid_test() ->
    Grid = grid(),
    ?assert(fw_grid:is_window(94, 2, Grid)),
    ?assertNot(fw_grid:is_window(95, 2, Grid)).

a_window_of_no_slots_is_not_a_window_test() ->
    ?assertNot(fw_grid:is_window(0, 0, grid())).

%%% ---- instants ----

the_first_slot_starts_when_the_grid_does_test() ->
    ?assertEqual(1_700_000_000_000, fw_grid:slot_start(0, grid())).

each_slot_is_one_slot_length_after_the_last_test() ->
    ?assertEqual(1_700_000_000_000 + 4 * 15 * 60_000, fw_grid:slot_start(4, grid())).

a_window_runs_from_its_first_slot_to_the_end_of_its_last_test() ->
    ?assertEqual(
        {1_700_000_000_000 + 4 * 900_000, 1_700_000_000_000 + 6 * 900_000},
        fw_grid:window(4, 2, grid())
    ).

a_window_may_end_exactly_at_the_end_of_the_grid_test() ->
    ?assertEqual(
        {1_700_000_000_000 + 94 * 900_000, 1_700_000_000_000 + 96 * 900_000},
        fw_grid:window(94, 2, grid())
    ).
