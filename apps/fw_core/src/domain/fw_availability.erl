-module(fw_availability).
-moduledoc """
When one attendee can meet: the stretches of time they are free. Half-open
`{From, Until}`, sorted and merged, so two equal availabilities are equal
terms.

Free rather than busy because it fails the right way: anything this module has
not been told about is *not* free — an empty availability, a slot past the end
of an answer, a person who has said nothing. As busy-time those same gaps read
as free, and a scheduler that invents availability produces meetings nobody can
attend.

Intervals rather than slots because an ordinary working week is five stretches
where a set of slot numbers is a hundred and sixty entries at sixty times the
memory.
""".

-export([none/0, from_slots/2, free_at/2, free_slots/1, free_intervals/1, free_count/1]).
-export_type([t/0, interval/0, error/0]).

-type interval() :: {fw_grid:slot(), fw_grid:slot()}.
-opaque t() :: [interval()].
-type error() :: bad_slot | too_fragmented.

%% Nine separate free stretches a day is already unlike any real week, and the
%% cap is what keeps memory bounded against a crafted answer: intervals cost
%% what the caller sends, so something has to say how much that may be.
-define(MAX_INTERVALS, 64).

-doc "Free nowhere, which is the safe thing to assume about anyone who has not said.".
-spec none() -> t().
none() -> [].

-doc """
Build from the slots someone says they are free in.

Every slot must be one this grid has, so a stale client cannot claim time that
is not there, and the result must not be more fragmented than a person could
plausibly mean.
""".
-spec from_slots(term(), fw_grid:t()) -> {ok, t()} | {error, error()}.
from_slots(Slots, Grid) when is_list(Slots) ->
    case lists:all(fun(Slot) -> fw_grid:is_slot(Slot, Grid) end, Slots) of
        true -> bounded(merge(lists:usort(Slots)));
        false -> {error, bad_slot}
    end;
from_slots(_NotAList, _Grid) ->
    {error, bad_slot}.

-spec free_at(fw_grid:slot(), t()) -> boolean().
free_at(Slot, Intervals) ->
    lists:any(fun({From, Until}) -> Slot >= From andalso Slot < Until end, Intervals).

-doc "Every free slot, in order.".
-spec free_slots(t()) -> [fw_grid:slot()].
free_slots(Intervals) ->
    lists:append([lists:seq(From, Until - 1) || {From, Until} <- Intervals]).

-doc "The stretches themselves, which is how this is meant to be read.".
-spec free_intervals(t()) -> [interval()].
free_intervals(Intervals) -> Intervals.

-spec free_count(t()) -> non_neg_integer().
free_count(Intervals) -> lists:foldl(fun add_length/2, 0, Intervals).

%%% ---- internal ----

add_length({From, Until}, Total) when is_integer(From), is_integer(Until), is_integer(Total) ->
    Total + Until - From.

bounded(Intervals) when length(Intervals) =< ?MAX_INTERVALS -> {ok, Intervals};
bounded(_TooMany) -> {error, too_fragmented}.

%% Consecutive slots are one stretch. The input is sorted and unique, so a slot
%% that continues the run extends it and anything else starts a new one.
merge([]) -> [];
merge([First | Rest]) -> merge(Rest, First, First + 1, []).

merge([], From, Until, Done) ->
    lists:reverse([{From, Until} | Done]);
merge([Until | Rest], From, Until, Done) ->
    merge(Rest, From, Until + 1, Done);
merge([Slot | Rest], From, Until, Done) ->
    merge(Rest, Slot, Slot + 1, [{From, Until} | Done]).
