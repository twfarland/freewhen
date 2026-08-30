-module(fw_room).
-moduledoc """
The aggregate: one scheduling room, and every rule about what may happen to it.

A room lives on **idleness, not age**: every change pushes its deadline out by
`idle_ms`, because coordinating across organisations takes weeks.

**Everybody here answers before a time can be chosen**, and `exclude_silent/3`
is the only way past that gate. **A chosen time is an answer, not an ending**:
the host may unpick or pick again, availability stays editable, and a settled
room lives until `grace_ms` past the meeting rather than past the decision.

Whether a chosen time still works is derived by `fw_schedule` and never stored,
so the two cannot disagree. Picking, excluding and cancelling belong to the
host, proved by a token rather than an identity. The machine these rules add up
to is drawn in `docs/ARCHITECTURE.md`.
""".

-export([new/2, join/4, submit/4, pick/4, unpick/3, exclude_silent/3, cancel/3]).
-export([grid/1, duration_slots/1, expires_at/1, picked/1, is_expired/2]).
-export([attendees/1, everyone_answered/1, cancelled/1]).
-export([to_binary/1, from_binary/1]).
-export_type([t/0, params/0, token/0, error/0]).

-type token() :: binary().

-type params() :: #{
    grid := fw_grid:t(),
    duration_slots := pos_integer(),
    host_token := token(),
    capacity := pos_integer(),
    idle_ms := pos_integer(),
    grace_ms := pos_integer()
}.

-type error() ::
    expired | still_waiting | forbidden | bad_slot | bad_duration |
    fw_roster:error() | fw_availability:error().

-opaque t() :: #{
    grid := fw_grid:t(),
    duration_slots := pos_integer(),
    host_token := token(),
    capacity := pos_integer(),
    idle_ms := pos_integer(),
    grace_ms := pos_integer(),
    roster := fw_roster:t(),
    picked := fw_grid:slot() | undefined,
    cancelled := boolean(),
    idle_until := fw_grid:millisecond()
}.

%% Bump when the shape above changes: a snapshot written by an older release
%% must be discarded rather than misread.
-define(SNAPSHOT, fw_room_v4).

%%% ---- commands ----

