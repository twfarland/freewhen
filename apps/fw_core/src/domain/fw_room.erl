-module(fw_room).
-moduledoc """
The aggregate: one scheduling room, and every rule about what may happen to it.

A room is closed to changes once it expires or once a slot is picked. Picking
is the host's alone, proved by a token rather than an identity — the room knows
nothing about who the host is, only that they hold the secret it was made with.

Everything a client displays is computed here and published whole. The browser
formats; it does not decide.
""".

-export([new/2, join/4, submit/4, leave/2, pick/4]).
-export([grid/1, duration_slots/1, expires_at/1, picked/1, is_expired/2]).
-export([attendees/1, heatmap/1, proposals/1, chosen/1]).
-export([to_binary/1, from_binary/1]).
-export_type([t/0, params/0, token/0, error/0]).

-type token() :: binary().

-type params() :: #{
    grid := fw_grid:t(),
    duration_slots := pos_integer(),
    host_token := token(),
    capacity := pos_integer(),
    ttl_ms := pos_integer()
}.

-type error() ::
    expired | finalized | full | duplicate | unknown_attendee | forbidden | bad_slot |
    bad_duration | fw_attendee:error() | fw_availability:error().

-opaque t() :: #{
    grid := fw_grid:t(),
    duration_slots := pos_integer(),
    host_token := token(),
    capacity := pos_integer(),
    attendees := #{fw_attendee:id() => fw_attendee:t()},
    order := [fw_attendee:id()],
    picked := fw_grid:slot() | undefined,
    expires_at := fw_grid:millisecond()
}.

-define(MAX_PROPOSALS, 5).
%% Bump when the shape above changes: a snapshot written by an older release
%% must be discarded rather than misread.
-define(SNAPSHOT, fw_room_v1).

%%% ---- construction ----

