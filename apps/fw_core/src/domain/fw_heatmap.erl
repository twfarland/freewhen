-module(fw_heatmap).
-moduledoc """
How many attendees are free in each slot, and which windows are worth meeting
in.

The aggregate is the *only* availability the server publishes. A count of three
says three people are free at ten; it never says which three, and no sequence
of counts runs backwards to one person's diary unless they are the only
attendee — which is why a room of one has nothing to reveal.
""".

-export([counts/2, windows/3, best/3, free_across/3]).
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
    [#{start => Start, free => free_across(Counts, Start, Length)} || Start <- lists:seq(0, Last)].

-doc """
The most attended windows, best first, ties broken by starting earliest.

Windows nobody can attend are dropped rather than ranked last: offering a slot
with zero attendees is worse than offering nothing.

Windows closer together than `Apart` slots are the same offer wearing a
different hat — take the best of them and move on. Without this, the five
suggestions for a half-hour meeting were five consecutive half hours of the
same morning, which is one suggestion.
""".
-spec best([window()], pos_integer(), pos_integer()) -> [window()].
best(Windows, Apart, Limit) ->
    Attended = [Window || #{free := Free} = Window <- Windows, Free > 0],
    spread(lists:sort(fun is_better/2, Attended), Apart, Limit, []).

-doc """
How many are free for **all** of a window: the lowest count across it, because
a meeting needs people present the whole time rather than for some of it.
""".
-spec free_across(counts(), fw_grid:slot(), pos_integer()) -> non_neg_integer().
free_across(Counts, Start, Length) ->
    lists:min(lists:sublist(Counts, Start + 1, Length)).

%%% ---- internal ----

spread(_Windows, _Apart, 0, Taken) ->
    lists:reverse(Taken);
spread([], _Apart, _Limit, Taken) ->
    lists:reverse(Taken);
spread([#{start := Start} = Window | Rest], Apart, Limit, Taken) ->
    case [near || #{start := Other} <- Taken, abs(Start - Other) < Apart] of
        [] -> spread(Rest, Apart, Limit - 1, [Window | Taken]);
        [_Near | _More] -> spread(Rest, Apart, Limit, Taken)
    end.

free_at(Slot, Availabilities) ->
    length([free || Free <- Availabilities, fw_availability:free_at(Slot, Free)]).

is_better(#{free := Free, start := Start}, #{free := Other, start := OtherStart}) ->
    Free > Other orelse (Free =:= Other andalso Start =< OtherStart).
