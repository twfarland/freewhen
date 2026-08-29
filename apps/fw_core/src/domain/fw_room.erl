-module(fw_room).
-moduledoc """
The aggregate: one scheduling room, and every rule about what may happen to it.

A room lives on **idleness, not age**. Every change pushes its deadline out by
`idle_ms`, because coordinating a meeting across organisations can take weeks
and a room that dies mid-negotiation is worse than useless. It closes when a
slot is picked, or when nobody has touched it for that long.

Picking is the host's alone, proved by a token rather than an identity — the
room knows nothing about who the host is, only that they hold the secret it was
made with.

What a client *displays* is `fw_schedule`; this module is only the rules.
""".

-export([new/2, join/4, submit/4, pick/4]).
-export([grid/1, duration_slots/1, expires_at/1, picked/1, is_expired/2]).
-export([attendees/1]).
-export([to_binary/1, from_binary/1]).
-export_type([t/0, params/0, token/0, error/0]).

-type token() :: binary().

-type params() :: #{
    grid := fw_grid:t(),
    duration_slots := pos_integer(),
    host_token := token(),
    capacity := pos_integer(),
    idle_ms := pos_integer()
}.

-type error() ::
    expired | finalized | full | duplicate | unknown_attendee | forbidden | bad_slot |
    bad_duration | fw_attendee:error() | fw_availability:error().

-opaque t() :: #{
    grid := fw_grid:t(),
    duration_slots := pos_integer(),
    host_token := token(),
    capacity := pos_integer(),
    idle_ms := pos_integer(),
    attendees := #{fw_attendee:id() => fw_attendee:t()},
    order := [fw_attendee:id()],
    picked := fw_grid:slot() | undefined,
    expires_at := fw_grid:millisecond()
}.

%% Bump when the shape above changes: a snapshot written by an older release
%% must be discarded rather than misread.
-define(SNAPSHOT, fw_room_v2).

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
        ok -> extended(admit(Id, Alias, Room), Now);
        {error, Reason} -> {error, Reason}
    end.

-doc "Record when an attendee can meet, as the slots they are free in.".
-spec submit(fw_attendee:id(), [fw_grid:slot()], fw_grid:millisecond(), t()) ->
    {ok, t()} | {error, error()}.
submit(Id, FreeSlots, Now, Room) ->
    case open(Now, Room) of
        ok -> extended(record(Id, FreeSlots, Room), Now);
        {error, Reason} -> {error, Reason}
    end.

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

-spec is_expired(fw_grid:millisecond(), t()) -> boolean().
is_expired(Now, #{expires_at := ExpiresAt}) -> Now >= ExpiresAt.

-doc "In the order they joined, so the grid does not reshuffle itself.".
-spec attendees(t()) -> [fw_attendee:t()].
attendees(#{attendees := Attendees, order := Order}) ->
    [maps:get(Id, Attendees) || Id <- Order].

%%% ---- writing a room down ----

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
    #{host_token := Token, capacity := Capacity, idle_ms := Idle} = Params,
    #{
        grid => Grid,
        duration_slots => Duration,
        host_token => Token,
        capacity => Capacity,
        idle_ms => Idle,
        attendees => #{},
        order => [],
        picked => undefined,
        expires_at => Now + Idle
    }.

%% Any change is a sign the meeting is still being arranged, so the deadline
%% moves. Picking does not go through here: a settled room runs out its grace.
extended({ok, Room}, Now) -> {ok, touched(Now, Room)};
extended({error, Reason}, _Now) -> {error, Reason}.

touched(Now, #{idle_ms := Idle} = Room) -> Room#{expires_at := Now + Idle}.

open(Now, #{expires_at := ExpiresAt}) when Now >= ExpiresAt -> {error, expired};
open(_Now, #{picked := Picked}) when Picked =/= undefined -> {error, finalized};
open(_Now, _Room) -> ok.

admit(Id, Alias, #{attendees := Attendees, capacity := Capacity} = Room) ->
    case {maps:is_key(Id, Attendees), maps:size(Attendees) >= Capacity} of
        {true, _AtCapacity} -> {error, duplicate};
        {false, true} -> {error, full};
        {false, false} -> attach(fw_attendee:new(Id, Alias), Id, Room)
    end.

attach({ok, Attendee}, Id, #{attendees := Attendees, order := Order} = Room) ->
    {ok, Room#{attendees := Attendees#{Id => Attendee}, order := Order ++ [Id]}};
attach({error, Reason}, _Id, _Room) ->
    {error, Reason}.

record(Id, FreeSlots, #{grid := Grid, attendees := Attendees} = Room) ->
    case {maps:find(Id, Attendees), fw_availability:from_slots(FreeSlots, Grid)} of
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