-spec new(params(), fw_grid:millisecond()) -> {ok, t()} | {error, error()}.
new(#{grid := Grid, duration_slots := Duration} = Params, Now) ->
    case fw_grid:is_window(0, Duration, Grid) of
        true -> {ok, build(Params, Now)};
        false -> {error, bad_duration}
    end.

%%% ---- commands ----

-spec join(fw_attendee:id(), fw_attendee:alias(), fw_grid:millisecond(), t()) ->
    {ok, t()} | {error, error()}.
join(Id, Alias, Now, Room) ->
    case open(Now, Room) of
        ok -> admit(Id, Alias, Now, Room);
        {error, Reason} -> {error, Reason}
    end.

-doc "Record when an attendee is busy, as the slots they cannot meet in.".
-spec submit(fw_attendee:id(), [fw_grid:slot()], fw_grid:millisecond(), t()) ->
    {ok, t()} | {error, error()}.
submit(Id, BusySlots, Now, Room) ->
    case open(Now, Room) of
        ok -> record(Id, BusySlots, Room);
        {error, Reason} -> {error, Reason}
    end.

-doc "Always allowed and always succeeds, including for a stranger.".
-spec leave(fw_attendee:id(), t()) -> t().
leave(Id, #{attendees := Attendees, order := Order} = Room) ->
    Room#{attendees := maps:remove(Id, Attendees), order := lists:delete(Id, Order)}.

-doc "Settle on a slot. Only the holder of the host token may do this.".
-spec pick(fw_grid:slot(), token(), fw_grid:millisecond(), t()) -> {ok, t()} | {error, error()}.
pick(Slot, Token, Now, Room) ->
    case is_host(Token, Room) of
        true -> pick_open(Slot, Now, Room);
        false -> {error, forbidden}
    end.

%%% ---- queries ----

-spec grid(t()) -> fw_grid:t().
grid(#{grid := Grid}) -> Grid.

-spec duration_slots(t()) -> pos_integer().
duration_slots(#{duration_slots := Duration}) -> Duration.

-spec expires_at(t()) -> fw_grid:millisecond().
expires_at(#{expires_at := ExpiresAt}) -> ExpiresAt.

-spec picked(t()) -> fw_grid:slot() | undefined.
picked(#{picked := Picked}) -> Picked.

-doc "The settled meeting, or `undefined` while the room is still open.".
-spec chosen(t()) -> fw_proposal:t() | undefined.
chosen(#{picked := undefined}) -> undefined;
chosen(#{picked := Slot} = Room) -> proposal(#{start => Slot, free => answered(Room)}, Room).

-spec is_expired(fw_grid:millisecond(), t()) -> boolean().
is_expired(Now, #{expires_at := ExpiresAt}) -> Now >= ExpiresAt.

-doc "In the order they joined, so the grid does not reshuffle itself.".
-spec attendees(t()) -> [fw_attendee:t()].
attendees(#{attendees := Attendees, order := Order}) ->
    [maps:get(Id, Attendees) || Id <- Order].

-spec heatmap(t()) -> fw_heatmap:counts().
heatmap(#{grid := Grid} = Room) ->
    fw_heatmap:counts([fw_attendee:availability(A) || A <- answered_by(Room)], Grid).

-spec proposals(t()) -> [fw_proposal:t()].
proposals(#{grid := Grid, duration_slots := Duration} = Room) ->
    Windows = fw_heatmap:windows(heatmap(Room), Duration, Grid),
    [proposal(W, Room) || W <- fw_heatmap:best(Windows, ?MAX_PROPOSALS)].

%%% ---- writing a room down ----

-doc "Serialisation lives here because this module owns the shape being written.".
-spec to_binary(t()) -> binary().
to_binary(Room) -> term_to_binary({?SNAPSHOT, Room}).

-doc "Anything not written by this release's shape is unreadable, never guessed at.".
-spec from_binary(binary()) -> {ok, t()} | {error, unreadable}.
from_binary(Bytes) ->
    try binary_to_term(Bytes, [safe]) of
        {?SNAPSHOT, Room} when is_map(Room) -> {ok, Room};
        _Other -> {error, unreadable}
    catch
        error:badarg -> {error, unreadable}
    end.

%%% ---- internal ----

build(#{grid := Grid, duration_slots := Duration} = Params, Now) ->
    #{host_token := Token, capacity := Capacity, ttl_ms := Ttl} = Params,
    #{
        grid => Grid,
        duration_slots => Duration,
        host_token => Token,
        capacity => Capacity,
        attendees => #{},
        order => [],
        picked => undefined,
        expires_at => Now + Ttl
    }.

proposal(Window, #{grid := Grid, duration_slots := Duration}) ->
    fw_proposal:of_window(Window, Duration, Grid).

answered_by(Room) -> [A || A <- attendees(Room), fw_attendee:has_availability(A)].

answered(Room) -> length(answered_by(Room)).

open(Now, #{expires_at := ExpiresAt}) when Now >= ExpiresAt -> {error, expired};
open(_Now, #{picked := Picked}) when Picked =/= undefined -> {error, finalized};
open(_Now, _Room) -> ok.

admit(Id, Alias, Now, #{attendees := Attendees, capacity := Capacity} = Room) ->
    case {maps:is_key(Id, Attendees), maps:size(Attendees) >= Capacity} of
        {true, _AtCapacity} -> {error, duplicate};
        {false, true} -> {error, full};
        {false, false} -> attach(fw_attendee:new(Id, Alias, Now), Id, Room)
    end.

attach({ok, Attendee}, Id, #{attendees := Attendees, order := Order} = Room) ->
    {ok, Room#{attendees := Attendees#{Id => Attendee}, order := Order ++ [Id]}};
attach({error, Reason}, _Id, _Room) ->
    {error, Reason}.

record(Id, BusySlots, #{grid := Grid, attendees := Attendees} = Room) ->
    case {maps:find(Id, Attendees), fw_availability:from_slots(BusySlots, Grid)} of
        {{ok, Attendee}, {ok, Availability}} ->
            Updated = fw_attendee:with_availability(Availability, Attendee),
            {ok, Room#{attendees := Attendees#{Id => Updated}}};
        {error, _AnyAvailability} ->
            {error, unknown_attendee};
        {_AnyAttendee, {error, Reason}} ->
            {error, Reason}
    end.

pick_open(Slot, Now, #{grid := Grid, duration_slots := Duration} = Room) ->
    case open(Now, Room) of
        ok -> settle(fw_grid:is_window(Slot, Duration, Grid), Slot, Room);
        {error, Reason} -> {error, Reason}
    end.

settle(true, Slot, Room) -> {ok, Room#{picked := Slot}};
settle(false, _Slot, _Room) -> {error, bad_slot}.

%% Constant-time, and length-checked first because crypto:hash_equals/2 raises
%% rather than answering false when the two binaries differ in size.
is_host(Token, #{host_token := Expected}) when
    is_binary(Token), byte_size(Token) =:= byte_size(Expected)
->
    crypto:hash_equals(Token, Expected);
is_host(_Token, _Room) ->
    false.