-spec new(params(), fw_grid:millisecond()) -> {ok, t()} | {error, error()}.
new(#{grid := Grid, duration_slots := Duration} = Params, Now) ->
    case fw_grid:is_window(0, Duration, Grid) of
        true -> {ok, build(Params, Now)};
        false -> {error, bad_duration}
    end.

-spec join(fw_attendee:id(), fw_attendee:alias(), fw_grid:millisecond(), t()) ->
    {ok, t()} | {error, error()}.
join(Id, Alias, Now, #{capacity := Capacity, roster := Roster} = Room) ->
    guarded(fun() -> rostered(fw_roster:add(Id, Alias, Capacity, Roster), Room) end, Now, Room).

-spec submit(fw_attendee:id(), [fw_grid:slot()], fw_grid:millisecond(), t()) ->
    {ok, t()} | {error, error()}.
submit(Id, FreeSlots, Now, Room) ->
    guarded(fun() -> recorded(Id, FreeSlots, Room) end, Now, Room).

-doc "Put a slot on the table, once everybody here has answered.".
-spec pick(fw_grid:slot(), token(), fw_grid:millisecond(), t()) -> {ok, t()} | {error, error()}.
pick(Slot, Token, Now, Room) ->
    hosted(fun() -> settle(Slot, Room) end, Token, Now, Room).

-spec unpick(token(), fw_grid:millisecond(), t()) -> {ok, t()} | {error, error()}.
unpick(Token, Now, Room) ->
    hosted(fun() -> {ok, Room#{picked := undefined}} end, Token, Now, Room).

-spec exclude_silent(token(), fw_grid:millisecond(), t()) -> {ok, t()} | {error, error()}.
exclude_silent(Token, Now, #{roster := Roster} = Room) ->
    hosted(fun() -> {ok, Room#{roster := fw_roster:without_silent(Roster)}} end, Token, Now, Room).

-doc "Call the whole thing off. The room ends and leaves nothing behind.".
-spec cancel(token(), fw_grid:millisecond(), t()) -> {ok, t()} | {error, error()}.
cancel(Token, Now, Room) ->
    hosted(fun() -> {ok, Room#{cancelled := true}} end, Token, Now, Room).

%%% ---- queries ----

-spec grid(t()) -> fw_grid:t().
grid(#{grid := Grid}) -> Grid.

-spec duration_slots(t()) -> pos_integer().
duration_slots(#{duration_slots := Duration}) -> Duration.

-doc "The later of running out of patience and the meeting itself being over.".
-spec expires_at(t()) -> fw_grid:millisecond().
expires_at(#{cancelled := true}) -> 0;
expires_at(#{idle_until := Idle} = Room) -> max(Idle, settled_until(Room)).

-spec picked(t()) -> fw_grid:slot() | undefined.
picked(#{picked := Picked}) -> Picked.

-spec cancelled(t()) -> boolean().
cancelled(#{cancelled := Cancelled}) -> Cancelled.

-spec is_expired(fw_grid:millisecond(), t()) -> boolean().
is_expired(Now, Room) -> Now >= expires_at(Room).

-spec attendees(t()) -> [fw_attendee:t()].
attendees(#{roster := Roster}) -> fw_roster:list(Roster).

-spec everyone_answered(t()) -> boolean().
everyone_answered(#{roster := Roster}) -> fw_roster:everyone_answered(Roster).

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
    #{host_token := Token, capacity := Capacity, idle_ms := Idle, grace_ms := Grace} = Params,
    #{
        grid => Grid,
        duration_slots => Duration,
        host_token => Token,
        capacity => Capacity,
        idle_ms => Idle,
        grace_ms => Grace,
        roster => fw_roster:empty(),
        picked => undefined,
        cancelled => false,
        idle_until => Now + Idle
    }.

%% Every command runs through here: refuse an ended room, then push the
%% deadline out, because a change means the meeting is still being arranged.
guarded(Change, Now, Room) ->
    case is_expired(Now, Room) of
        true -> {error, expired};
        false -> extended(Change(), Now)
    end.

hosted(Change, Token, Now, Room) ->
    case is_host(Token, Room) of
        true -> guarded(Change, Now, Room);
        false -> {error, forbidden}
    end.

extended({ok, Room}, Now) -> {ok, touched(Now, Room)};
extended({error, Reason}, _Now) -> {error, Reason}.

touched(Now, #{idle_ms := Idle} = Room) -> Room#{idle_until := Now + Idle}.

settled_until(#{picked := undefined}) ->
    0;
settled_until(#{picked := Slot, grace_ms := Grace, grid := Grid, duration_slots := Duration}) ->
    element(2, fw_grid:window(Slot, Duration, Grid)) + Grace.

settle(Slot, #{grid := Grid, duration_slots := Duration} = Room) ->
    case {everyone_answered(Room), fw_grid:is_window(Slot, Duration, Grid)} of
        {false, _AnyWindow} -> {error, still_waiting};
        {true, false} -> {error, bad_slot};
        {true, true} -> {ok, Room#{picked := Slot}}
    end.

recorded(Id, FreeSlots, #{grid := Grid, roster := Roster} = Room) ->
    case fw_availability:from_slots(FreeSlots, Grid) of
        {ok, Availability} -> rostered(fw_roster:answer(Id, Availability, Roster), Room);
        {error, Reason} -> {error, Reason}
    end.

rostered({ok, Roster}, Room) -> {ok, Room#{roster := Roster}};
rostered({error, Reason}, _Room) -> {error, Reason}.

%% Constant-time, and length-checked first because crypto:hash_equals/2 raises
%% rather than answering false when the two binaries differ in size.
is_host(Token, #{host_token := Expected}) when
    is_binary(Token), byte_size(Token) =:= byte_size(Expected)
->
    crypto:hash_equals(Token, Expected);
is_host(_Token, _Room) ->
    false.
