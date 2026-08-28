-module(fw_bucket).
-moduledoc """
A token bucket, as a value.

Pure: it holds no timer and reads no clock, so refill is computed from the
elapsed time handed to `take/3`. That makes every rate-limiting rule testable
by arithmetic rather than by waiting.

Costs are in whole tokens and `refill_per_sec` may be fractional, which is how
"ten rooms, then one a minute" is expressed without a scheduler. The balance is
always a float, so that a partial refill never turns one bucket's arithmetic
into a different type from another's.
""".

-export([new/2, take/3, tokens/1]).
-export_type([t/0, config/0]).

-type config() :: #{
    capacity := pos_integer(),
    refill_per_sec := number(),
    cost := pos_integer()
}.

-opaque t() :: #{
    tokens := float(),
    capacity := pos_integer(),
    refill_per_sec := number(),
    cost := pos_integer(),
    at := fw_grid:millisecond()
}.

-doc "A full bucket. New arrivals get their whole allowance immediately.".
-spec new(config(), fw_grid:millisecond()) -> t().
new(#{capacity := Capacity, refill_per_sec := Rate, cost := Cost}, Now) ->
    #{
        tokens => float(Capacity),
        capacity => Capacity,
        refill_per_sec => Rate,
        cost => Cost,
        at => Now
    }.

-doc """
Refill for the time that has passed, then spend one request's worth.

Returns the bucket either way, because a denial still advances the clock and a
caller that drops the denied bucket would hand the next request a full one.
""".
-spec take(pos_integer(), fw_grid:millisecond(), t()) -> {ok, t()} | {denied, t()}.
take(Cost, Now, Bucket) ->
    #{tokens := Tokens} = Filled = refill(Now, Bucket),
    case Tokens >= Cost of
        true -> {ok, Filled#{tokens := Tokens - Cost}};
        false -> {denied, Filled}
    end.

-spec tokens(t()) -> float().
tokens(#{tokens := Tokens}) -> Tokens.

%%% ---- internal ----

%% A clock that goes backwards must not mint tokens, hence max(0, Elapsed).
refill(Now, #{tokens := Tokens, capacity := Capacity, refill_per_sec := Rate, at := At} = Bucket) ->
    Elapsed = max(0, Now - At),
    Gained = Elapsed * Rate / 1000,
    Bucket#{tokens := min(float(Capacity), Tokens + Gained), at := Now}.
