-module(fw_room_json).
-moduledoc """
The translation between a room and what goes over the socket.

The whole of FreeWhen's JSON knowledge, deliberately in one module: the domain
has no idea it is being published, and the transport has no idea what it is
publishing.

## The protocol

Four messages in, four out, and no correlation ids — a connection watches
exactly one room, and the only reply anyone waits for is the id they get back
from joining.

    client -> server                        server -> client
    {type: join,   alias}                   {type: state,  room}
    {type: submit, attendeeId, busy}        {type: joined, attendeeId}
    {type: leave,  attendeeId}              {type: error,  reason}
    {type: pick,   hostToken, slot}         {type: closed, reason}

Every change sends the whole room, already computed. A snapshot is about a
kilobyte and a room has a handful of participants, so the bandwidth a diff
would save is not worth the machinery on both sides.

## What the browser is left to do

Formatting, and only formatting. Proposals carry UTC instants rather than slot
numbers, so the browser converts them to local time with the timezone database
it already has and does no arithmetic of its own. The server holds no
timezone for anybody.

## What is deliberately absent

Attendee ids are **not** in a snapshot. An id is a capability — whoever holds
one may replace that person's availability — so publishing the list would let
any participant impersonate any other. A client learns its own id once, as the
reply to its own join.
""".

-export([state/1, joined/1, error/1, closed/1, command/1]).

%%% ---- server to client ----

-spec state(fw_room:t()) -> binary().
state(Room) -> fw_json:encode(#{<<"type">> => <<"state">>, <<"room">> => room(Room)}).

-spec joined(fw_attendee:id()) -> binary().
joined(Id) -> fw_json:encode(#{<<"type">> => <<"joined">>, <<"attendeeId">> => Id}).

-spec error(atom() | binary()) -> binary().
error(Reason) -> fw_json:encode(#{<<"type">> => <<"error">>, <<"reason">> => text(Reason)}).

-spec closed(atom() | binary()) -> binary().
closed(Reason) -> fw_json:encode(#{<<"type">> => <<"closed">>, <<"reason">> => text(Reason)}).

%%% ---- client to server ----

-spec command(binary()) -> {ok, fw_room_server:command()} | {error, binary()}.
command(Frame) ->
    case fw_json:decode(Frame) of
        {ok, Message} -> decode(Message);
        {error, invalid_json} -> {error, <<"not json">>}
    end.

%%% ---- decoding ----

decode(#{<<"type">> := <<"join">>, <<"alias">> := Alias}) when is_binary(Alias) ->
    {ok, {join, Alias}};
decode(#{<<"type">> := <<"submit">>, <<"attendeeId">> := Id, <<"busy">> := Busy}) when
    is_binary(Id), is_binary(Busy)
->
    submitted(Id, Busy);
decode(#{<<"type">> := <<"leave">>, <<"attendeeId">> := Id}) when is_binary(Id) ->
    {ok, {leave, Id}};
decode(#{<<"type">> := <<"pick">>, <<"hostToken">> := Token, <<"slot">> := Slot}) when
    is_binary(Token), is_integer(Slot)
->
    {ok, {pick, Slot, Token}};
decode(_Unrecognised) ->
    {error, <<"unrecognised message">>}.

submitted(Id, Busy) ->
    case fw_busy_codec:decode(Busy) of
        {ok, BusySlots} -> {ok, {submit, Id, BusySlots}};
        {error, Why} -> {error, Why}
    end.

%%% ---- projection ----

room(Room) ->
    #{
        <<"grid">> => grid(fw_room:grid(Room)),
        <<"durationSlots">> => fw_room:duration_slots(Room),
        <<"attendees">> => [attendee(A) || A <- fw_room:attendees(Room)],
        <<"heatmap">> => fw_room:heatmap(Room),
        <<"proposals">> => [proposal(P) || P <- fw_room:proposals(Room)],
        <<"chosen">> => chosen(fw_room:chosen(Room)),
        <<"expiresAt">> => fw_room:expires_at(Room)
    }.

grid(Grid) ->
    #{
        <<"startsAt">> => fw_grid:starts_at(Grid),
        <<"slotMinutes">> => fw_grid:slot_minutes(Grid),
        <<"slots">> => fw_grid:slots(Grid)
    }.

attendee(Attendee) ->
    #{
        <<"alias">> => fw_attendee:alias(Attendee),
        <<"ready">> => fw_attendee:has_availability(Attendee)
    }.

proposal(Proposal) ->
    #{
        <<"slot">> => fw_proposal:slot(Proposal),
        <<"free">> => fw_proposal:free(Proposal),
        <<"startsAt">> => fw_proposal:starts_at(Proposal),
        <<"endsAt">> => fw_proposal:ends_at(Proposal)
    }.

chosen(undefined) -> null;
chosen(Proposal) -> proposal(Proposal).

text(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
text(Reason) when is_binary(Reason) -> Reason.
