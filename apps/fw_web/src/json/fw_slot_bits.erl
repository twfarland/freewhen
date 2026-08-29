-module(fw_slot_bits).
-moduledoc """
Packed bits on the wire, slot numbers in the domain.

A client sends its free time as one bit per slot, base64url, because a week at
quarter-hour resolution is eighty-four bytes that way and two and a half
kilobytes as a list of numbers. This unpacks it into the slots the domain
speaks in.

`fw_availability` then merges those slots back into intervals, which is a round
trip and a deliberate one: it costs microseconds, and the alternative is a
domain function shaped like a bitstring, leaking a transport decision into the
only vocabulary the rules are written in. Do not "optimise" it by passing bits
inward.
""".

-export([decode/1]).

-doc "Slots whose bit is set. A 1 means free, matching what the client paints.".
-spec decode(binary()) -> {ok, [fw_grid:slot()]} | {error, binary()}.
decode(Base64) ->
    try base64:decode(Base64, #{mode => urlsafe, padding => false}) of
        Bytes -> {ok, set_slots(Bytes)}
    catch
        error:_ -> {error, <<"not base64url">>}
    end.

%%% ---- internal ----

%% Bits are most-significant first within each byte. Slots past the end of the
%% grid are rejected by the domain, so the spare bits of the final byte need no
%% special case here.
set_slots(Bytes) ->
    {Slots, _Next} = lists:foldl(fun collect/2, {[], 0}, [Bit || <<Bit:1>> <= Bytes]),
    lists:reverse(Slots).

collect(1, {Slots, Slot}) -> {[Slot | Slots], Slot + 1};
collect(0, {Slots, Slot}) -> {Slots, Slot + 1}.
