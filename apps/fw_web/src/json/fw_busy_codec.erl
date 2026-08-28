-module(fw_busy_codec).
-moduledoc """
Packed bits on the wire, slot numbers in the domain.

The domain holds availability as a set of slots because that is what it means.
The wire packs the same fact one bit per slot, base64url, because a week at
quarter-hour resolution is eighty-four bytes that way and about two and a half
kilobytes as a list of numbers.

Both representations are correct; they are correct about different things.
Keeping the translation in one small module at the edge is what lets the domain
stay readable without making the transport wasteful.
""".

-export([decode/1]).

-spec decode(binary()) -> {ok, [fw_grid:slot()]} | {error, binary()}.
decode(Base64) ->
    try base64:decode(Base64, #{mode => urlsafe, padding => false}) of
        Bytes -> {ok, busy_slots(Bytes)}
    catch
        error:_ -> {error, <<"busy is not base64url">>}
    end.

%%% ---- internal ----

%% Bits are most-significant first within each byte. Slots past the end of the
%% grid are rejected by the domain, so the spare bits of the final byte need no
%% special case here.
busy_slots(Bytes) ->
    {Busy, _Slot} = lists:foldl(fun collect/2, {[], 0}, [Bit || <<Bit:1>> <= Bytes]),
    lists:reverse(Busy).

collect(1, {Busy, Slot}) -> {[Slot | Busy], Slot + 1};
collect(0, {Busy, Slot}) -> {Busy, Slot + 1}.
