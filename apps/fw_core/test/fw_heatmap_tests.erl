-module(fw_heatmap_tests).

-include_lib("eunit/include/eunit.hrl").

grid() ->
    {ok, Grid} = fw_grid:new(0, 15, 6),
    Grid.

busy(Slots) ->
    {ok, Availability} = fw_availability:from_slots(Slots, grid()),
    Availability.

%%% ---- counts ----

nobody_present_means_nobody_free_test() ->
    ?assertEqual([0, 0, 0, 0, 0, 0], fw_heatmap:counts([], grid())).

someone_busy_nowhere_is_free_throughout_test() ->
    ?assertEqual([1, 1, 1, 1, 1, 1], fw_heatmap:counts([fw_availability:free()], grid())).

a_busy_slot_is_subtracted_from_that_slot_only_test() ->
    ?assertEqual([1, 0, 1, 1, 1, 1], fw_heatmap:counts([busy([1])], grid())).

counts_add_up_across_attendees_test() ->
    People = [busy([1]), busy([1, 2]), fw_availability:free()],
    ?assertEqual([3, 1, 2, 3, 3, 3], fw_heatmap:counts(People, grid())).

%%% ---- windows ----

a_window_scores_the_worst_slot_it_covers_test() ->
    ?assertEqual(
        [
            #{start => 0, free => 1},
            #{start => 1, free => 1},
            #{start => 2, free => 3},
            #{start => 3, free => 3},
            #{start => 4, free => 3}
        ],
        fw_heatmap:windows([3, 1, 3, 3, 3, 3], 2, grid())
    ).

a_window_the_length_of_the_grid_is_the_only_window_test() ->
    ?assertEqual([#{start => 0, free => 1}], fw_heatmap:windows([3, 1, 3, 3, 3, 3], 6, grid())).

a_window_longer_than_the_grid_yields_nothing_test() ->
    ?assertEqual([], fw_heatmap:windows([3, 1, 3, 3, 3, 3], 7, grid())).

%%% ---- ranking ----

the_busiest_window_comes_first_test() ->
    Windows = [#{start => 0, free => 1}, #{start => 1, free => 3}, #{start => 2, free => 2}],
    ?assertEqual(
        [#{start => 1, free => 3}, #{start => 2, free => 2}, #{start => 0, free => 1}],
        fw_heatmap:best(Windows, 5)
    ).

equally_attended_windows_are_ordered_earliest_first_test() ->
    Windows = [#{start => 5, free => 2}, #{start => 1, free => 2}, #{start => 3, free => 2}],
    ?assertEqual(
        [#{start => 1, free => 2}, #{start => 3, free => 2}, #{start => 5, free => 2}],
        fw_heatmap:best(Windows, 5)
    ).

a_window_nobody_can_attend_is_not_offered_test() ->
    ?assertEqual([], fw_heatmap:best([#{start => 0, free => 0}], 5)).

only_the_limit_is_returned_test() ->
    Windows = [#{start => S, free => 1} || S <- lists:seq(0, 9)],
    ?assertEqual(3, length(fw_heatmap:best(Windows, 3))).
