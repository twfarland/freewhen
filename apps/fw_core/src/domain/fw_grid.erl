-module(fw_grid).
-moduledoc """
The time grid a room is scheduled on: a start instant, a slot length, and a
number of slots. Every other part of the domain speaks in slot indices.

Instants are UTC milliseconds, always, everywhere. Nothing here knows where
anybody is: there is exactly one canonical answer to when a slot is, and each
browser converts it against its own locale.
""".

-export([new/3, starts_at/1, slot_minutes/1, slots/1]).
-export([is_slot/2, is_window/3, slot_start/2, window/3]).
-export_type([t/0, slot/0, millisecond/0, error/0]).

-type millisecond() :: non_neg_integer().
-type slot() :: non_neg_integer().
-type error() :: bad_start | bad_slot_minutes | bad_slots.

-opaque t() :: #{
    starts_at := millisecond(),
    slot_minutes := pos_integer(),
    slots := pos_integer()
}.

%% One week at five-minute resolution. The ceiling exists because a room holds
%% one slot per attendee per bit, and an unbounded grid is an unbounded room.
-define(MAX_SLOTS, 2016).
-define(MAX_SLOT_MINUTES, 1440).

-spec new(millisecond(), pos_integer(), pos_integer()) -> {ok, t()} | {error, error()}.
new(StartsAt, SlotMinutes, Slots) ->
    case validate(StartsAt, SlotMinutes, Slots) of
        ok ->
            {ok, #{starts_at => StartsAt, slot_minutes => SlotMinutes, slots => Slots}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec starts_at(t()) -> millisecond().
starts_at(#{starts_at := StartsAt}) -> StartsAt.

-spec slot_minutes(t()) -> pos_integer().
slot_minutes(#{slot_minutes := SlotMinutes}) -> SlotMinutes.

-spec slots(t()) -> pos_integer().
slots(#{slots := Slots}) -> Slots.

-spec is_slot(term(), t()) -> boolean().
is_slot(Slot, #{slots := Slots}) ->
    is_integer(Slot) andalso Slot >= 0 andalso Slot < Slots.

-doc "Whether `Length` slots starting at `Start` fit inside the grid.".
-spec is_window(term(), term(), t()) -> boolean().
is_window(Start, Length, #{slots := Slots}) ->
    is_integer(Start) andalso is_integer(Length) andalso
        Start >= 0 andalso Length >= 1 andalso Start + Length =< Slots.

-doc "The UTC instant a slot begins.".
-spec slot_start(slot(), t()) -> millisecond().
slot_start(Slot, #{starts_at := StartsAt, slot_minutes := SlotMinutes}) when
    is_integer(Slot), is_integer(StartsAt), is_integer(SlotMinutes)
->
    StartsAt + Slot * SlotMinutes * 60_000.

-doc """
The UTC instants a window begins and ends.

Published with every proposal so that a browser never has to do time
arithmetic — it formats what it is given and nothing more.
""".
-spec window(slot(), pos_integer(), t()) -> {millisecond(), millisecond()}.
window(Start, Length, Grid) ->
    {slot_start(Start, Grid), slot_start(Start + Length, Grid)}.

%%% ---- internal ----

validate(StartsAt, _SlotMinutes, _Slots) when not is_integer(StartsAt); StartsAt < 0 ->
    {error, bad_start};
validate(_StartsAt, SlotMinutes, _Slots) when
    not is_integer(SlotMinutes); SlotMinutes < 1; SlotMinutes > ?MAX_SLOT_MINUTES
->
    {error, bad_slot_minutes};
validate(_StartsAt, _SlotMinutes, Slots) when
    not is_integer(Slots); Slots < 1; Slots > ?MAX_SLOTS
->
    {error, bad_slots};
validate(_StartsAt, _SlotMinutes, _Slots) ->
    ok.
