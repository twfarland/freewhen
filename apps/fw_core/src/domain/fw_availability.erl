-module(fw_availability).
-moduledoc """
When one attendee cannot meet: the slots they are busy in.

Everything that asks this module a question asks it in slots. "Is Blue Falcon
busy at 09:15" is a slot, `from_slots/2` takes slots, `busy_slots/1` gives slots
back, and no caller anywhere has to know or care how they are held.

Inside, they are held as one bit per slot. That is invisible from outside and
it is not a premature optimisation: a set of slot numbers costs about 15 kB of
memory per attendee against 84 bytes packed, and multiplied by the attendees in
every live room that difference is what decides how many rooms a machine can
hold. The readable thing is the API; the compact thing is the storage; keeping
them separate is the entire point of an opaque type.

A mask shorter than the grid is busy nowhere beyond its end, which is why
`free/0` needs no grid to answer with.
""".

-export([free/0, from_slots/2, busy_at/2, busy_slots/1, busy_count/1]).
-export_type([t/0, error/0]).

-opaque t() :: bitstring().
-type error() :: bad_slot.

-doc "Busy nowhere, which is where every attendee starts.".
-spec free() -> t().
free() -> <<>>.

-doc "Every slot must be one this grid has, so a stale client cannot claim time that is not there.".
-spec from_slots(term(), fw_grid:t()) -> {ok, t()} | {error, error()}.
from_slots(Slots, Grid) when is_list(Slots) ->
    case lists:all(fun(Slot) -> fw_grid:is_slot(Slot, Grid) end, Slots) of
        true -> {ok, pack(Slots, fw_grid:slots(Grid))};
        false -> {error, bad_slot}
    end;
from_slots(_NotAList, _Grid) ->
    {error, bad_slot}.

-spec busy_at(fw_grid:slot(), t()) -> boolean().
busy_at(Slot, Busy) when is_integer(Slot), Slot >= 0, Slot < bit_size(Busy) ->
    <<_Before:Slot, Bit:1, _After/bitstring>> = Busy,
    Bit =:= 1;
busy_at(_Beyond, _Busy) ->
    false.

-doc "In slot order, so that two equal availabilities always read the same.".
-spec busy_slots(t()) -> [fw_grid:slot()].
busy_slots(Busy) ->
    {Slots, _Count} = lists:foldl(fun collect/2, {[], 0}, [Bit || <<Bit:1>> <= Busy]),
    lists:reverse(Slots).

-spec busy_count(t()) -> non_neg_integer().
busy_count(Busy) -> length(busy_slots(Busy)).

%%% ---- internal ----

collect(1, {Slots, Slot}) -> {[Slot | Slots], Slot + 1};
collect(0, {Slots, Slot}) -> {Slots, Slot + 1}.

pack(Slots, Width) ->
    Busy = sets:from_list(Slots, [{version, 2}]),
    <<<<(bit(sets:is_element(Slot, Busy))):1>> || Slot <- lists:seq(0, Width - 1)>>.

bit(true) -> 1;
bit(false) -> 0.
