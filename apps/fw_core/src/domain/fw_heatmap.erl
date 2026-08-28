-module(fw_heatmap).
-moduledoc """
How many attendees are free in each slot, and which windows are worth meeting
in.

The aggregate is the *only* availability the server ever publishes. A count of
three says three people are free at ten o'clock; it does not say which three,
and no sequence of counts can be run backwards to a particular person's diary
unless they are the only attendee — which is why a room with one attendee has
nothing to reveal.
""".

-export([counts/2, windows/3, best/2]).
-export_type([counts/0, window/0]).

-type counts() :: [non_neg_integer()].
-type window() :: #{start := fw_grid:slot(), free := non_neg_integer()}.

-doc "How many of these people are free in each slot, in slot order.".
-spec counts([fw_availability:t()], fw_grid:t()) -> counts().
counts(Availabilities, Grid) ->
    [free_at(Slot, Availabilities) || Slot <- lists:seq(0, fw_grid:slots(Grid) - 1)].

-doc """
Every window of `Length` consecutive slots, scored by the number of attendees
free for **all** of it — the lowest count across the window, because a meeting
needs people present the whole time.
""".
-spec windows(counts(), pos_integer(), fw_grid:t()) -> [window()].
windows(Counts, Length, Grid) ->
    Last = fw_grid:slots(Grid) - Length,
    [#{start => Start, free => lowest(Counts, Start, Length)} || Start <- lists:seq(0, Last)].

-doc """
The most attended windows, best first, ties broken by starting earliest.

Windows nobody can attend are dropped rather than ranked last: offering a slot
with zero attendees is worse than offering nothing.
""".
-spec best([window()], pos_integer()) -> [window()].
best(Windows, Limit) ->
    Attended = [Window || #{free := Free} = Window <- Windows, Free > 0],
    lists:sublist(lists:sort(fun is_better/2, Attended), Limit).

%%% ---- internal ----

free_at(Slot, Availabilities) ->
    length([free || Busy <- Availabilities, not fw_availability:busy_at(Slot, Busy)]).

lowest(Counts, Start, Length) ->
    lists:min(lists:sublist(Counts, Start + 1, Length)).

is_better(#{free := Free, start := Start}, #{free := Other, start := OtherStart}) ->
    Free > Other orelse (Free =:= Other andalso Start =< OtherStart).
