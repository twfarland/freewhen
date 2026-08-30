-module(fw_heatmap_tests).

-include_lib("eunit/include/eunit.hrl").

grid() ->
    {ok, Grid} = fw_grid:new(0, 15, 6),
    Grid.

free(Slots) ->
    {ok, Availability} = fw_availability:from_slots(Slots, grid()),
    Availability.

all_week() -> free(lists:seq(0, 5)).

%% Free everywhere except the given slots, which is how a real answer looks.
free_except(Busy) ->
    free([Slot || Slot <- lists:seq(0, 5), not lists:member(Slot, Busy)]).

%%% ---- counts ----

nobody_present_means_nobody_free_test() ->
    ?assertEqual([0, 0, 0, 0, 0, 0], fw_heatmap:counts([], grid())).

someone_free_all_week_is_counted_throughout_test() ->
    ?assertEqual([1, 1, 1, 1, 1, 1], fw_heatmap:counts([all_week()], grid())).

%% Somebody who said nothing is nobody's availability.
someone_who_answered_nothing_counts_nowhere_test() ->
    ?assertEqual([0, 0, 0, 0, 0, 0], fw_heatmap:counts([fw_availability:none()], grid())).

a_slot_somebody_is_busy_in_loses_that_one_count_test() ->
    ?assertEqual([1, 0, 1, 1, 1, 1], fw_heatmap:counts([free_except([1])], grid())).

counts_add_up_across_attendees_test() ->
    People = [free_except([1]), free_except([1, 2]), all_week()],
    ?assertEqual([3, 1, 2, 3, 3, 3], fw_heatmap:counts(People, grid())).

only_the_stretch_somebody_offered_is_counted_test() ->
    ?assertEqual([0, 1, 1, 0, 0, 0], fw_heatmap:counts([free([1, 2])], grid())).

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
        fw_heatmap:best(Windows, 1, 5)
    ).

equally_attended_windows_are_ordered_earliest_first_test() ->
    Windows = [#{start => 5, free => 2}, #{start => 1, free => 2}, #{start => 3, free => 2}],
    ?assertEqual(
        [#{start => 1, free => 2}, #{start => 3, free => 2}, #{start => 5, free => 2}],
        fw_heatmap:best(Windows, 1, 5)
    ).

a_window_nobody_can_attend_is_not_offered_test() ->
    ?assertEqual([], fw_heatmap:best([#{start => 0, free => 0}], 1, 5)).

only_the_limit_is_returned_test() ->
    Windows = [#{start => S, free => 1} || S <- lists:seq(0, 9)],
    ?assertEqual(3, length(fw_heatmap:best(Windows, 1, 3))).

%% Five suggestions that are five consecutive half hours of one morning are
%% one suggestion. The best of a cluster is kept and the rest of it dropped.
suggestions_nearer_than_the_separation_are_one_suggestion_test() ->
    Windows = [#{start => S, free => 2} || S <- lists:seq(0, 20)],
    ?assertEqual(
        [#{start => 0, free => 2}, #{start => 8, free => 2}, #{start => 16, free => 2}],
        fw_heatmap:best(Windows, 8, 5)
    ).

%% Separation must not cost the best answer: a busier window further out still
%% wins the cluster it belongs to.
the_best_of_a_cluster_is_the_one_kept_test() ->
    Windows = [#{start => 0, free => 1}, #{start => 2, free => 4}, #{start => 12, free => 2}],
    ?assertEqual(
        [#{start => 2, free => 4}, #{start => 12, free => 2}],
        fw_heatmap:best(Windows, 8, 5)
    ).
