-module(fw_bucket_tests).

-include_lib("eunit/include/eunit.hrl").

config() -> #{capacity => 10, refill_per_sec => 1, cost => 1}.

bucket() -> fw_bucket:new(config(), 0).

drain(Bucket, 0) -> Bucket;
drain(Bucket, N) ->
    {ok, Spent} = fw_bucket:take(1, 0, Bucket),
    drain(Spent, N - 1).

a_new_bucket_is_full_test() ->
    ?assertEqual(10.0, fw_bucket:tokens(bucket())).

taking_spends_one_cost_test() ->
    {ok, Spent} = fw_bucket:take(1, 0, bucket()),
    ?assertEqual(9.0, fw_bucket:tokens(Spent)).

a_bucket_can_be_spent_to_exactly_empty_test() ->
    ?assertEqual(0.0, fw_bucket:tokens(drain(bucket(), 10))).

an_empty_bucket_denies_test() ->
    ?assertMatch({denied, _}, fw_bucket:take(1, 0, drain(bucket(), 10))).

a_denial_still_returns_the_bucket_test() ->
    {denied, Denied} = fw_bucket:take(1, 0, drain(bucket(), 10)),
    ?assertEqual(0.0, fw_bucket:tokens(Denied)).

a_cost_larger_than_the_balance_is_denied_without_partial_spend_test() ->
    Bucket = drain(bucket(), 8),
    {denied, Denied} = fw_bucket:take(5, 0, Bucket),
    ?assertEqual(2.0, fw_bucket:tokens(Denied)).

one_second_restores_one_token_test() ->
    {ok, Refilled} = fw_bucket:take(1, 1000, drain(bucket(), 10)),
    ?assertEqual(0.0, fw_bucket:tokens(Refilled)).

refill_is_proportional_to_elapsed_time_test() ->
    {denied, Partial} = fw_bucket:take(1, 500, drain(bucket(), 10)),
    ?assertEqual(0.5, fw_bucket:tokens(Partial)).

refill_stops_at_capacity_test() ->
    {ok, Spent} = fw_bucket:take(1, 3_600_000, drain(bucket(), 10)),
    ?assertEqual(9.0, fw_bucket:tokens(Spent)).

%% A clock that jumps backwards — a suspended laptop, an NTP correction — must
%% not be a way to mint allowance.
time_going_backwards_grants_nothing_test() ->
    Later = fw_bucket:new(config(), 10_000),
    {denied, Denied} = fw_bucket:take(1, 0, drain(Later, 10)),
    ?assertEqual(0.0, fw_bucket:tokens(Denied)).

a_fractional_rate_expresses_a_slow_refill_test() ->
    Slow = fw_bucket:new(#{capacity => 2, refill_per_sec => 0.1, cost => 1}, 0),
    {denied, _} = fw_bucket:take(1, 5_000, drain2(Slow)),
    {ok, Refilled} = fw_bucket:take(1, 10_000, drain2(Slow)),
    ?assertEqual(0.0, fw_bucket:tokens(Refilled)).

drain2(Bucket) ->
    {ok, One} = fw_bucket:take(1, 0, Bucket),
    {ok, Two} = fw_bucket:take(1, 0, One),
    Two.
